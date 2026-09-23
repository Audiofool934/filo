#!/usr/bin/env python3
"""Independent finite-reference byte audit; never opens an audio device or player."""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct

import numpy as np


WORK = Path(__file__).resolve().parent
REFERENCE = WORK / "filo-reference-44100-24.wav"
REFERENCE_SHA256 = "43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e"
DEFAULT_CAPTURES = [WORK / f"spotify-{codec}-first-tap.f32" for codec in ("flac", "wav", "alac")]
ANCHOR_FRAMES = 32
SCALE = 8388608


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


def stable_read(path, limit):
    before = path.stat()
    if not 0 < before.st_size <= limit:
        raise ValueError(f"Unexpected size: {path.name}")
    raw = path.read_bytes()
    after = path.stat()
    if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
        raise ValueError(f"File changed during reading: {path.name}")
    if len(raw) != before.st_size:
        raise ValueError(f"Incomplete read: {path.name}")
    return raw


def read_reference():
    raw = stable_read(REFERENCE, 2_000_000)
    if sha256(raw) != REFERENCE_SHA256:
        raise ValueError("Canonical original fixture hash changed")
    if raw[:4] != b"RIFF" or raw[8:12] != b"WAVE" or struct.unpack_from("<I", raw, 4)[0] + 8 != len(raw):
        raise ValueError("Invalid complete RIFF/WAVE file")
    position, fmt, pcm = 12, None, None
    while position < len(raw):
        kind, length = struct.unpack_from("<4sI", raw, position)
        payload = raw[position + 8:position + 8 + length]
        if len(payload) != length:
            raise ValueError("Truncated WAV chunk")
        if kind == b"fmt ":
            if fmt is not None:
                raise ValueError("Duplicate WAV format")
            fmt = struct.unpack_from("<HHIIHH", payload)
        elif kind == b"data":
            if pcm is not None:
                raise ValueError("Duplicate WAV data")
            pcm = payload
        position += 8 + length + length % 2
    if position != len(raw) or fmt != (1, 2, 44100, 264600, 6, 24) or pcm is None or len(pcm) != 220500 * 6:
        raise ValueError("Expected original five-second 44.1 kHz signed24 stereo fixture")
    packed = np.frombuffer(pcm, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
    integers = packed[:, 0] + 256 * packed[:, 1] + 65536 * packed[:, 2]
    integers[integers >= 8388608] -= 16777216
    floats = (integers.astype(np.float64) / SCALE).astype("<f4").reshape(-1, 2)
    if not np.array_equal(floats.astype(np.float64).ravel() * SCALE, integers):
        raise ValueError("Reference Float32 conversion is not exact")
    return floats, {"file": REFERENCE.name, "sha256": sha256(raw), "sampleRate": 44100,
                    "channels": 2, "bits": 24, "frames": len(floats), "samples": floats.size,
                    "signed24PCMSHA256": sha256(pcm), "float32PCMSHA256": sha256(floats.tobytes())}


def align(reference, capture):
    raw = capture.tobytes()
    anchors, votes = [], Counter()
    for frame in [0, len(reference) // 2, len(reference) - ANCHOR_FRAMES]:
        needle = reference[frame:frame + ANCHOR_FRAMES].tobytes()
        offsets, position = [], 0
        while True:
            found = raw.find(needle, position)
            if found < 0:
                break
            if found % 8 == 0:
                offsets.append(found // 8 - frame)
            if len(offsets) > 128:
                raise ValueError("Excessively repeated reference anchor")
            position = found + 1
        votes.update(set(offsets))
        anchors.append({"referenceStartFrame": frame, "frames": ANCHOR_FRAMES,
                        "candidateCaptureOffsets": offsets})
    ordered = sorted(votes.items(), key=lambda item: (-item[1], item[0]))
    ambiguous = len(ordered) > 1 and ordered[0][1] == ordered[1][1]
    confident = bool(ordered and ordered[0][1] >= 2 and not ambiguous)
    return {"method": "Exact byte search for three disjoint 32-stereo-frame anchors; require two agreeing anchors and a unique highest vote",
            "anchors": anchors, "candidateVotes": [{"captureOffsetFrames": k, "matchingAnchors": v} for k, v in ordered],
            "ambiguous": ambiguous, "confident": confident,
            "captureOffsetFrames": ordered[0][0] if confident else None}


def analyze(reference, capture):
    if capture.dtype != np.dtype("<f4") or capture.ndim != 2 or capture.shape[1] != 2 or len(capture) < 128:
        raise ValueError("Expected finite-length interleaved stereo little-endian Float32 capture")
    finite = bool(np.isfinite(capture).all())
    result = {"capturedFrames": len(capture), "referenceFrames": len(reference),
              "nonFiniteSamples": int(np.count_nonzero(~np.isfinite(capture))), "fullReferenceFloat32WordsExact": False}
    if not finite:
        result["failure"] = "Nonfinite sample"
        return result
    scaled = capture.astype(np.float64) * SCALE
    result["off24BitGridSamples"] = int(np.count_nonzero(scaled != np.trunc(scaled)))
    active = np.flatnonzero(np.any(capture != 0, axis=1))
    start, end = (int(active[0]), int(active[-1]) + 1) if active.size else (0, 0)
    result["activeSpan"] = {"firstFrame": start if active.size else None, "lastFrameInclusive": end - 1 if active.size else None,
                            "frames": end - start, "sha256": sha256(capture[start:end].tobytes()),
                            "byteIdenticalToReference": capture[start:end].tobytes() == reference.tobytes(),
                            "method": "Remove only outer Float32 zero-valued silence; retain every frame and individual zero inside the span"}
    alignment = align(reference, capture)
    result["alignment"] = alignment
    offset = alignment["captureOffsetFrames"]
    if offset is None:
        result["failure"] = "No unambiguous alignment supported by at least two anchors"
        return result
    first, last = max(0, -offset), min(len(reference), len(capture) - offset)
    last = max(first, last)
    expected, actual = reference[first:last], capture[first + offset:last + offset]
    words_differ = expected.view("<u4") != actual.view("<u4")
    differing_locations = np.argwhere(words_differ)
    errors = (actual.astype(np.float64) - expected.astype(np.float64)) * SCALE
    prefix = capture[:max(0, offset)]
    tail = capture[max(0, min(len(capture), offset + len(reference))):]
    prefix_nonzero, tail_nonzero = int(np.count_nonzero(prefix)), int(np.count_nonzero(tail))
    missing_prefix, missing_suffix = first, len(reference) - last
    first_exact = first == 0 and len(actual) > 0 and np.array_equal(expected[0].view("<u4"), actual[0].view("<u4"))
    last_exact = last == len(reference) and len(actual) > 0 and np.array_equal(expected[-1].view("<u4"), actual[-1].view("<u4"))
    result.update({"referenceStartFrame": first, "comparedFrames": last - first, "comparedSamples": (last - first) * 2,
                   "missingPrefixFrames": missing_prefix, "missingSuffixFrames": missing_suffix,
                   "firstReferenceFrameExact": bool(first_exact), "lastReferenceFrameExact": bool(last_exact),
                   "leadingCaptureFrames": len(prefix), "trailingCaptureFrames": len(tail),
                   "nonzeroLeadingSamples": prefix_nonzero, "nonzeroTrailingSamples": tail_nonzero,
                   "float32WordMismatches": int(np.count_nonzero(words_differ)),
                   "mismatchedFrames": int(np.count_nonzero(np.any(words_differ, axis=1))),
                   "numericSampleMismatches": int(np.count_nonzero(expected != actual)),
                   "firstWordMismatch": {"referenceFrame": first + int(differing_locations[0, 0]), "channel": int(differing_locations[0, 1])} if differing_locations.size else None,
                   "maxAbsoluteErrorLSB24": float(np.max(np.abs(errors))) if errors.size else None,
                   "alignedWindowSHA256": sha256(actual.tobytes()), "expectedWindowSHA256": sha256(expected.tobytes())})
    result["fullReferenceFloat32WordsExact"] = bool(not missing_prefix and not missing_suffix and not np.any(words_differ)
                                                       and not prefix_nonzero and not tail_nonzero and first_exact and last_exact)
    return result


def self_tests(reference):
    zeros = np.zeros((79, 2), dtype="<f4")
    padded = np.concatenate([zeros, reference, zeros])
    early, late, changed = padded.copy(), padded.copy(), padded.copy()
    early[78, 0], late[79 + len(reference), 1] = np.float32(1 / SCALE), np.float32(1 / SCALE)
    changed[79 + 12345, 1] = np.nextafter(changed[79 + 12345, 1], np.float32(np.inf))
    head_zero, tail_zero = padded.copy(), padded.copy()
    head_zero[79] = 0
    tail_zero[79 + len(reference) - 1] = 0
    sign_zero = padded.copy()
    zero_location = np.argwhere(reference == 0)[0]
    sign_zero[79 + zero_location[0], zero_location[1]] = np.float32(-0.0)
    cases = [("exactPadded", padded, True), ("missingFirstFrame", reference[1:], False),
             ("missingLastFrame", reference[:-1], False), ("missingFirstFrameReplacedBySilence", head_zero, False),
             ("missingLastFrameReplacedBySilence", tail_zero, False), ("additionalActivePrefixFrame", early, False),
             ("additionalActiveTailFrame", late, False),
             ("internalDroppedFrame", np.delete(padded, 79 + 123456, axis=0), False),
             ("subLSBFloat32Change", changed, False), ("changedZeroSignBit", sign_zero, False)]
    results = []
    for name, capture, expected in cases:
        result = analyze(reference, capture)
        if result["fullReferenceFloat32WordsExact"] != expected:
            raise AssertionError(f"Self-test failed: {name}")
        if name == "missingFirstFrame" and result.get("missingPrefixFrames") != 1:
            raise AssertionError("Missing first frame was not measured")
        if name == "missingLastFrame" and result.get("missingSuffixFrames") != 1:
            raise AssertionError("Missing last frame was not measured")
        if name == "changedZeroSignBit" and (result.get("numericSampleMismatches") != 0 or result.get("float32WordMismatches") != 1):
            raise AssertionError("Float32 word equality was not independently checked")
        results.append({"case": name, "expectedFullPass": expected, "selfTestPassed": True, "analysis": result})
    return results


def load_and_analyze(path, reference, reference_info):
    metadata_path = path.with_suffix(".json")
    metadata_raw = stable_read(metadata_path, 1_000_000)
    metadata = json.loads(metadata_raw)
    raw = stable_read(path, 32_000_000)
    if len(raw) % 8:
        raise ValueError("Partial stereo frame")
    if metadata.get("captureSHA256") != sha256(raw) or metadata.get("canonicalReferenceSHA256") != reference_info["sha256"]:
        raise ValueError("Receipt hash mismatch")
    fmt = metadata["inputFormat"]
    if (fmt["rate"], fmt["channels"], fmt["bits"], fmt["bytesPerFrame"], fmt["formatID"], fmt["flags"]) != (44100, 2, 32, 8, 1819304813, 9):
        raise ValueError("Unexpected tap sample encoding")
    capture = np.frombuffer(raw, dtype="<f4").reshape(-1, 2)
    if metadata["metrics"]["capturedFrames"] != len(capture):
        raise ValueError("Receipt frame count disagrees")
    result = analyze(reference, capture)
    result.update({"captureFile": path.name, "captureSHA256": sha256(raw), "receiptFile": metadata_path.name,
                   "receiptSHA256": sha256(metadata_raw), "sourceCodec": metadata["sourceCodec"],
                   "sourceFileSHA256": metadata["referenceSHA256"], "receiptInvalidBuffers": metadata["metrics"]["invalidBuffers"],
                   "receiptReportedPass": metadata["passed"], "receiptRestorationErrors": metadata["restorationErrors"]})
    if path.read_bytes() != raw or metadata_path.read_bytes() != metadata_raw:
        raise ValueError("Capture changed during analysis")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path, action="append")
    parser.add_argument("--output", type=Path, default=WORK / "spotify-reference-analysis.json")
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    reference, reference_info = read_reference()
    tests = self_tests(reference)
    if arguments.self_test:
        print(json.dumps({"selfTestsPassed": len(tests), "cases": [t["case"] for t in tests]}, indent=2))
        return
    captures = [load_and_analyze(p, reference, reference_info) for p in (arguments.capture or DEFAULT_CAPTURES)]
    report = {"scope": "Original local synthetic fixture at the Spotify process tap; no relay, USB receiver, subscription stream, or streaming master proof",
              "reference": reference_info, "analysisScriptSHA256": sha256(Path(__file__).read_bytes()),
              "method": "Independent raw signed24 RIFF decoding and exact Float32 word comparison over every original stereo frame after one fixed byte-anchor alignment; only zero-valued outer silence is allowed; no ignored internal frames, rounding, resampling, gain fitting, or moving alignment",
              "selfTests": tests, "captures": captures,
              "allCompleteCapturesExact": all(c["fullReferenceFloat32WordsExact"] for c in captures),
              "allActiveSpansByteIdenticalToReference": all(c["activeSpan"]["byteIdenticalToReference"] for c in captures),
              "limits": "PCM equality does not establish callback timestamp continuity, which the original tap receipts do not expose; receipt metrics and restoration fields are retained but do not decide byte equality"}
    with arguments.output.open("x") as file:
        json.dump(report, file, indent=2, allow_nan=False)
        file.write("\n")
    print(json.dumps({"output": str(arguments.output), "selfTestsPassed": len(tests),
                      "captures": [{k: c.get(k) for k in ("sourceCodec", "captureFile", "capturedFrames", "comparedFrames", "float32WordMismatches", "nonzeroLeadingSamples", "nonzeroTrailingSamples", "fullReferenceFloat32WordsExact")} for c in captures]}, indent=2))


if __name__ == "__main__":
    main()
