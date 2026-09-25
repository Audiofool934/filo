#!/usr/bin/env python3
"""Adapted reproducer added after the original two inline Python audit commands.

This is not a frozen file that existed when independent-analysis.json was first
written. It combines the executed numerical audit and its explanatory annotation
step, adds explicit paths, and always emits a fresh analysis timestamp.
No audio, HAL, player, or network operations are performed.

For full historical semantic reproduction, supply the retained measured binary
with --helper-binary. Without it, hashes are checked against the build manifest
and receipts only, and the output explicitly records that weaker provenance.
"""

import argparse
import hashlib
import json
import struct
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo


def sha(data):
    return hashlib.sha256(data).hexdigest()


def load_json(path):
    data = path.read_bytes()
    return json.loads(data), sha(data)


def require(value, message):
    if not value:
        raise ValueError(message)


def reference_bytes(path):
    reference = path.read_bytes()
    require(sha(reference) ==
            "43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e",
            "Reference is not the canonical synthetic WAV.")
    require(reference[:4] == b"RIFF" and reference[8:12] == b"WAVE"
            and struct.unpack_from("<I", reference, 4)[0] + 8 == len(reference),
            "Invalid RIFF header.")
    chunks, offset = {}, 12
    while offset < len(reference):
        key = reference[offset:offset + 4]
        size = struct.unpack_from("<I", reference, offset + 4)[0]
        chunks[key] = reference[offset + 8:offset + 8 + size]
        offset += 8 + size + (size & 1)
    require(struct.unpack("<HHIIHH", chunks[b"fmt "]) ==
            (1, 2, 44100, 264600, 6, 24), "Unexpected reference format.")
    raw = chunks[b"data"]
    require(len(raw) == 220500 * 6, "Unexpected reference payload length.")
    integers = [int.from_bytes(raw[i:i + 3], "little", signed=True)
                for i in range(0, len(raw), 3)]
    for index, value in enumerate(integers):
        frame, channel = divmod(index, 2)
        word = frame ^ (0xc2b2ae35 if channel else 0x27d4eb2f)
        word ^= word >> 16
        word = word * 0x7feb352d & 0xffffffff
        word ^= word >> 15
        word = word * 0x846ca68b & 0xffffffff
        word ^= word >> 16
        require(value == (word & 16383) - 8192,
                f"Generator mismatch at frame {frame}, channel {channel}.")
    expected = b"".join(struct.pack("<i", value << 8) for value in integers)
    require(len(expected) == 1764000, "Unexpected signed32 byte count.")
    return reference, integers, expected


def analyze_run(base, filename, mode, setters, reference_hash, expected, binary_hash):
    receipt, receipt_hash = load_json(base / filename)
    comparison = receipt["comparison"]
    sample = comparison["sampleComparison"]
    metrics, pre_go = receipt["metrics"], receipt["preGOMetrics"]
    events = receipt["childEvents"]
    ready = next(event for event in events if event["event"] == "ready")
    go = next(event for event in events if event["event"] == "goAccepted")
    stopped = next(event for event in events if event["event"] == "stopped")
    calls = stopped["calls"]
    operations = [call["operation"] for call in calls]
    call = {item["operation"]: item for item in calls}
    prefix, tail = sample["leadingCaptureFrames"], sample["trailingCaptureFrames"]
    require(isinstance(prefix, int) and isinstance(tail, int)
            and 0 <= prefix <= 44100 * 20 and 0 <= tail <= 44100 * 20,
            "Capture margins exceed the bounded experiment.")
    capture = bytes(prefix * 8) + expected + bytes(tail * 8)
    aligned_hash, capture_hash = sha(expected), sha(capture)
    watchdog_name = filename.replace(".json", "-watchdog.json")
    watchdog, watchdog_hash = load_json(base / watchdog_name)
    started_utc = datetime.fromisoformat(watchdog["startedUTC"])
    started_local = started_utc.astimezone(ZoneInfo("Asia/Singapore"))
    expected_format = {"bits": 32, "bytesPerFrame": 8, "channels": 2,
                       "flags": 76, "formatID": 1819304813, "rate": 44100}
    checks = {
        "canonicalSourceSHA256Matches": receipt["referenceSHA256"] == reference_hash == ready["referenceSHA256"],
        "binaryMatchesReceiptAndBuildManifest": receipt["binarySHA256"] == binary_hash == watchdog["binarySHA256"],
        "modeMatches": receipt["mode"] == mode == watchdog["mode"],
        "expectedActualAlignedHashesMatch": all(comparison[key] == aligned_hash for key in ["actualAlignedSHA256", "expectedAlignedSHA256", "expectedReferenceSHA256"]),
        "fullCaptureHashMatchesReconstructedReferenceAndZeroMargins": comparison["actualCaptureSHA256"] == capture_hash,
        "wholeReferenceCountsMatch": comparison["referenceFrames"] == sample["referenceFrames"] == comparison["comparedFrames"] == sample["comparedFrames"] == 220500 and comparison["comparedBytes"] == len(expected),
        "marginAndTotalByteCountsMatch": prefix + 220500 + tail == comparison["capturedFrames"] == sample["capturedFrames"] == metrics["deliveredFrames"] == metrics["renderedCaptureFrames"] and len(capture) == comparison["totalOutputBytes"],
        "referenceStartsAtFrameZero": sample["referenceStartFrame"] == 0 and sample["captureStartFrame"] == prefix,
        "integerStereo44100PhysicalAndCallbackFormatsMatch": receipt["outputFormat"] == receipt["physicalFormat"] == comparison["outputFormat"] == expected_format,
        "wholeReferenceAndFormatPassFieldsTrue": receipt["passed"] and all(comparison[key] for key in ["passed", "captureWellFormed", "validFormat", "exactReferencePrecision", "rateMatches"]) and all(sample[key] for key in ["aligned", "fullReferenceExact", "windowExact"]) and not sample["alignmentAmbiguous"],
        "zeroMismatchAndMissingEdgeCounts": all(comparison[key] == 0 for key in ["mismatchedBytes", "mismatchedFrames", "mismatchedSampleWords", "nonzeroLeadingBytes", "nonzeroTrailingBytes", "nonzeroPaddingBytes", "paddingBits"]) and all(sample[key] == 0 for key in ["mismatchedSamples", "maxIntegerError", "missingPrefixFrames", "missingSuffixFrames", "nonzeroLeadingSamples", "nonzeroTrailingSamples"]),
        "zeroBridgeFaultCounts": all(metrics[key] == 0 for key in ["fault", "invalidBuffers", "representationFailures", "underflows", "overflows", "startupSilenceFrames", "inputTimestampMissing", "outputTimestampMissing", "inputTimestampDiscontinuities", "outputTimestampDiscontinuities"]),
        "inputFrameAccountingBalances": metrics["capturedFrames"] == metrics["deliveredFrames"] + metrics["queuedFrames"],
        "preGOFrameAccountingBalances": pre_go["capturedFrames"] == pre_go["deliveredFrames"] + pre_go["queuedFrames"],
        "allRecordedPrimitiveCallsSucceeded": all(item["status"] == 0 for item in calls),
        "explicitUnityCallCountMatchesArm": operations.count("setVolumeUnityOnce") == setters,
        "noOtherSetterPresent": set(operation for operation in operations if operation.startswith("set")) == ({"setCurrentDeviceBlackHole", "setVolumeUnityOnce"} if setters else {"setCurrentDeviceBlackHole"}),
        "singleReferenceThenPostrollOnly": ready["metrics"]["referenceEnqueueCount"] == stopped["metrics"]["referenceEnqueueCount"] == 1 and ready["metrics"]["referenceFramesEnqueued"] == 220500 and ready["metrics"]["zeroFramesEnqueued"] == 441000 and operations.index("enqueueBuffer1") < operations.index("enqueueBuffer2") and receipt["sourcePrefixFramesEnqueued"] == 0,
        "readySourceUnstartedAndNoReturnedBuffers": ready["metrics"]["startCalls"] == 0 and ready["metrics"]["startSucceeded"] is False and ready["metrics"]["lastRunningReadValue"] is False and ready["metrics"]["framesReturnedForReuse"] == 0,
        "sourceCallbacksRemainZeroThroughPostStartGoAcknowledgement": go["metrics"]["framesReturnedForReuse"] == go["metrics"]["referenceBuffersReturnedForReuse"] == go["metrics"]["zeroBuffersReturnedForReuse"] == 0,
        "exactlyOneSuccessfulFirstStart": operations.count("firstStartAfterGO") == go["metrics"]["startCalls"] == stopped["metrics"]["startCalls"] == 1 and go["metrics"]["startSucceeded"] and stopped["metrics"]["startSucceeded"],
        "noExplicitPrimeOrSeparateSilentRenderer": receipt["audioQueuePrimeCalls"] == receipt["separateSilentRenderers"] == 0,
        "queueReadyRelayStartReturnedGOBeforeFirstStartReadbackOrdered": ready["monotonicSeconds"] < receipt["relayStartRequestedAt"] < receipt["relayStartReturnedAt"] < receipt["goSentAt"] < call["immediatelyBeforeFirstStart.rampSeconds"]["monotonicSeconds"] < call["firstStartAfterGO"]["monotonicSeconds"] <= go["monotonicSeconds"],
        "parameterReadbacksAllUnityAndZeroRamp": all(item["value"] == (0 if item["operation"].endswith(".rampSeconds") else 1) for item in calls if ".volume" in item["operation"] or ".rampSeconds" in item["operation"]),
        "registeredUnrunningSourceBeforeGO": receipt["childProcessObjectsBeforeGO"] == 1 and receipt["childProcessRunningBeforeGO"] is False,
        "experimentalTapAutoStartFalse": receipt["experimentalTapAutoStart"] is False,
        "captureHasAtLeastTwoSecondsTail": tail >= 88200,
        "cleanupAndWatchdogNormal": receipt["cleanupErrors"] == stopped["cleanupErrors"] == [] and watchdog["exitCode"] == 0 and watchdog["termination"] == "normal" and watchdog["parentExited"],
    }
    failures = [key for key, passed in checks.items() if not passed]
    times = {
        "ready": ready["monotonicSeconds"],
        "relayStartRequested": receipt["relayStartRequestedAt"],
        "relayStartReturned": receipt["relayStartReturnedAt"],
        "goSent": receipt["goSentAt"],
        "lastPreStartParameterReadReturned": call["immediatelyBeforeFirstStart.rampSeconds"]["monotonicSeconds"],
        "AudioQueueStartCallReturnedAndLogged": call["firstStartAfterGO"]["monotonicSeconds"],
        "goAcknowledged": go["monotonicSeconds"],
        "firstObservedReferenceBufferReusable": next(event["monotonicSeconds"] for event in events if event.get("metrics", {}).get("referenceBuffersReturnedForReuse", 0) > 0),
        "sourceStoppedEvent": stopped["monotonicSeconds"],
    }
    durations = {
        "relayStartCallSeconds": times["relayStartReturned"] - times["relayStartRequested"],
        "readyToGOSeconds": times["goSent"] - times["ready"],
        "GOToLastPreStartReadSeconds": times["lastPreStartParameterReadReturned"] - times["goSent"],
        "GOToStartReturnSeconds": times["AudioQueueStartCallReturnedAndLogged"] - times["goSent"],
        "preGOAggregateCapturedSeconds": pre_go["capturedFrames"] / 44100,
        "referenceLeadingCaptureSeconds": prefix / 44100,
        "tailSeconds": tail / 44100,
    }
    return {
        "receipt": filename, "receiptSHA256": receipt_hash,
        "watchdog": watchdog_name, "watchdogSHA256": watchdog_hash,
        "mode": mode, "startedUTC": started_utc.isoformat(),
        "startedAsiaSingapore": started_local.isoformat(),
        "allChecksPassed": not failures, "failedChecks": failures, "checks": checks,
        "recomputedAlignedSHA256": aligned_hash,
        "reconstructedFullCaptureSHA256": capture_hash,
        "leadingCaptureFrames": prefix, "referenceFrames": 220500,
        "trailingCaptureFrames": tail, "capturedOutputFrames": comparison["capturedFrames"],
        "capturedOutputBytes": len(capture), "preGOAggregateMetrics": pre_go,
        "finalRelayMetrics": metrics, "sourceStateAtReady": ready["metrics"],
        "sourceStateAtGoAcknowledgement": go["metrics"],
        "sourceStateAtStop": stopped["metrics"], "monotonicTimes": times,
        "durations": durations, "recordedPrimitiveCalls": calls,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--helper-source", type=Path, required=True)
    parser.add_argument("--helper-binary", type=Path,
                        help="Optional retained measured executable, hashed only, never run.")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Refusing to overwrite the output file.")
    reference, integers, expected = reference_bytes(args.reference)
    source = args.helper_source.read_bytes()
    build, _ = load_json(args.evidence_dir / "build-manifest.json")
    source_hash = sha(source)
    require(source_hash == build["sourceSHA256"], "Helper source differs from the build manifest.")
    binary_hash = (sha(args.helper_binary.read_bytes()) if args.helper_binary
                   else build["binarySHA256"])
    require(binary_hash == build["binarySHA256"], "Binary differs from the build manifest.")
    require(b"AudioQueuePrime(" not in source and source.count(b"AudioQueueStart(") == 1,
            "Helper call-site structure differs from the audited source.")
    runs = [analyze_run(args.evidence_dir, filename, mode, setters,
                        sha(reference), expected, binary_hash)
            for filename, mode, setters in [
                ("default-first-start.json", "default", 0),
                ("unity-first-start.json", "explicit-unity", 1)]]
    local_dates = {run["startedAsiaSingapore"][:10] for run in runs}
    utc_dates = {run["startedUTC"][:10] for run in runs}
    require(len(local_dates) == len(utc_dates) == 1, "Runs span different measurement dates.")
    result = {
        "schemaVersion": 1,
        "analysisType": "Independent offline receipt consistency and canonical-byte reconstruction",
        "createdUTC": datetime.now(timezone.utc).isoformat(),
        "localMeasurementDate": next(iter(local_dates)),
        "UTCMeasurementDate": next(iter(utc_dates)),
        "reference": {
            "filename": "filo-reference-44100-24.wav", "fileSHA256": sha(reference),
            "sampleRate": 44100, "channels": 2, "bits": 24, "frames": 220500,
            "generatorSamplesIndependentlyChecked": len(integers),
            "firstStereoSigned24Samples": integers[:2],
            "lastStereoSigned24Samples": integers[-2:],
            "signed32LittleEndianAlignedSHA256": sha(expected),
        },
        "helperProvenance": {
            "sourceSHA256": source_hash, "binarySHA256": binary_hash,
            "matchesExistingBuildManifest": True,
            "sourceAudioQueueStartCallSites": 1,
            "sourceExplicitAudioQueuePrimeCallSites": 0,
            "callTimestampsRecordedAfterAPIReturn": True,
            "sourceEnqueueOrderVerified": "Canonical reference from frame zero first; 441000 all-zero frames second; no preceding source-zero buffer.",
        },
        "allChecksPassed": all(run["allChecksPassed"] for run in runs),
        "runs": runs,
        "conclusions": [
            "Both full canonical reference spans independently reconstruct the aligned signed32 hash and each reported full-capture hash when combined with the reported zero margins.",
            "No source AudioQueue Start or explicit Prime precedes GO in the inspected control flow and receipts; source buffer-return counters remain zero through the acknowledgement emitted after first Start returns.",
            "Aggregate pre-GO capture is not source prewarm: default captured 18432/delivered 0 frames; unity captured 20992/delivered 512 frames while the source queue remained unstarted.",
            "The only intended source configuration difference is one explicit unity-volume call; both arms report volume 1 and ramp-time 0 at every successful parameter readback.",
            "Both arms use experimental TapAutoStart=false; these observations do not establish equivalent first-start behavior in production TapAutoStart=true or in Spotify.",
        ],
        "limits": [
            "Raw capture bytes were not independently available: the full-capture hash is independently reconstructed from canonical WAV bytes and receipt margins, then compared with the logged capture hash. This checks consistency of the evidence, not a second hardware capture.",
            "Primitive-call timestamps are recorded after return; the exact AudioQueueStart invocation instant and source render-callback timestamps are not recorded. The source control flow bounds the call after GO and the last immediately-before-start parameter read.",
            "Registration/running snapshots and event timestamps are observations, not a public contract that every fresh AudioQueue exposes a pre-start process.",
            "The goAccepted metrics carry the last IsRunning read made during readiness; that false value is not a fresh post-Start read. The successful first Start and later running=true status observations are separate evidence.",
            "Durations derived from frame counts divide by the nominal 44100 Hz rate and are not independently measured wall-clock durations.",
            "Aggregate callbacks existed before GO in both runs; the no-before-GO-callback claim applies only to source AudioQueue buffer callbacks, not the relay.",
            "Post-stop buffer-return counts include the zero buffer released during stop/dispose and do not prove it was fully rendered. The retained output tail and full reference comparison are the coverage evidence.",
            "Ordered single attempts at each setting are a bounded non-reproduction of the onset and do not attribute Spotify behavior or exclude a shared macOS mechanism.",
            "Watchdog normal exit and cleanup receipts are recorded; separate live resource/device restoration checks belong to the parent and were not repeated here.",
        ],
        "independentRawCaptureReReadPerformed": False,
    }
    if not args.helper_binary:
        result["helperProvenance"]["binaryFileIndependentlyHashed"] = False
        result["limits"].append(
            "No measured binary was supplied to this reproduction; its hash was cross-checked between the manifest and receipts, not recomputed from an executable.")
    # Historical conclusion text above describes this fixed pair, not arbitrary
    # newly supplied receipts. Failed checks must not inherit those conclusions.
    if not result["allChecksPassed"]:
        result["conclusions"] = ["One or more audit checks failed; historical success conclusions do not apply."]
    with args.output.open("x") as output:
        json.dump(result, output, indent=2, sort_keys=True, allow_nan=False)
        output.write("\n")
    print(json.dumps({"allChecksPassed": result["allChecksPassed"],
                      "outputSHA256": sha(args.output.read_bytes())}))
    return 0 if result["allChecksPassed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
