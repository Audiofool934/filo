#!/usr/bin/env python3
"""Offline, exact PCM comparison for original filo fixture captures; never opens audio devices."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import wave

os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
import numpy as np
from scipy.signal import correlate

WORK = Path(__file__).resolve().parent
REFERENCE = WORK / "filo-reference-44100-24.wav"
MUSIC = WORK / "known-reference-tap.f32"
DEFAULT_CAPTURES = [WORK / "avplayer-alac-tap.f32", WORK / "avplayer-alac-rate-enabled-tap.f32"]
SCALE = 8_388_608
MAX_CAPTURE_BYTES = 32_000_000


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def stable_bytes(path, maximum):
    before = path.stat()
    if not 0 < before.st_size <= maximum:
        raise ValueError(f"{path.name}: empty or exceeds {maximum} bytes")
    data = path.read_bytes()
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns) or len(data) != before.st_size:
        raise ValueError(f"{path.name}: input changed while reading")
    return data


def read_reference(path):
    raw = stable_bytes(path, 16_000_000)
    with wave.open(str(path), "rb") as audio:
        if audio.getnchannels() != 2 or audio.getsampwidth() != 3 or audio.getcomptype() != "NONE":
            raise ValueError("Reference must be signed24 stereo PCM WAV")
        rate, frames = audio.getframerate(), audio.getnframes()
        if rate != 44100 or not 128 <= frames <= 1_000_000:
            raise ValueError("Unexpected reference rate or frame count")
        packed = np.frombuffer(audio.readframes(frames), dtype=np.uint8)
    if packed.size != frames * 6 or sha256(path.read_bytes()) != sha256(raw):
        raise ValueError("Truncated or changing WAV reference")
    words = packed.reshape(-1, 3).astype(np.int32)
    signed = words[:, 0] | (words[:, 1] << 8) | (words[:, 2] << 16)
    signed = ((signed ^ 0x800000) - 0x800000).reshape(-1, 2)
    samples = (signed.astype(np.float64) / SCALE).astype("<f4")
    if not np.array_equal(samples.astype(np.float64) * SCALE, signed):
        raise ValueError("Reference did not decode exactly to Float32")
    return samples, {"file": path.name, "sha256": sha256(raw), "sampleRate": rate,
                     "frames": frames, "bits": 24, "channels": 2}


def active_span(samples):
    active = np.flatnonzero(np.any(samples != 0, axis=1))
    if not active.size:
        return {"firstFrame": None, "lastFrameInclusive": None, "frames": 0,
                "nonzeroStereoFrames": 0, "nonzeroIndividualSamples": 0, "sha256": sha256(b"")}, b""
    first, end = int(active[0]), int(active[-1]) + 1
    raw = samples[first:end].astype("<f4", copy=False).tobytes()
    return {"firstFrame": first, "lastFrameInclusive": end - 1, "frames": end - first,
            "nonzeroStereoFrames": int(active.size), "nonzeroIndividualSamples": int(np.count_nonzero(samples)),
            "sha256": sha256(raw)}, raw


def overlap(reference_frames, capture_frames, lag):
    first = max(0, -lag)
    end = min(reference_frames, capture_frames - lag)
    return first, max(first, end)


def align(reference, capture):
    channels = []
    for channel in range(2):
        x = reference[:, channel].astype(np.float64)
        y = capture[:, channel].astype(np.float64)
        correlation = correlate(y, x, mode="full", method="fft")
        magnitudes = np.abs(correlation)
        peak = int(np.argmax(magnitudes))
        lag = peak - len(reference) + 1
        maximum = float(magnitudes[peak])
        magnitudes[peak] = 0
        competitor = float(magnitudes.max())
        first, end = overlap(len(reference), len(capture), lag)
        expected, actual = x[first:end], y[first + lag:end + lag]
        denominator = float(np.sqrt(np.sum(expected * expected) * np.sum(actual * actual)))
        similarity = float(np.sum(expected * actual) / denominator) if denominator else 0.0
        ratio = maximum / competitor if competitor else None
        confident = end - first >= 128 and abs(similarity) >= 0.8 and maximum > 0 and (ratio is None or ratio >= 4)
        channels.append({"channel": channel, "captureOffsetFrames": lag, "overlapFrames": end - first,
                         "signedCosineSimilarity": similarity, "peakOverNextLag": ratio, "confident": confident})
    agreed = channels[0]["captureOffsetFrames"] == channels[1]["captureOffsetFrames"]
    return {"channels": channels, "channelsAgree": agreed,
            "confident": agreed and all(c["confident"] for c in channels),
            "captureOffsetFrames": channels[0]["captureOffsetFrames"] if agreed else None}


def section(reference, capture, lag, first, end):
    available_first, available_end = overlap(len(reference), len(capture), lag)
    start, stop = max(first, available_first), min(end, available_end)
    count = max(0, stop - start)
    result = {"requestedStartFrame": first, "requestedEndFrameExclusive": end,
              "comparedStartFrame": start if count else None, "comparedFrames": count,
              "missingFrames": end - first - count}
    if not count:
        return result
    x, y = reference[start:stop], capture[start + lag:stop + lag]
    errors = (y.astype(np.float64) - x.astype(np.float64)) * SCALE
    different = y != x
    result.update({"mismatchedSamples": int(np.count_nonzero(different)),
                   "mismatchedFrames": int(np.count_nonzero(np.any(different, axis=1))),
                   "float32WordMismatches": int(np.count_nonzero(y.view("<u4") != x.view("<u4"))),
                   "rmsErrorLSB24": float(np.sqrt(np.mean(errors * errors))),
                   "maxAbsoluteErrorLSB24": float(np.max(np.abs(errors))),
                   "nearest24BitMismatchedSamplesDiagnosticOnly": int(np.count_nonzero(np.rint(y.astype(np.float64) * SCALE) != x.astype(np.float64) * SCALE)),
                   "exactExpectedSamples": bool(not np.any(different))})
    return result


def analyze(reference, capture):
    if capture.ndim != 2 or capture.shape[1] != 2 or len(capture) < 128 or not np.isfinite(capture).all():
        raise ValueError("Capture must contain at least 128 finite interleaved stereo Float32 frames")
    alignment = align(reference, capture)
    span, _ = active_span(capture)
    scaled = capture.astype(np.float64) * SCALE
    result = {"capturedFrames": len(capture), "referenceFrames": len(reference), "activeSpan": span,
              "off24BitGridSamples": int(np.count_nonzero(scaled != np.trunc(scaled))),
              "outOfRangeSamples": int(np.count_nonzero((capture < -1) | (capture >= 1))),
              "alignment": alignment, "fullReferenceExact": False, "fullReferenceFloat32WordsExact": False,
              "boundary": "Observed player process-tap PCM; no exclusive relay or USB receiver measurement"}
    lag = alignment["captureOffsetFrames"]
    if lag is None:
        result["failureReason"] = "Independent channel alignments disagree"
        return result
    first, end = overlap(len(reference), len(capture), lag)
    capture_first, capture_end = first + lag, end + lag
    leading_nonzero = int(np.count_nonzero(capture[:max(0, lag)]))
    trailing_nonzero = int(np.count_nonzero(capture[max(0, min(len(capture), lag + len(reference))):]))
    whole = section(reference, capture, lag, 0, len(reference))
    result.update({"referenceStartFrame": first, "referenceEndFrameExclusive": end,
                   "captureStartFrame": capture_first, "captureEndFrameExclusive": capture_end,
                   "missingPrefixFrames": first, "missingSuffixFrames": len(reference) - end,
                   "alignedWindowFitsCapture": first == 0 and end == len(reference),
                   "nonzeroSamplesBeforeAlignedReference": leading_nonzero,
                   "nonzeroSamplesAfterAlignedReference": trailing_nonzero,
                   "activeStartRelativeToAlignedReference": span["firstFrame"] - lag if span["firstFrame"] is not None else None,
                   "firstReferenceFrameInCapture": 0 <= lag < len(capture),
                   "lastReferenceFrameInCapture": 0 <= lag + len(reference) - 1 < len(capture),
                   "firstReferenceFrameExact": bool(first == 0 and np.array_equal(capture[lag], reference[0])),
                   "lastReferenceFrameExact": bool(end == len(reference) and np.array_equal(capture[lag + len(reference) - 1], reference[-1])),
                   "wholeReference": whole,
                   "opening2048": section(reference, capture, lag, 0, min(2048, len(reference))),
                   "steadyAfter2048": section(reference, capture, lag, min(2048, len(reference)), len(reference)),
                   "final1024": section(reference, capture, lag, max(0, len(reference) - 1024), len(reference))})
    exact = alignment["confident"] and whole["missingFrames"] == 0 and whole.get("mismatchedSamples") == 0
    exact = exact and leading_nonzero == 0 and trailing_nonzero == 0 and result["off24BitGridSamples"] == 0 and result["outOfRangeSamples"] == 0
    result["fullReferenceExact"] = bool(exact)
    result["fullReferenceFloat32WordsExact"] = bool(exact and whole.get("float32WordMismatches") == 0)
    # These are diagnostic local-lag checks only; they never change the one global comparison alignment.
    windows = []
    for start in range(max(first + 4, 2048), min(end, len(reference) - 4) - 8192 + 1, 8192):
        y = capture[lag + start:lag + start + 8192].astype(np.float64)
        scores = []
        for shift in range(-4, 5):
            x = reference[start + shift:start + shift + 8192].astype(np.float64)
            denominator = float(np.sqrt(np.sum(x * x) * np.sum(y * y)))
            scores.append((float(np.sum(x * y) / denominator) if denominator else 0, shift))
        similarity, shift = max(scores)
        windows.append({"referenceStartFrame": start, "bestAdditionalLag": shift, "signedCosineSimilarity": similarity})
    result["steadyLocalLagChecks"] = windows
    if not exact:
        result["failureReason"] = "Requires confident fixed alignment, every original reference frame unchanged, and no extra nonzero prefix/tail; no rounding or fitted gain is permitted"
    return result


def compare_active_spans(first, second):
    first_info, a = active_span(first)
    second_info, b = active_span(second)
    equal_length = len(a) == len(b)
    return {"firstSpan": first_info, "secondSpan": second_info, "sameLength": equal_length,
            "byteIdentical": a == b,
            "differingFloat32Words": int(np.count_nonzero(np.frombuffer(a, "<u4") != np.frombuffer(b, "<u4"))) if equal_length else None,
            "method": "Remove only outer silence; preserve every stereo frame and individual zero sample inside the active span"}


def compare_aligned_captures(first, first_result, second, second_result, reference_frames):
    offsets = [first_result["alignment"]["captureOffsetFrames"], second_result["alignment"]["captureOffsetFrames"]]
    if any(value is None for value in offsets):
        return {"available": False, "reason": "No agreed reference alignment"}
    a, b = offsets
    windows = []
    for label, start, end in [("opening2048", 0, min(2048, reference_frames)), ("steadyAfter2048", min(2048, reference_frames), reference_frames)]:
        start = max(start, -a, -b)
        end = min(end, len(first) - a, len(second) - b)
        if end <= start:
            continue
        x, y = first[a + start:a + end], second[b + start:b + end]
        errors = (x.astype(np.float64) - y.astype(np.float64)) * SCALE
        windows.append({"section": label, "referenceStartFrame": start, "frames": end - start,
                        "differingSamples": int(np.count_nonzero(x != y)),
                        "rmsDifferenceLSB24": float(np.sqrt(np.mean(errors * errors))),
                        "maxAbsoluteDifferenceLSB24": float(np.max(np.abs(errors)))})
    return {"available": True, "method": "Compare both captures at their independently found fixed original-reference offsets; no gain fit or realignment", "windows": windows}


def load_capture(path):
    metadata_path = path.with_suffix(".json")
    metadata_raw = stable_bytes(metadata_path, 1_000_000)
    metadata = json.loads(metadata_raw)
    raw = stable_bytes(path, MAX_CAPTURE_BYTES)
    if len(raw) % 8:
        raise ValueError(f"{path.name}: partial stereo frame")
    samples = np.frombuffer(raw, dtype="<f4").reshape(-1, 2)
    if not np.isfinite(samples).all():
        raise ValueError(f"{path.name}: nonfinite samples")
    if "captureSHA256" in metadata and metadata["captureSHA256"] != sha256(raw):
        raise ValueError(f"{path.name}: completed sidecar capture hash does not match")
    if "inputFormat" in metadata and metadata["inputFormat"].get("rate") != 44100:
        raise ValueError(f"{path.name}: observed input rate does not match the reference")
    facts = {key: metadata[key] for key in ("firstNonzeroFrame", "lastNonzeroFrame", "nonzeroFrameSpan", "off24BitGridSamples", "sampleRate", "rate") if key in metadata}
    for container in [metadata, metadata.get("metrics", {})]:
        if "capturedFrames" in container and int(container["capturedFrames"]) != len(samples):
            raise ValueError(f"{path.name}: metadata frame count does not match the completed capture")
    return samples, {"file": path.name, "sha256": sha256(raw), "metadataFile": metadata_path.name,
                     "metadataSHA256": sha256(metadata_raw), "metadataObservations": facts}


def self_test(reference):
    zero = np.zeros((257, 2), dtype="<f4")
    padded = np.concatenate([zero, reference, zero])
    cases = {"exactPaddedReference": padded,
             "missingOnset": reference[37:], "missingTail": reference[:-41],
             "missingOnsetReplacedWithSilence": np.concatenate([zero, np.zeros((37, 2), dtype="<f4"), reference[37:], zero]),
             "missingTailReplacedWithSilence": np.concatenate([zero, reference[:-41], np.zeros((41, 2), dtype="<f4"), zero]),
             "oneFrameEarlyNonzeroOnset": np.concatenate([zero, reference[:1], reference, zero]),
             "extraNonzeroTail": np.concatenate([zero, reference, reference[-1:], zero]),
             "internalDroppedFrame": np.concatenate([zero, reference[:110000], reference[110001:], zero])}
    outcomes = {}
    for label, capture in cases.items():
        result = analyze(reference, capture)
        wanted = label == "exactPaddedReference"
        if result["fullReferenceExact"] != wanted:
            raise AssertionError(f"Self-test {label} incorrectly classified complete exact reference: {result}")
        if wanted:
            assert result["fullReferenceFloat32WordsExact"] and result["firstReferenceFrameExact"] and result["lastReferenceFrameExact"]
        if label == "missingOnset":
            assert result["missingPrefixFrames"] == 37 and not result["firstReferenceFrameInCapture"]
        if label == "missingTail":
            assert result["missingSuffixFrames"] == 41 and not result["lastReferenceFrameInCapture"]
        outcomes[label] = result["fullReferenceExact"]
    return outcomes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path, action="append", help="Completed .f32 plus same-stem .json; repeat for each API case")
    parser.add_argument("--output", type=Path, default=WORK / "api-reference-analysis.json")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    reference, reference_info = read_reference(REFERENCE)
    validation = self_test(reference)
    if args.self_test:
        print(json.dumps({"selfTestsPassed": True, "cases": validation}, indent=2))
        return
    paths = args.capture or DEFAULT_CAPTURES
    missing = [p.name for path in [MUSIC, *paths] for p in (path, path.with_suffix(".json")) if not p.exists()]
    if missing:
        print(json.dumps({"ready": True, "selfTestsPassed": True, "waitingForCompletedCaptures": missing}, indent=2))
        return
    music, music_info = load_capture(MUSIC)
    report = {"scope": "Original synthetic fixture only, process-tap boundary before filo exclusive bridge and DAC",
              "reference": reference_info, "selfTests": validation,
              "method": "Independent stereo FFT alignment, then one fixed offset; exact original values and complete first-to-last coverage, without rounding, gain fitting, or resampling",
              "music": {**music_info, **analyze(reference, music)}, "apiCaptures": []}
    for path in paths:
        samples, info = load_capture(path)
        result = analyze(reference, samples)
        report["apiCaptures"].append({**info, **result, "comparisonToMusicActiveSpan": compare_active_spans(samples, music),
            "comparisonToMusicAtReferenceAlignment": compare_aligned_captures(samples, result, music, report["music"], len(reference))})
    # A finished sidecar and unchanged capture bytes are required; never report a moving recording as final.
    for item in [report["music"], *report["apiCaptures"]]:
        path = MUSIC if item is report["music"] else next(p for p in paths if p.name == item["file"])
        if sha256(path.read_bytes()) != item["sha256"] or sha256(path.with_suffix(".json").read_bytes()) != item["metadataSHA256"]:
            raise ValueError(f"{path.name}: inputs changed during analysis")
    with args.output.open("x") as file:
        json.dump(report, file, indent=2, allow_nan=False)
        file.write("\n")
    print(json.dumps({"output": args.output.name, "selfTestsPassed": True,
        "results": [{"file": item["file"], "fullReferenceExact": item["fullReferenceExact"],
                     "float32WordsExact": item["fullReferenceFloat32WordsExact"], "off24BitGridSamples": item["off24BitGridSamples"],
                     "missingPrefixFrames": item.get("missingPrefixFrames"), "missingSuffixFrames": item.get("missingSuffixFrames"),
                     "sameActivePCMAsMusic": item["comparisonToMusicActiveSpan"]["byteIdentical"]} for item in report["apiCaptures"]]}, indent=2))


if __name__ == "__main__":
    main()
