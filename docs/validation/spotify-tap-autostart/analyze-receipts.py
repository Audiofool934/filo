#!/usr/bin/env python3
"""Deterministic offline audit of the three archived Spotify tap-start trials."""

import argparse
import copy
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import sys

sys.dont_write_bytecode = True
CONTRACT_PATH = Path(__file__).resolve().parent.parent / "spotify-onset/analyze-rejected-reference.py"
spec = importlib.util.spec_from_file_location("rejection_contract", CONTRACT_PATH)
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
STEMS = ("false-direct-start", "false-fresh-retry", "false-mode-on-reference")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def load(path):
    contract.require(path.stat().st_size <= contract.MAX_REPORT_BYTES, "Oversized JSON input.")
    return json.loads(path.read_text(), object_pairs_hook=contract.duplicate_free_object)


def words_hash(words):
    return sha(struct.pack(f"<{len(words)}I", *words))


def compare(left, right):
    contract.require(len(left) == len(right), "Word comparison lengths differ.")
    mismatches = [i for i, (a, b) in enumerate(zip(left, right)) if a != b]
    return {"comparedSampleWords": len(left), "mismatchedSampleWords": len(mismatches),
            "firstMismatchWord": mismatches[0] if mismatches else None,
            "leftSHA256": words_hash(left), "rightSHA256": words_hash(right), "exact": not mismatches}


def zero_hash(size):
    contract.require(type(size) is int and 0 <= size <= 64 * 1024 * 1024, "Unexpected output byte count.")
    digest = hashlib.sha256()
    chunk = bytes(65536)
    while size:
        count = min(size, len(chunk))
        digest.update(chunk[:count])
        size -= count
    return digest.hexdigest()


def timing(watchdog, ui):
    if ui is None:
        return {"playbackWindowCoverageEstablished": False,
                "reason": "The first attempt did not record UI dispatch or armed-event timestamps."}
    events = watchdog["stderrEvents"]
    arm = next(e["observedUTC"] for e in events if "capture armed" in e["message"])
    end = next(e["observedUTC"] for e in events if "verification failed" in e["message"])
    parse = lambda text: datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    deltas = {key: (parse(text) - parse(arm)).total_seconds() for key, text in {
        "beforeClickSecondsAfterArmed": ui["beforeClickUTC"],
        "afterClickSecondsAfterArmed": ui["afterClickUTC"],
        "UIObservationSecondsAfterArmed": ui["afterObservationUTC"],
        "terminalSecondsAfterArmed": end}.items()}
    contract.require(0 <= deltas["beforeClickSecondsAfterArmed"] <= deltas["afterClickSecondsAfterArmed"]
                     <= deltas["UIObservationSecondsAfterArmed"] <= deltas["terminalSecondsAfterArmed"]
                     < watchdog["captureSeconds"], "Unexpected event ordering.")
    return {"armedObservedUTC": arm, **ui, "terminalObservedUTC": end, **deltas,
            "scope": "Wrapper/UI observations, not source-render timestamps; the nonzero rejected callback independently establishes audio arrived during capture."}


def analyze(reference_path, evidence):
    reference = contract.load_reference(reference_path)
    source = Path(__file__).resolve().parent
    prior_path = source.parent / "spotify-prewarm/onset2-original-after-silence.json"
    model_path = source.parent / "spotify-onset/spotify-rejection-onset-model-analysis.json"
    prior = load(prior_path)
    prior_snapshot = contract.parse_snapshot(prior)
    frozen = load(model_path)
    f32 = lambda x: struct.unpack("<f", struct.pack("<f", x))[0]
    alpha, gain, predicted = f32(0.002), 0.0, []
    contract.require(frozen["model"]["alpha"] == alpha and frozen["model"]["initialGain"] == 0,
                     "Frozen model parameters differ.")
    for frame in range(512):
        predicted.extend(contract.bits_from_float(contract.float_from_bits(reference.words[frame * 2 + channel]) * gain)
                         for channel in (0, 1))
        gain = f32(gain + alpha * f32(1 - gain))
    contract.require(words_hash(predicted) == frozen["modelComparisonsAtReferenceOffset0"]["single_round_update"]["predictedFloat32BitsSHA256"],
                     "Frozen model reproduction differs.")
    runs, hashes, snapshots, binary_hashes = [], {}, [], []
    for index, stem in enumerate(STEMS):
        report_path, watchdog_path = evidence / (stem + ".json"), evidence / (stem + "-watchdog.json")
        report, watchdog = load(report_path), load(watchdog_path)
        for path in (report_path, watchdog_path):
            hashes[path.name] = sha(path.read_bytes())
        ui_path = evidence / (stem + "-ui-timing.json")
        ui = load(ui_path) if index else None
        if ui is not None:
            hashes[ui_path.name] = sha(ui_path.read_bytes())
        snapshot = contract.parse_snapshot(report)
        comparison, metrics = report["comparison"], report["metrics"]
        contract.require(watchdog["experimentalTapAutoStart"] is False and watchdog["processExited"] is True
                         and watchdog["termination"] == "normal" and watchdog["exitCode"] == 1,
                         "Unexpected watchdog result.")
        contract.require(report["referenceSHA256"] == watchdog["referenceSHA256"] == reference.file_hash,
                         "Reference identity differs.")
        binary_hashes.append(watchdog["binarySHA256"])
        expected_zero = zero_hash(comparison["totalOutputBytes"])
        checks = {
            "frameAccounting": metrics["capturedFrames"] - metrics["deliveredFrames"] == metrics["queuedFrames"],
            "outputCoverageAccounting": metrics["deliveredFrames"] == metrics["renderedCaptureFrames"] == comparison["capturedFrames"],
            "outputByteAccounting": comparison["totalOutputBytes"] == comparison["capturedFrames"] * 8,
            "zeroTimingAndBufferFaults": all(metrics[k] == 0 for k in ("inputTimestampDiscontinuities", "inputTimestampMissing",
                "outputTimestampDiscontinuities", "outputTimestampMissing", "invalidBuffers", "overflows", "underflows")),
            "referenceWasNotCompared": comparison["comparedFrames"] == comparison["comparedBytes"] == 0,
            "notPassedOrAligned": report["passed"] is False and comparison["passed"] is False
                and comparison["sampleComparison"]["aligned"] is False and comparison["sampleComparison"]["fullReferenceExact"] is False,
            "wholeOutputHashEqualsSilence": comparison["actualCaptureSHA256"] == expected_zero,
            "cleanupErrorsEmpty": report["cleanupErrors"] == [],
        }
        contract.require(all(checks.values()), f"Receipt consistency check failed for {stem}: {checks}")
        run = {"receipt": report_path.name, "order": index + 1,
               "classification": "Setup/coverage failure" if index == 0 else "Complete-reference failure with an off-grid rejected onset",
               "usbDACMode": "Earlier interval unknown" if index < 2 else "User-confirmed enabled before this run; no receiver readback",
               "checks": checks, "capturedOutputFrames": comparison["capturedFrames"],
               "capturedOutputBytes": comparison["totalOutputBytes"], "actualCaptureSHA256": comparison["actualCaptureSHA256"],
               "independentAllZeroSHA256": expected_zero, "fault": metrics["fault"],
               "representationFailures": metrics["representationFailures"],
               "unrenderedAcceptedFramesAtStop": metrics["queuedFrames"],
               "configuredSeconds": watchdog["captureSeconds"], "timing": timing(watchdog, ui)}
        if index == 0:
            contract.require(snapshot is None and metrics["fault"] == metrics["representationFailures"] == 0,
                             "First coverage failure has unexpected rejection evidence.")
            run["limit"] = "All-zero output and an absent snapshot do not establish source silence, onset absence, or playback within the window; accepted queued input was not all rendered."
        else:
            contract.require(snapshot is not None and snapshot["capturedFrames"] == snapshot["callbackFrames"] == 512
                             and snapshot["captureStartFrame"] == 0, "Unexpected onset window.")
            words = snapshot["capturedSampleBits"]
            snapshots.append(words)
            run["rejectionDiagnostic"] = contract.analyze(report, reference)
            run["comparisonWithPriorOnset"] = compare(words, prior_snapshot["capturedSampleBits"])
            run["comparisonWithFrozenModel"] = compare(words, predicted)
            contract.require(run["comparisonWithPriorOnset"]["exact"] and run["comparisonWithFrozenModel"]["exact"],
                             "The retained onset differs from the archived observation or frozen model.")
        runs.append(run)
    contract.require(len(set(binary_hashes)) == 1, "Trial executable hashes differ.")
    mutated = snapshots[0].copy()
    mutated[35] ^= 1
    mutation = compare(mutated, predicted)
    contract.require(mutation["mismatchedSampleWords"] == 1, "One-bit negative control failed.")
    malformed = copy.deepcopy(load(evidence / "false-fresh-retry.json"))
    malformed["rejectionSnapshot"]["rejectedSampleBits"] ^= 1
    try:
        contract.parse_snapshot(malformed)
    except ValueError:
        metadata_rejected = True
    else:
        raise ValueError("Inconsistent offender metadata was accepted.")
    return {"schemaVersion": 1, "scope": "Deterministic offline numerical audit; no hardware calls or source-parameter fitting.",
            "reference": {"fileSHA256": reference.file_hash, "frames": reference.frames, "channels": 2, "bits": 24, "rate": 44100,
                          "all441000IntegerSamplesValidatedAgainstGenerator": True},
            "inputHashes": hashes, "dependencies": {"analyzerSHA256": sha(Path(__file__).read_bytes()),
                "rejectionContractSHA256": sha(CONTRACT_PATH.read_bytes()), "priorOnsetSHA256": sha(prior_path.read_bytes()),
                "frozenModelReceiptSHA256": sha(model_path.read_bytes())},
            "scratchBinarySHA256RecordedByAllWatchdogs": binary_hashes[0],
            "binaryIndependentlyReadByThisOfflineRunner": False,
            "runs": runs, "betweenRetrySnapshots": compare(*snapshots),
            "frozenModel": {"referenceStartFrame": 0, "initialGain": 0, "alpha": alpha,
                "outputRule": "Float32(reference[n,channel] * gain[n])",
                "updateRule": "Float32(gain[n] + Float32(0.002) * Float32(1 - gain[n]))",
                "parameterOrOffsetSearchPerformed": False,
                "arithmetic": "Explicit Float32 conversions use struct; other operations use Python binary64 before the stated final rounding.",
                "alignmentLimit": "Previously established model-dependent offset zero; no exact untransformed anchor or component identification."},
            "offlineControls": {"oneBitMutation": mutation, "inconsistentOffenderMetadataRejected": metadata_rejected},
            "bitPerfectProofFromModel": False,
            "conclusion": "TapAutoStart=false was insufficient in the final user-confirmed-mode condition; both retained 512-frame retries reproduce the prior onset exactly.",
            "limits": ["The first silent attempt is not an onset-absence test.",
                       "Mode intervals for both earlier attempts and historical onset evidence remain unknown.",
                       "No claim is made about samples after the retained 512 frames, responsible component, receiver output, or general player reliability.",
                       "Reconstructed zero hashes use expected bytes and recorded digests, not a second raw capture.",
                       "Empty helper cleanup-error arrays are not a complete settings/default-output restoration audit."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        contract.require(not os.path.lexists(args.output), "Output already exists; nothing changed.")
        result = analyze(args.reference, args.evidence_dir)
        with args.output.open("x") as output:
            output.write(json.dumps(result, indent=2, allow_nan=False) + "\n")
    except (OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        print(f"analyze-receipts: {error}", file=sys.stderr)
        return 1
    print("Offline receipt audit passed; both retained onset windows matched. Playback verification remains failed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
