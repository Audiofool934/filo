#!/usr/bin/env python3
"""Exercise the actual macOS tap using synthetic samples on a named output.

Uses BlackHole by default to keep tests silent. Restores its original sample rate.
The report covers the synthetic renderer -> process tap and filo software path,
not commercial streaming masters or the physical USB payload.
"""
import argparse
import datetime
import json
import pathlib
import platform
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", default=".build/debug/filo-lab")
parser.add_argument("--device", default="BlackHole 2ch")
parser.add_argument("--seconds", type=float, default=3)
parser.add_argument("--report", default="work/validation/pcm-matrix.json")
args = parser.parse_args()
binary = str(pathlib.Path(args.binary).resolve())

def call(*arguments):
    return subprocess.run([binary, *map(str, arguments)], capture_output=True, text=True, timeout=150)

devices = json.loads(call("devices").stdout)
device = next((d for d in devices if d["name"] == args.device or d["uid"] == args.device), None)
if device is None:
    raise SystemExit(f"Output {args.device!r} not found. Install BlackHole for silent loopback tests.")
report = {
    "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "os": platform.mac_ver()[0],
    "architecture": platform.machine(),
    "device": device["name"],
    "scope": "Synthetic renderer -> process tap; software relay enabled; no DAC input verification",
    "cases": [],
}
report_path = pathlib.Path(args.report)
report_path.parent.mkdir(parents=True, exist_ok=True)
last_set_rate = device["rate"]
try:
    for rate in [44100, 48000, 96000, 192000]:
        result = call("rate", "--device", args.device, "--hz", rate)
        if result.returncode:
            raise RuntimeError(result.stderr)
        last_set_rate = rate
        for bits in [16, 24]:
            result = call("verify", "--device", args.device, "--bits", bits, "--seconds", args.seconds, "--relay")
            try:
                case = json.loads(result.stdout)
            except json.JSONDecodeError:
                case = {"rate": rate, "bits": bits, "passed": False}
            case["exitCode"] = result.returncode
            if result.stderr.strip():
                case["error"] = result.stderr.strip()
            report["cases"].append(case)
            print(f"{rate} Hz / {bits} bit: {'PASS' if case.get('passed') else 'FAIL'}", flush=True)
finally:
    current_devices = json.loads(call("devices").stdout)
    current_device = next((d for d in current_devices if d["uid"] == device["uid"]), None)
    if current_device and current_device["rate"] == last_set_rate:
        restoration = call("rate", "--device", args.device, "--hz", device["rate"])
        report["restored"] = restoration.returncode == 0
    else:
        report["restored"] = False
        report["restorationNote"] = "Output disappeared or its rate changed externally; preserved the new state."
    report_path.write_text(json.dumps(report, indent=2) + "\n")

raise SystemExit(0 if report["restored"] and len(report["cases"]) == 8 and all(c.get("passed") for c in report["cases"]) else 1)
