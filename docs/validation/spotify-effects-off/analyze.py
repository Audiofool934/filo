#!/usr/bin/env python3
"""Offline known-reference audit of a joint Spotify effects-off observation."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / "docs/validation/spotify-tap-autostart/analyze-receipts.py"
spec = importlib.util.spec_from_file_location("archive_audit", HELPER)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
contract = audit.contract
BASELINE = ROOT / "docs/validation/spotify-tap-autostart/false-mode-on-reference.json"
MODEL = ROOT / "docs/validation/spotify-onset/spotify-rejection-onset-model-analysis.json"
FORMAT = {"bits": 32, "bytesPerFrame": 8, "channels": 2, "flags": 76, "formatID": 1819304813, "rate": 44100}


def validate_failed_comparison(report, reference_frames):
    c, s = report["comparison"], report["comparison"]["sampleComparison"]
    contract.require(type(report["passed"]) is bool and type(c["passed"]) is bool,
                     "Receipt and comparison verdicts must be booleans.")
    if report["passed"]:
        return
    contract.require(c["passed"] is False, "Failed receipt contradicts comparison.passed.")
    for field in ("aligned", "windowExact", "fullReferenceExact"):
        contract.require(type(s[field]) is bool, f"sampleComparison.{field} must be boolean.")
    for obj, fields in ((c, ("referenceFrames", "capturedFrames", "comparedFrames", "comparedBytes")),
                        (s, ("referenceFrames", "capturedFrames", "comparedFrames", "referenceStartFrame", "captureStartFrame"))):
        for field in fields:
            contract.require(type(obj[field]) is int and obj[field] >= 0,
                             f"Invalid nonnegative integer comparison field: {field}.")
    contract.require(c["referenceFrames"] == s["referenceFrames"] == reference_frames,
                     "Failed comparison reference counts differ.")
    contract.require(c["comparedFrames"] == s["comparedFrames"]
                     and c["comparedBytes"] == c["comparedFrames"] * FORMAT["bytesPerFrame"],
                     "Failed comparison frame/byte counts disagree.")
    contract.require(s["referenceStartFrame"] + s["comparedFrames"] <= reference_frames
                     and s["captureStartFrame"] + s["comparedFrames"] <= s["capturedFrames"],
                     "Failed comparison span exceeds reference or capture bounds.")
    if not s["aligned"]:
        contract.require(c["comparedFrames"] == 0 and s["windowExact"] is False and s["fullReferenceExact"] is False,
                         "Unaligned failed comparison cannot claim compared frames or exact coverage.")


def analyze(report_path, reference_path):
    reference = contract.load_reference(reference_path)
    report, baseline, frozen = audit.load(report_path), audit.load(BASELINE), audit.load(MODEL)
    snapshot = contract.parse_snapshot(report)
    baseline_snapshot = contract.parse_snapshot(baseline)
    c, s, m = report["comparison"], report["comparison"]["sampleComparison"], report["metrics"]
    validate_failed_comparison(report, reference.frames)
    expected = b"".join(struct.pack("<i", int(contract.float_from_bits(word) * (1 << 23)) << 8) for word in reference.words)
    expected_sha = hashlib.sha256(expected).hexdigest()
    contract.require(expected_sha == c["expectedReferenceSHA256"], "Expected signed32 reference differs.")
    checks = {
        "formatExactlySigned32Stereo44100": report["output"] == report["physical"] == c["outputFormat"] == FORMAT,
        "frameAccounting": m["capturedFrames"] - m["deliveredFrames"] == m["queuedFrames"],
        "outputFrameAccounting": m["deliveredFrames"] == m["renderedCaptureFrames"] == c["capturedFrames"] == s["capturedFrames"],
        "outputByteAccounting": c["totalOutputBytes"] == c["capturedFrames"] * 8,
        "zeroTimingAndBufferFaults": all(m[k] == 0 for k in ("inputTimestampDiscontinuities", "inputTimestampMissing",
            "outputTimestampDiscontinuities", "outputTimestampMissing", "invalidBuffers", "overflows", "underflows")),
        "cleanupErrorsEmpty": report["cleanupErrors"] == [],
    }
    result = {"schemaVersion": 1, "scope": "Offline joint-effects-off trial analysis; no player, hardware, receiver readback, parameter fit, or source-offset search.",
        "referenceSHA256": reference.file_hash, "referenceFrames": reference.frames,
        "all441000ReferenceIntegersValidatedAgainstGenerator": True,
        "expectedSigned32ReferenceSHA256": expected_sha,
        "inputReportSHA256": audit.sha(report_path.read_bytes()), "baselineReceiptSHA256": audit.sha(BASELINE.read_bytes()),
        "frozenModelReceiptSHA256": audit.sha(MODEL.read_bytes()), "analyzerSHA256": audit.sha(Path(__file__).read_bytes()),
        "existingAuditHelperSHA256": audit.sha(HELPER.read_bytes()), "existingParserSHA256": audit.sha(audit.CONTRACT_PATH.read_bytes()),
        "receiptPassed": report["passed"], "fault": m["fault"], "representationFailures": m["representationFailures"],
        "checks": checks, "comparedReferenceFrames": c["comparedFrames"], "comparedReferenceBytes": c["comparedBytes"],
        "capturedOutputFrames": c["capturedFrames"], "capturedOutputBytes": c["totalOutputBytes"],
        "actualCaptureSHA256": c["actualCaptureSHA256"],
        "effectCondition": "User disabled Gapless and Automix while Crossfade remained OFF; joint-settings observation, not a single-factor intervention.",
        "preferenceBoundary": "The user-selected OFF settings must remain OFF; this analyzer does not change settings.",
        "comparisonLimit": "The preceding baseline is a separate observation, not a randomized matched trial or causal attribution.",
        "receiverMeasured": False}
    if report["passed"] is True:
        lead, tail = s["leadingCaptureFrames"], s["trailingCaptureFrames"]
        contract.require(type(lead) is int and type(tail) is int and 0 <= lead <= 44100 * 120
                         and 0 <= tail <= 44100 * 120, "Invalid full-capture margins.")
        digest = hashlib.sha256(bytes(lead * 8) + expected + bytes(tail * 8)).hexdigest()
        success_checks = {
            "completeFramesAndBytes": c["comparedFrames"] == s["comparedFrames"] == reference.frames == 220500
                and c["comparedBytes"] == len(expected) == 1764000,
            "validExactComparison": all(c[k] is True for k in ("passed", "validFormat", "rateMatches", "exactReferencePrecision", "captureWellFormed"))
                and all(s[k] is True for k in ("aligned", "fullReferenceExact", "windowExact")) and s["alignmentAmbiguous"] is False,
            "wholeReferenceAlignment": s["referenceStartFrame"] == s["missingPrefixFrames"] == s["missingSuffixFrames"] == 0
                and s["captureStartFrame"] == lead and lead + reference.frames + tail == c["capturedFrames"],
            "zeroMismatchesPaddingAndOutsideAudio": all(c[k] == 0 for k in ("mismatchedBytes", "mismatchedFrames", "mismatchedSampleWords",
                "nonzeroLeadingBytes", "nonzeroPaddingBytes", "nonzeroTrailingBytes", "paddingBits"))
                and all(s[k] == 0 for k in ("mismatchedSamples", "maxIntegerError", "nonzeroLeadingSamples", "nonzeroTrailingSamples")),
            "exactExpectedAndActualAlignedHashes": c["actualAlignedSHA256"] == c["expectedAlignedSHA256"] == expected_sha,
            "wholeCaptureHashReproduced": c["actualCaptureSHA256"] == digest,
            "noFaultOrSnapshot": m["fault"] == m["representationFailures"] == m["startupSilenceFrames"] == 0 and snapshot is None,
        }
        result.update({"completeReferenceChecks": success_checks, "leadingCaptureFrames": lead, "trailingCaptureFrames": tail,
                       "independentExpectedWholeCaptureSHA256": digest,
                       "classification": "Complete known reference matches at software output callback" if all(checks.values()) and all(success_checks.values())
                           else "A reported pass failed independent receipt consistency checks",
                       "wholeReferenceSoftwarePassValidated": all(checks.values()) and all(success_checks.values()),
                       "hashBoundary": "Independent expected-byte reconstruction checked against receipt digests; raw output is not recaptured or read from the receiver."})
    elif snapshot is not None:
        diagnostic = contract.analyze(report, reference)
        words = snapshot["capturedSampleBits"]
        base_words = baseline_snapshot["capturedSampleBits"]
        same_bounds = all(snapshot[k] == baseline_snapshot[k] for k in ("captureStartFrame", "capturedFrames", "callbackFrames"))
        comparison = audit.compare(words, base_words) if same_bounds else {"comparableWholeWindow": False, "reason": "Snapshot bounds differ; no source alignment assumed."}
        model_result = {"assessed": False, "reason": "Only the previously established 512-frame window starting at callback frame zero is supported."}
        if snapshot["capturedFrames"] == snapshot["callbackFrames"] == 512 and snapshot["captureStartFrame"] == 0:
            f32 = lambda x: struct.unpack("<f", struct.pack("<f", x))[0]
            alpha, gain, predicted = f32(0.002), 0.0, []
            contract.require(frozen["model"]["alpha"] == alpha and frozen["model"]["initialGain"] == 0, "Frozen model changed.")
            for frame in range(512):
                predicted.extend(contract.bits_from_float(contract.float_from_bits(reference.words[frame * 2 + channel]) * gain) for channel in (0, 1))
                gain = f32(gain + alpha * f32(1 - gain))
            contract.require(audit.words_hash(predicted) == frozen["modelComparisonsAtReferenceOffset0"]["single_round_update"]["predictedFloat32BitsSHA256"], "Frozen prediction differs.")
            model_result = {"assessed": True, "referenceStartFrame": 0, "initialGain": 0, "alpha": alpha,
                            "parameterOrOffsetSearchPerformed": False, "comparison": audit.compare(words, predicted),
                            "limit": "A fixed model-dependent alignment, not an unchanged-source anchor or responsible-component identification."}
        result.update({"classification": "Complete-reference failure with retained rejected input", "wholeReferenceSoftwarePassValidated": False,
            "rejectionDiagnostic": diagnostic, "comparisonWithPreviousModeOnSnapshot": comparison, "frozenModel": model_result,
            "outputHashEqualsZeros": c["actualCaptureSHA256"] == audit.zero_hash(c["totalOutputBytes"]),
            "sameOnsetAsPrevious": comparison.get("exact") is True and model_result.get("comparison", {}).get("exact") is True})
    else:
        result.update({"classification": "No complete-reference pass and no retained rejection; coverage or other failure requires separate interpretation",
            "wholeReferenceSoftwarePassValidated": False, "outputHashEqualsZeros": c["actualCaptureSHA256"] == audit.zero_hash(c["totalOutputBytes"]),
            "limit": "Snapshot absence and zero mismatches do not establish onset absence or successful playback."})
    result["auditConsistent"] = all(checks.values()) and (not report["passed"] or result["wholeReferenceSoftwarePassValidated"])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        contract.require(not os.path.lexists(args.output), "Output exists; nothing changed.")
        result = analyze(args.report, args.reference)
        with args.output.open("x") as handle:
            handle.write(json.dumps(result, indent=2, allow_nan=False) + "\n")
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"analyze: {error}", file=sys.stderr)
        return 1
    print(json.dumps({k: result[k] for k in ("classification", "auditConsistent", "wholeReferenceSoftwarePassValidated")}))
    return 0 if result["auditConsistent"] else 1


if __name__ == "__main__":
    sys.exit(main())
