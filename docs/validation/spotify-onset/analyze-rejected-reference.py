#!/usr/bin/env python3
"""Offline diagnostics for the original five-second filo synthetic reference only."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import wave


REFERENCE_SHA256 = "43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e"
REFERENCE_FRAMES = 220_500
RATE = 44_100
MAX_CAPTURE_FRAMES = 8_192
MAX_REPORT_BYTES = 2 * 1024 * 1024
ANCHOR_FRAMES = 4
LPCM = 1_819_304_813


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unsigned(value, bits, name):
    require(type(value) is int and 0 <= value < (1 << bits), f"Invalid {name}: expected UInt{bits}.")
    return value


def float_from_bits(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def bits_from_float(value):
    return struct.unpack("<I", struct.pack("<f", value))[0]


def generator_integer(frame, channel):
    """Independent Python transcription of the original 24-bit fixture generator."""
    x = ((frame & 0xFFFFFFFF) ^ (((frame >> 32) * 0x85EBCA6B) & 0xFFFFFFFF)
         ^ (0xC2B2AE35 if channel else 0x27D4EB2F))
    x ^= x >> 16
    x = (x * 0x7FEB352D) & 0xFFFFFFFF
    x ^= x >> 15
    x = (x * 0x846CA68B) & 0xFFFFFFFF
    x ^= x >> 16
    return (x & 16383) - 8192


def grid_properties(value, bits):
    finite = math.isfinite(value)
    scale = 1 << (bits - 1)
    scaled = value * scale if finite else None
    in_range = finite and -1 <= value < 1
    integer_grid = finite and scaled == math.trunc(scaled)
    return {
        "bits": bits,
        "finite": finite,
        "inSignedNormalizedRange": in_range,
        "onUnboundedIntegerGrid": integer_grid,
        "representable": in_range and integer_grid,
        "scaledValue": scaled,
        "fractionalResidueTowardZero": scaled - math.trunc(scaled) if finite else None,
    }


def sample_properties(bits, source_bits, output_bits):
    value = float_from_bits(bits)
    exponent = (bits >> 23) & 255
    fraction = bits & 0x7FFFFF
    if exponent == 255:
        classification = "NaN" if fraction else ("negative infinity" if bits >> 31 else "positive infinity")
    elif exponent == 0:
        classification = "subnormal" if fraction else ("negative zero" if bits >> 31 else "positive zero")
    else:
        classification = "normal"
    reference_grid = grid_properties(value, 24)
    scaled = reference_grid["scaledValue"]
    nearest = round(scaled) if scaled is not None else None
    return {
        "rawBits": bits,
        "rawBitsHex": f"0x{bits:08x}",
        "classification": classification,
        "value": value if math.isfinite(value) else None,
        "finite": math.isfinite(value),
        "sourceGrid": grid_properties(value, source_bits) if source_bits else None,
        "reference24Grid": reference_grid,
        "outputGrid": grid_properties(value, output_bits),
        "nearest24Diagnostic": {
            "nearestUnboundedInteger": nearest,
            "signedErrorIn24BitLSB": scaled - nearest if nearest is not None else None,
            "nearestIntegerInSigned24Range": -(1 << 23) <= nearest < (1 << 23) if nearest is not None else None,
            "roundingRule": "Nearest integer, ties to even, without clipping; diagnostic only, never used for alignment or equality.",
        },
    }


class Reference:
    def __init__(self, words, file_hash=None):
        self.words = tuple(words)
        require(len(self.words) % 2 == 0, "Reference must be stereo.")
        self.frames = len(self.words) // 2
        self.bytes = struct.pack(f"<{len(self.words)}I", *self.words)
        self.file_hash = file_hash
        self._anchors = None

    @property
    def anchors(self):
        if self._anchors is None:
            self._anchors = {}
            size = ANCHOR_FRAMES * 8
            for frame in range(self.frames - ANCHOR_FRAMES + 1):
                key = self.bytes[frame * 8:frame * 8 + size]
                if not any(key):
                    continue
                if key not in self._anchors:
                    self._anchors[key] = frame
                else:
                    previous = self._anchors[key]
                    if type(previous) is int:
                        self._anchors[key] = [previous, frame]
                    else:
                        previous.append(frame)
        return self._anchors


def load_reference(path):
    require(path.stat().st_size == 1_323_044, "Reference size differs from the original synthetic WAV.")
    raw = path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    require(digest == REFERENCE_SHA256, "Reference is not the allowlisted original synthetic WAV.")
    with wave.open(str(path), "rb") as wav:
        require((wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes())
                == (2, 3, RATE, REFERENCE_FRAMES), "Reference format or length differs.")
        packed = wav.readframes(REFERENCE_FRAMES)
    require(len(packed) == REFERENCE_FRAMES * 6, "Reference payload is incomplete.")
    words = []
    for sample_index in range(REFERENCE_FRAMES * 2):
        offset = sample_index * 3
        integer = int.from_bytes(packed[offset:offset + 3], "little", signed=True)
        require(integer == generator_integer(sample_index // 2, sample_index % 2),
                f"Reference generator mismatch at sample {sample_index}.")
        words.append(bits_from_float(integer / (1 << 23)))
    return Reference(words, digest)


def exact_alignment(words, reference):
    """A single offset is justified only by mutually consistent exact stereo anchors."""
    raw = struct.pack(f"<{len(words)}I", *words)
    frames = len(words) // 2
    offsets = Counter()
    evidence = []
    for frame in range(max(0, frames - ANCHOR_FRAMES + 1)):
        key = raw[frame * 8:(frame + ANCHOR_FRAMES) * 8]
        if not any(key):
            continue
        matches = reference.anchors.get(key)
        if matches is None:
            continue
        for reference_frame in [matches] if type(matches) is int else matches:
            offset = reference_frame - frame
            offsets[offset] += 1
            if len(evidence) < 8:
                evidence.append({"captureWindowFrame": frame, "referenceFrame": reference_frame,
                                 "referenceFrameAtCaptureWindowStart": offset})
    result = {
        "method": "Exact raw Float32 bits in four consecutive stereo frames; no rounding, correlation, gain fit, or time warping.",
        "anchorFrames": ANCHOR_FRAMES,
        "candidateOffsetCount": len(offsets),
        "candidateOffsets": [{"referenceFrameAtCaptureWindowStart": k, "matchingAnchorCount": v}
                             for k, v in sorted(offsets.items())[:16]],
        "candidateListTruncated": len(offsets) > 16,
        "anchorExamples": evidence,
        "status": "unique" if len(offsets) == 1 else "ambiguous" if offsets else "unavailable",
        "fullReferenceCoverageProved": False,
        "bitPerfectVerdict": "not assessed by this bounded rejection diagnostic",
    }
    if len(offsets) != 1:
        result["windowComparison"] = None
        return result
    offset = next(iter(offsets))
    capture_start = max(0, -offset)
    reference_start = max(0, offset)
    compared = max(0, min(frames - capture_start, reference.frames - reference_start))
    mismatched_words = 0
    mismatched_frames = 0
    first = None
    for frame in range(compared):
        frame_differs = False
        for channel in range(2):
            capture_frame = capture_start + frame
            reference_frame = reference_start + frame
            actual = words[capture_frame * 2 + channel]
            expected = reference.words[reference_frame * 2 + channel]
            if actual != expected:
                mismatched_words += 1
                frame_differs = True
                if first is None:
                    av, ev = float_from_bits(actual), float_from_bits(expected)
                    first = {"captureWindowFrame": capture_frame, "referenceFrame": reference_frame,
                             "channel": channel, "actualBitsHex": f"0x{actual:08x}",
                             "expectedBitsHex": f"0x{expected:08x}",
                             "signedErrorIn24BitLSB": (av - ev) * (1 << 23) if math.isfinite(av) else None}
        mismatched_frames += frame_differs
    outside = [words[i] for i in range(len(words)) if not capture_start * 2 <= i < (capture_start + compared) * 2]
    result["referenceFrameAtCaptureWindowStart"] = offset
    result["windowComparison"] = {
        "capturedFrames": frames, "captureWindowStartFrame": capture_start,
        "referenceStartFrame": reference_start, "comparedFrames": compared,
        "mismatchedSampleWords": mismatched_words, "mismatchedFrames": mismatched_frames,
        "firstMismatch": first, "outsideReferenceNonzeroWords": sum((w & 0x7FFFFFFF) != 0 for w in outside),
        "outsideReferenceNegativeZeroWords": sum(w == 0x80000000 for w in outside),
        "unobservedReferenceFrames": reference.frames - compared,
        "windowRawWordsExact": compared > 0 and mismatched_words == 0,
        "fullReferenceCoverageProved": False,
    }
    return result


def parse_snapshot(report):
    require(type(report) is dict, "Report must be a JSON object.")
    require(report.get("rejectionInspectionRequested") is True, "Report did not request rejection inspection.")
    require(report.get("referenceSHA256") == REFERENCE_SHA256, "Report names a different or absent reference hash.")
    require(type(report.get("metrics")) is dict, "Report metrics must be an object.")
    unsigned(report["metrics"].get("fault"), 32, "metrics.fault")
    snapshot = report.get("rejectionSnapshot")
    if snapshot is None:
        return None
    require(type(snapshot) is dict and snapshot.get("available") is True, "Invalid rejectionSnapshot availability.")
    unsigned(snapshot.get("acceptedFramesBeforeCallback"), 64, "acceptedFramesBeforeCallback")
    for key in ["callbackFrames", "firstRejectedFrame", "firstRejectedChannel", "rejectedSampleBits",
                "captureStartFrame", "capturedFrames", "sourceBits", "outputBits"]:
        unsigned(snapshot.get(key), 32, key)
    count, start, callback = (snapshot[k] for k in ["capturedFrames", "captureStartFrame", "callbackFrames"])
    require(1 <= count <= MAX_CAPTURE_FRAMES and start + count <= callback, "Invalid bounded capture window.")
    bad, channel = snapshot["firstRejectedFrame"], snapshot["firstRejectedChannel"]
    require(start <= bad < start + count and channel in (0, 1), "Offender is outside captured stereo window.")
    source_bits, output_bits = snapshot["sourceBits"], snapshot["outputBits"]
    require(source_bits in (0, 16, 24) and output_bits in (16, 24, 32), "Unsupported source/output bit depth.")
    output = report.get("output", {})
    require(type(output) is dict and output.get("formatID") == LPCM
            and output.get("rate") == RATE and output.get("channels") == 2
            and output.get("bits") == output_bits, "Output format disagrees with known reference or snapshot.")
    flags = unsigned(output.get("flags"), 32, "output.flags")
    require(not flags & 1 and flags & 4, "This analyzer requires a signed integer output format.")
    require(report["metrics"]["fault"] == 5, "Snapshot is not associated with a representation fault.")
    words = snapshot.get("capturedSampleBits")
    require(type(words) is list and len(words) == count * 2, "Captured word count differs from stereo frame count.")
    for word in words:
        unsigned(word, 32, "capturedSampleBits word")
    local_word = (bad - start) * 2 + channel
    require(words[local_word] == snapshot["rejectedSampleBits"], "Offender raw bits disagree with captured word.")
    offender = sample_properties(words[local_word], source_bits, output_bits)
    require(type(snapshot.get("finite")) is bool and snapshot["finite"] == offender["finite"], "Finite metadata differs from raw bits.")
    if source_bits:
        require(type(snapshot.get("sourceRepresentable")) is bool
                and snapshot["sourceRepresentable"] == offender["sourceGrid"]["representable"],
                "Source representability metadata differs from raw bits.")
    else:
        require(snapshot.get("sourceRepresentable") is None, "Unasserted source depth must remain null/unknown.")
    require(type(snapshot.get("outputRepresentable")) is bool
            and snapshot["outputRepresentable"] == offender["outputGrid"]["representable"],
            "Output representability metadata differs from raw bits.")
    require(not offender["outputGrid"]["representable"] or
            (source_bits and not offender["sourceGrid"]["representable"]), "Declared offender is representable.")
    for word in words[:local_word]:
        value = float_from_bits(word)
        require(grid_properties(value, output_bits)["representable"] and
                (not source_bits or grid_properties(value, source_bits)["representable"]),
                "An earlier captured word already fails representation; first-offender metadata is inconsistent.")
    return snapshot


def analyze(report, reference):
    snapshot = parse_snapshot(report)
    result = {
        "schemaVersion": 1,
        "scope": "Offline, bounded first-rejected-callback diagnostic for the original synthetic reference only.",
        "reference": {"fileSHA256": reference.file_hash, "frames": reference.frames, "rate": RATE,
                      "channels": 2, "bits": 24, "everySampleVerifiedAgainstIndependentGenerator": True},
        "bitPerfectVerdict": "not assessed; a rejected callback cannot certify complete playback",
        "fullReferenceCoverageProved": False,
        "metadataValid": True,
    }
    if snapshot is None:
        result.update({"status": "snapshot unavailable", "representationFaultReported": report.get("metrics", {}).get("fault") == 5,
                       "note": "No rejected-callback words were supplied; absence is not evidence of bit-perfect playback."})
        return result
    words = snapshot["capturedSampleBits"]
    properties = [sample_properties(w, snapshot["sourceBits"], snapshot["outputBits"]) for w in words]
    first_word = (snapshot["firstRejectedFrame"] - snapshot["captureStartFrame"]) * 2 + snapshot["firstRejectedChannel"]
    metadata = {k: v for k, v in snapshot.items() if k != "capturedSampleBits"}
    metadata["captureFloat32BitsSHA256"] = hashlib.sha256(struct.pack(f"<{len(words)}I", *words)).hexdigest()
    metadata["capturedThroughCallbackEnd"] = snapshot["captureStartFrame"] + snapshot["capturedFrames"] == snapshot["callbackFrames"]
    alignment = exact_alignment(words, reference)
    def located_sample(index):
        sample = dict(properties[index])
        sample.update({"captureWindowFrame": index // 2,
                       "callbackFrame": snapshot["captureStartFrame"] + index // 2,
                       "channel": index % 2,
                       "referenceFrameFromExactAnchors": None})
        if alignment["status"] == "unique":
            frame = alignment["referenceFrameAtCaptureWindowStart"] + index // 2
            if 0 <= frame < reference.frames:
                sample["referenceFrameFromExactAnchors"] = frame
        return sample
    first_reference_violation = next((i for i, p in enumerate(properties) if not p["reference24Grid"]["representable"]), None)
    result.update({
        "status": "rejected callback analyzed",
        "snapshot": metadata,
        "positionNote": "acceptedFramesBeforeCallback counts accepted stream frames, including preroll; it is not a source-file frame index.",
        "firstRejectedSample": located_sample(first_word),
        "firstNotRepresentableAsReference24InWindow": located_sample(first_reference_violation) if first_reference_violation is not None else None,
        "windowStatistics": {
            "sampleWords": len(words), "nonfiniteWords": sum(not p["finite"] for p in properties),
            "negativeZeroWords": sum(p["classification"] == "negative zero" for p in properties),
            "notRepresentableAsReference24Words": sum(not p["reference24Grid"]["representable"] for p in properties),
            "notRepresentableAtAssertedSourceDepthWords": sum(not p["sourceGrid"]["representable"] for p in properties) if snapshot["sourceBits"] else None,
            "notRepresentableAtOutputDepthWords": sum(not p["outputGrid"]["representable"] for p in properties),
            "maximumAbsoluteNearest24ErrorLSB": max((abs(p["nearest24Diagnostic"]["signedErrorIn24BitLSB"])
                                                       for p in properties if p["finite"]), default=None),
        },
        "alignment": alignment,
    })
    return result


def duplicate_free_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def self_test(reference):
    import copy
    tests = []

    def check(name, function):
        function()
        tests.append({"name": name, "passed": True})

    def expect_error(report):
        try:
            analyze(report, reference)
        except ValueError:
            return
        raise AssertionError("Malformed report was accepted.")

    def make_report(words, first_frame, channel=0, start=0, callback=None, source_bits=24, output_bits=32):
        bits = words[(first_frame - start) * 2 + channel]
        p = sample_properties(bits, source_bits, output_bits)
        return {"rejectionInspectionRequested": True, "referenceSHA256": REFERENCE_SHA256,
                "output": {"formatID": LPCM, "rate": RATE, "channels": 2, "bits": output_bits, "flags": 76},
                "metrics": {"fault": 5}, "rejectionSnapshot": {
                    "available": True, "acceptedFramesBeforeCallback": 900_000, "callbackFrames": callback or start + len(words) // 2,
                    "firstRejectedFrame": first_frame, "firstRejectedChannel": channel, "rejectedSampleBits": bits,
                    "captureStartFrame": start, "capturedFrames": len(words) // 2, "sourceBits": source_bits,
                    "outputBits": output_bits, "finite": p["finite"],
                    "sourceRepresentable": p["sourceGrid"]["representable"] if source_bits else None,
                    "outputRepresentable": p["outputGrid"]["representable"], "capturedSampleBits": list(words)}}

    original = list(reference.words[1234 * 2:(1234 + 48) * 2])
    changed = original.copy()
    changed[0] ^= 1
    report = make_report(changed, 0)

    def unique():
        a = analyze(report, reference)
        assert a["alignment"]["status"] == "unique"
        assert a["alignment"]["referenceFrameAtCaptureWindowStart"] == 1234
        assert a["alignment"]["windowComparison"]["mismatchedSampleWords"] == 1
        assert not a["firstRejectedSample"]["reference24Grid"]["representable"]
        assert a["fullReferenceCoverageProved"] is False
    check("exact anchors locate a single low-bit corruption without accepting the window", unique)

    def fractional():
        p = sample_properties(bits_from_float(1.5 / (1 << 23)), 24, 32)
        assert p["reference24Grid"]["fractionalResidueTowardZero"] == 0.5
        assert p["nearest24Diagnostic"]["signedErrorIn24BitLSB"] == -0.5
        assert not p["sourceGrid"]["representable"] and p["outputGrid"]["representable"]
    check("scaled24 residue and nearest-even diagnostic remain distinct", fractional)

    def truncated():
        a = analyze(make_report(changed, 64, start=64, callback=512), reference)
        assert not a["snapshot"]["capturedThroughCallbackEnd"]
        assert a["alignment"]["referenceFrameAtCaptureWindowStart"] == 1234
    check("truncated callback window uses its own origin", truncated)

    def channel_one():
        w = original.copy(); w[1] ^= 1
        a = analyze(make_report(w, 0, channel=1), reference)
        assert a["alignment"]["windowComparison"]["firstMismatch"]["channel"] == 1
    check("channel1 offender retains stereo alignment", channel_one)

    def no_anchor():
        w = [bits_from_float(float_from_bits(x) * 0.731) for x in original]
        # Raw-bit-only search cannot promote a gain-like sequence to a match.
        assert exact_alignment(w, reference)["status"] == "unavailable"
    check("gain-altered window has no invented alignment", no_anchor)

    def ambiguous():
        periodic = Reference([bits_from_float(1 / (1 << 23)), bits_from_float(2 / (1 << 23))] * 40)
        a = exact_alignment(list(periodic.words[:16]), periodic)
        assert a["status"] == "ambiguous" and a["windowComparison"] is None
    check("repeated anchors cannot choose a convenient offset", ambiguous)

    def inconsistent():
        w = list(reference.words[100:132]) + list(reference.words[1000:1032])
        a = exact_alignment(w, reference)
        assert a["status"] == "ambiguous" and a["windowComparison"] is None
    check("two incompatible exact offsets remain ambiguous", inconsistent)

    def silence():
        assert exact_alignment([0] * 128, reference)["status"] == "unavailable"
    check("silence supplies no source-position evidence", silence)

    def negative_zero():
        p = sample_properties(0x80000000, 24, 32)
        assert p["classification"] == "negative zero" and p["sourceGrid"]["representable"]
        assert p["rawBits"] == 0x80000000
    check("negative zero is preserved rather than normalized", negative_zero)

    for name, bits in [("NaN payload", 0x7FC00123), ("infinity", 0x7F800000), ("out of range", 0x3F800000), ("subnormal", 1)]:
        def special(bits=bits):
            a = analyze(make_report([bits] + original[1:], 0), reference)
            assert a["firstRejectedSample"]["rawBits"] == bits
            assert not a["firstRejectedSample"]["outputGrid"]["representable"]
            json.dumps(a, allow_nan=False)
        check(name + " remains a rejection with JSON-safe numeric fields", special)

    def absent_source():
        a = analyze(make_report([1] + original[1:], 0, source_bits=0), reference)
        assert a["firstRejectedSample"]["sourceGrid"] is None
        assert a["windowStatistics"]["notRepresentableAtAssertedSourceDepthWords"] is None
    check("sourceBits0 stays unknown rather than safe", absent_source)

    cases = [
        ("wrong reference identity", lambda r: r.update(referenceSHA256="0" * 64)),
        ("wrong offender bits", lambda r: r["rejectionSnapshot"].update(rejectedSampleBits=0)),
        ("wrong finite metadata", lambda r: r["rejectionSnapshot"].update(finite=False)),
        ("wrong source metadata", lambda r: r["rejectionSnapshot"].update(sourceRepresentable=True)),
        ("partial stereo data", lambda r: r["rejectionSnapshot"]["capturedSampleBits"].pop()),
        ("oversized capture", lambda r: r["rejectionSnapshot"].update(capturedFrames=8193)),
        ("offender outside window", lambda r: r["rejectionSnapshot"].update(firstRejectedFrame=999)),
        ("wrong output depth", lambda r: r["output"].update(bits=24)),
        ("wrong output rate", lambda r: r["output"].update(rate=48000)),
        ("boolean sample word", lambda r: r["rejectionSnapshot"]["capturedSampleBits"].__setitem__(2, True)),
        ("malformed metrics", lambda r: r.update(metrics=None)),
        ("boolean fault code", lambda r: r["metrics"].update(fault=True)),
        ("wrong output representability", lambda r: r["rejectionSnapshot"].update(outputRepresentable=not r["rejectionSnapshot"]["outputRepresentable"])),
    ]
    for name, mutate in cases:
        def malformed(mutate=mutate):
            r = copy.deepcopy(report); mutate(r); expect_error(r)
        check("reject " + name, malformed)

    def missing():
        r = copy.deepcopy(report); r.pop("rejectionSnapshot")
        a = analyze(r, reference)
        assert a["status"] == "snapshot unavailable" and a["representationFaultReported"]
        assert a["fullReferenceCoverageProved"] is False
    check("missing snapshot stays unavailable even with fault5", missing)
    return {"schemaVersion": 1, "kind": "offline self-test", "passed": True,
            "referenceSHA256": reference.file_hash, "referenceFramesVerified": reference.frames,
            "testsPassed": len(tests), "tests": tests, "hardwareOrPlayerAccess": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--report", type=Path, help="Completed verify-reference JSON with --inspect-rejection.")
    action.add_argument("--self-test", action="store_true", help="Run offline controls; --output also writes their report.")
    parser.add_argument("--reference", type=Path, default=Path("work/filo-reference-44100-24.wav"))
    parser.add_argument("--output", type=Path, help="New JSON result file; existing files are never overwritten.")
    args = parser.parse_args()
    if args.output:
        require(not args.output.exists(), "Output already exists; choose a new diagnostic report path.")
    reference = load_reference(args.reference)
    if args.self_test:
        result = self_test(reference)
    else:
        require(args.report.stat().st_size <= MAX_REPORT_BYTES, "Report exceeds the bounded input size.")
        with args.report.open("rb") as handle:
            raw = handle.read(MAX_REPORT_BYTES + 1)
        require(len(raw) <= MAX_REPORT_BYTES, "Report grew beyond the bounded input size.")
        report = json.loads(raw, object_pairs_hook=duplicate_free_object,
                            parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f"Nonstandard JSON constant: {value}")))
        result = analyze(report, reference)
        result["inputReportSHA256"] = hashlib.sha256(raw).hexdigest()
    encoded = json.dumps(result, indent=2, allow_nan=False) + "\n"
    if args.output:
        with args.output.open("x", encoding="utf-8") as handle:
            handle.write(encoded)
    sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, wave.Error, struct.error, AssertionError) as error:
        print(json.dumps({"status": "error", "error": str(error), "hardwareOrPlayerAccess": False}), file=sys.stderr)
        raise SystemExit(1)
