#!/usr/bin/env python3
"""Run bounded offline controls for the effects-off receipt analyzer."""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
spec = importlib.util.spec_from_file_location("effects_audit", HERE / "analyze.py")
analyzer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analyzer)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if os.path.lexists(args.output):
        raise SystemExit("Output exists; nothing changed.")
    passed_path = ROOT / "docs/validation/spotify-onset/spotify-rejection-repeat-wav.json"
    failed_path = HERE / "combined-off.json"
    passed, failed = analyzer.audit.load(passed_path), analyzer.audit.load(failed_path)
    checks = []

    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        checks.append({"name": name, "passed": True})

    with tempfile.TemporaryDirectory(prefix="filo-effects-off-controls-") as directory:
        temporary = Path(directory)
        for name, mutate in (
            ("wrong_aligned_hash", lambda d: d["comparison"].__setitem__("actualAlignedSHA256", "0" * 64)),
            ("missing_prefix", lambda d: d["comparison"]["sampleComparison"].__setitem__("missingPrefixFrames", 1)),
            ("missing_suffix", lambda d: d["comparison"]["sampleComparison"].__setitem__("missingSuffixFrames", 1)),
        ):
            receipt = copy.deepcopy(passed)
            mutate(receipt)
            path = temporary / (name + ".json")
            path.write_text(json.dumps(receipt))
            result = analyzer.analyze(path, args.reference)
            check(name, not result["auditConsistent"] and not result["wholeReferenceSoftwarePassValidated"])

        receipt = copy.deepcopy(failed)
        receipt["rejectionSnapshot"]["capturedSampleBits"][35] ^= 1
        path = temporary / "changed-onset.json"
        path.write_text(json.dumps(receipt))
        result = analyzer.analyze(path, args.reference)
        check("changed_onset_reported_without_refit", result["auditConsistent"] and not result["sameOnsetAsPrevious"]
              and result["frozenModel"]["comparison"]["mismatchedSampleWords"] == 1)

        for name, mutate in (
            ("inconsistent_offender", lambda d: d["rejectionSnapshot"].__setitem__("rejectedSampleBits", d["rejectionSnapshot"]["rejectedSampleBits"] ^ 1)),
            ("failed_receipt_nested_pass_true", lambda d: d["comparison"].__setitem__("passed", True)),
            ("failed_receipt_compared_frames_disagree", lambda d: d["comparison"].__setitem__("comparedFrames", 1)),
            ("failed_receipt_compared_bytes_disagree", lambda d: d["comparison"].__setitem__("comparedBytes", 8)),
            ("unaligned_failure_claims_comparison", lambda d: (
                d["comparison"].__setitem__("comparedFrames", 1), d["comparison"].__setitem__("comparedBytes", 8),
                d["comparison"]["sampleComparison"].__setitem__("comparedFrames", 1))),
            ("unaligned_failure_claims_exact_coverage", lambda d: d["comparison"]["sampleComparison"].__setitem__("fullReferenceExact", True)),
            ("nonboolean_top_verdict", lambda d: d.__setitem__("passed", 0)),
            ("negative_compared_counts", lambda d: (
                d["comparison"].__setitem__("comparedFrames", -1), d["comparison"].__setitem__("comparedBytes", -8),
                d["comparison"]["sampleComparison"].__setitem__("comparedFrames", -1))),
        ):
            receipt = copy.deepcopy(failed)
            mutate(receipt)
            path, output = temporary / (name + ".json"), temporary / (name + "-analysis.json")
            path.write_text(json.dumps(receipt))
            result = subprocess.run([sys.executable, str(HERE / "analyze.py"), "--report", str(path),
                "--reference", str(args.reference), "--output", str(output)], capture_output=True, text=True)
            check(name, result.returncode == 1 and not output.exists())

        result = analyzer.analyze(passed_path, args.reference)
        check("historical_complete_pass", result["auditConsistent"] and result["wholeReferenceSoftwarePassValidated"])
        result = analyzer.analyze(failed_path, args.reference)
        check("unaligned_zero_comparison_failure_remains_valid", result["auditConsistent"] and result["sameOnsetAsPrevious"]
              and result["comparedReferenceFrames"] == result["comparedReferenceBytes"] == 0)
        no_snapshot_path = ROOT / "docs/validation/spotify-tap-autostart/false-direct-start.json"
        result = analyzer.analyze(no_snapshot_path, args.reference)
        check("failure_without_snapshot_remains_valid", result["auditConsistent"] and not result["wholeReferenceSoftwarePassValidated"])
        receipt = analyzer.audit.load(no_snapshot_path)
        receipt["comparison"]["passed"] = True
        path, rejected_output = temporary / "no-snapshot-contradiction.json", temporary / "no-snapshot-analysis.json"
        path.write_text(json.dumps(receipt))
        run = subprocess.run([sys.executable, str(HERE / "analyze.py"), "--report", str(path), "--reference",
            str(args.reference), "--output", str(rejected_output)], capture_output=True, text=True)
        check("failed_receipt_nested_pass_true_without_snapshot", run.returncode == 1 and not rejected_output.exists())
        output = temporary / "reproduced.json"
        command = [sys.executable, str(HERE / "analyze.py"), "--report", str(failed_path),
                   "--reference", str(args.reference), "--output", str(output)]
        run = subprocess.run(command, capture_output=True, text=True)
        check("deterministic_public_result", run.returncode == 0 and output.read_bytes() == (HERE / "independent-analysis.json").read_bytes())
        before = output.read_bytes()
        run = subprocess.run(command, capture_output=True, text=True)
        check("existing_output_refused_and_preserved", run.returncode == 1 and output.read_bytes() == before)

    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    result = {"schemaVersion": 2, "scope": "Offline analyzer controls only; no new playback or hardware evidence.",
              "analyzerSHA256": digest(HERE / "analyze.py"), "controlRunnerSHA256": digest(Path(__file__)),
              "referenceSHA256": digest(args.reference),
              "controlReceiptSHA256": {str(path.relative_to(ROOT)): digest(path) for path in (passed_path, failed_path, no_snapshot_path)},
              "allPassed": True, "checks": checks,
              "temporaryResources": "Temporary directory removed and all analysis subprocesses exited."}
    with args.output.open("x") as handle:
        handle.write(json.dumps(result, indent=2) + "\n")
    print(f"{len(checks)} offline controls passed.")


if __name__ == "__main__":
    main()
