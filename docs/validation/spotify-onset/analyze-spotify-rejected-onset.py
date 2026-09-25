#!/usr/bin/env python3
"""Post-hoc gain-model diagnostics for one known synthetic rejected callback."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import wave

REFERENCE_SHA = "43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e"
OUTPUT_SHA = "8fd04325bfb401bac8d2700c967453319a12e7ead41dde6ee04505e64e118ea5"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def f32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


def bits(value):
    return struct.unpack("<I", struct.pack("<f", value))[0]


def value(word):
    return struct.unpack("<f", struct.pack("<I", word))[0]


def words_sha(words):
    return sha(struct.pack(f"<{len(words)}I", *words))


def load_json(path):
    with path.open("rb") as handle:
        raw = handle.read(2 * 1024 * 1024 + 1)
    require(len(raw) <= 2 * 1024 * 1024, "Bounded report size exceeded.")
    report = json.loads(raw)
    require(report.get("referenceSHA256") == REFERENCE_SHA, "Unexpected reference identity.")
    require(report.get("rejectionInspectionRequested") is True, "Inspection was not requested.")
    return report, sha(raw)


def gain_sequence(count, model, alpha=0.002):
    a, retention, gain = f32(alpha), f32(1 - alpha), 0.0
    gains = []
    for frame in range(count):
        gains.append(gain)
        if model == "single_round_update":
            gain = f32(gain + a * f32(1 - gain))
        elif model == "double_difference_update":
            gain = f32(gain + a * (1 - gain))
        elif model == "separately_rounded_product":
            gain = f32(gain + f32(a * f32(1 - gain)))
        elif model == "double_closed_form":
            gain = 1 - (1 - alpha) ** (frame + 1)
        elif model == "float_closed_form":
            gain = f32(1 - (1 - alpha) ** (frame + 1))
        elif model == "separate_weighted_sum":
            gain = f32(f32(gain * retention) + a)
        elif model == "single_round_weighted_sum":
            gain = f32(gain * retention + a)
        elif model == "linear":
            gain = f32((frame + 1) * a)
        elif model == "unity":
            gain = 1.0
        else:
            raise ValueError("Unknown model.")
    return [1.0] * count if model == "unity" else gains


def predict(reference, start, gains):
    return [bits(reference[(start + frame) * 2 + channel] * gain)
            for frame, gain in enumerate(gains) for channel in (0, 1)]


def compare(predicted, captured):
    require(len(predicted) == len(captured), "Comparison lengths differ.")
    mismatches = [i for i, pair in enumerate(zip(predicted, captured)) if pair[0] != pair[1]]
    first = mismatches[0] if mismatches else None
    return {
        "comparedSampleWords": len(captured),
        "mismatchedSampleWords": len(mismatches),
        "mismatchedFrames": len({i // 2 for i in mismatches}),
        "maximumAbsoluteErrorIn24BitLSB": max(abs(value(a) - value(b)) * (1 << 23) for a, b in zip(predicted, captured)),
        "predictedFloat32BitsSHA256": words_sha(predicted),
        "capturedFloat32BitsSHA256": words_sha(captured),
        "firstMismatch": {"frame": first // 2, "channel": first % 2,
                          "predictedBitsHex": f"0x{predicted[first]:08x}",
                          "capturedBitsHex": f"0x{captured[first]:08x}"} if first is not None else None,
    }


def analyze(args):
    raw_reference = args.reference.read_bytes()
    require(sha(raw_reference) == REFERENCE_SHA, "Only the original synthetic WAV is allowed.")
    with wave.open(str(args.reference), "rb") as wav:
        require((wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes())
                == (2, 3, 44100, 220500), "Wrong reference format.")
        pcm = wav.readframes(220500)
    reference = [int.from_bytes(pcm[i:i + 3], "little", signed=True) / (1 << 23) for i in range(0, len(pcm), 3)]
    report, report_hash = load_json(args.report)
    snapshot = report.get("rejectionSnapshot", {})
    require(snapshot.get("available") is True and snapshot.get("captureStartFrame") == 0
            and snapshot.get("capturedFrames") == snapshot.get("callbackFrames") == 512,
            "This frozen exploratory model is scoped to the complete 512-frame callback beginning at callback frame0.")
    captured = snapshot.get("capturedSampleBits")
    require(type(captured) is list and len(captured) == 1024
            and all(type(w) is int and 0 <= w < (1 << 32) and math.isfinite(value(w)) for w in captured),
            "Expected1024 finite raw Float32 words.")
    require(report["metrics"]["fault"] == 5, "Expected a representation rejection.")
    count = 512
    models = ["unity", "linear", "double_closed_form", "float_closed_form", "separately_rounded_product",
              "single_round_update", "double_difference_update", "separate_weighted_sum", "single_round_weighted_sum"]
    results = {model: compare(predict(reference, 0, gain_sequence(count, model)), captured) for model in models}
    gains = gain_sequence(count, "single_round_update")
    expected = predict(reference, 0, gains)

    # Search only contiguous source windows fully covering the captured512 frames.
    # Eight stereo probes cheaply reject offsets; every surviving window is then compared in full.
    probes = [1, 2, 3, 7, 31, 127, 255, 511]
    candidates = []
    for start in range(220500 - count + 1):
        if all(bits(reference[(start + frame) * 2 + channel] * gains[frame]) == captured[frame * 2 + channel]
               for frame in probes for channel in (0, 1)):
            candidates.append(start)
    full_candidates = [{"referenceStartFrame": start, **compare(predict(reference, start, gains), captured)} for start in candidates]

    controls = []
    for name, predicted in [
        ("reference_offset_plus1", predict(reference, 1, gains)),
        ("alpha0.001999", predict(reference, 0, gain_sequence(count, "single_round_update", 0.001999))),
        ("alpha0.002001", predict(reference, 0, gain_sequence(count, "single_round_update", 0.002001))),
        ("swapped_reference_channels", [expected[i ^ 1] for i in range(len(expected))]),
    ]:
        comparison = compare(predicted, captured)
        require(comparison["mismatchedSampleWords"] > 0, "Negative model control unexpectedly matched.")
        controls.append({"name": name, "expectedMismatchObserved": True, **comparison})
    corrupted = captured.copy()
    corrupted[17 * 2 + 1] ^= 1
    comparison = compare(expected, corrupted)
    require(comparison["mismatchedSampleWords"] == results["single_round_update"]["mismatchedSampleWords"] + 1,
            "One-bit corruption control failed.")
    controls.append({"name": "one_bit_change_outside_probe_frames", "expectedMismatchObserved": True, **comparison})

    repeat, repeat_hash = load_json(args.repeat_report)
    comparison, sample, metrics = repeat["comparison"], repeat["comparison"]["sampleComparison"], repeat["metrics"]
    require(repeat.get("passed") is True and comparison["passed"] and sample["fullReferenceExact"]
            and comparison["comparedFrames"] == 220500 and comparison["comparedBytes"] == 1764000
            and comparison["actualAlignedSHA256"] == comparison["expectedAlignedSHA256"] == OUTPUT_SHA
            and not sample["alignmentAmbiguous"] and repeat["cleanupErrors"] == []
            and repeat.get("rejectionSnapshot") is None, "Repeat receipt does not prove the stated finite software-output comparison.")
    for field in ["mismatchedBytes", "mismatchedSampleWords", "mismatchedFrames", "nonzeroLeadingBytes", "nonzeroTrailingBytes", "nonzeroPaddingBytes"]:
        require(comparison[field] == 0, "Repeat mismatch counter is nonzero.")
    for field in ["fault", "representationFailures", "inputTimestampMissing", "outputTimestampMissing",
                  "inputTimestampDiscontinuities", "outputTimestampDiscontinuities", "underflows", "overflows", "invalidBuffers", "startupSilenceFrames"]:
        require(metrics[field] == 0, "Repeat fault or timing counter is nonzero.")
    require(sample["leadingCaptureFrames"] + 220500 + sample["trailingCaptureFrames"] == comparison["capturedFrames"], "Repeat boundaries differ.")
    require(metrics["deliveredFrames"] == metrics["renderedCaptureFrames"] == comparison["capturedFrames"], "Repeat capture coverage differs.")
    return {
        "schemaVersion": 1,
        "scope": "Exploratory post-hoc model of one original-synthetic512-frame rejection; no hardware or player access.",
        "inputReportSHA256": report_hash, "referenceSHA256": REFERENCE_SHA,
        "modelSelectionDisclosure": "The0.002 coefficient was hypothesized after inspecting the actual ratios; this is not a preregistered test or a DSP implementation identification.",
        "model": {"alpha": f32(0.002), "initialGain": 0,
                  "outputRule": "Float32(reference[n,channel] * gain[n])",
                  "updateRule": "gain[n+1] = Float32(gain[n] + Float32(0.002) * Float32(1 - gain[n]))",
                  "arithmetic": "Each stated Float32 conversion uses Python struct pack/unpack; multiply and addition otherwise use Python binary64 before one final Float32 rounding.",
                  "gain511": gains[511], "initialGainAppliesToBothChannels": True},
        "sourcePositionHypothesis": {"searchedReferenceOffsets": 220500 - count + 1,
                                     "probeFrames": probes, "survivingProbeOffsets": candidates,
                                     "fullCandidateComparisons": full_candidates,
                                     "scope": "Only nonnegative contiguous reference offsets with a complete512-frame window; model-dependent alignment, not an exact unprocessed-audio anchor."},
        "modelComparisonsAtReferenceOffset0": results,
        "negativeControls": controls,
        "sameFileRepeatControl": {"receiptSHA256": repeat_hash, "fullReferenceExactAtSoftwareOutput": True,
                                  "referenceFrames": 220500, "referenceBytes": 1764000,
                                  "actualAlignedSHA256": comparison["actualAlignedSHA256"],
                                  "silentPrefixFrames": sample["leadingCaptureFrames"],
                                  "silentSuffixFrames": sample["trailingCaptureFrames"],
                                  "capturedFrames": comparison["capturedFrames"],
                                  "rejectionSnapshotAbsent": True, "cleanupErrors": []},
        "limits": ["The original rejected samples differ from unprocessed reference audio; exact agreement with a transformation model is not bit-perfect playback.",
                   "Multiple arithmetic formulations can reproduce these512 frames; the data do not identify a unique implementation or component.",
                   "The full first playback, waveform after frame511, USB receiver, and analog output are unmeasured by this snapshot.",
                   "Same-file replay success is an independent observation, not proof of startup causality.",
                   "A zero initial gain discards the first frame in this model; this analysis does not propose inverse-gain recovery or rounding as a repair."],
        "bitPerfectProofFromModel": False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--repeat-report", type=Path, required=True)
    parser.add_argument("--reference", type=Path, default=Path("work/filo-reference-44100-24.wav"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(not args.output.exists(), "Output already exists.")
    result = analyze(args)
    result["analyzerSourceSHA256"] = sha(Path(__file__).read_bytes())
    encoded = json.dumps(result, indent=2, allow_nan=False) + "\n"
    with args.output.open("x") as handle:
        handle.write(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    main()
