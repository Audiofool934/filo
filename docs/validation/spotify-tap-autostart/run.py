#!/usr/bin/env python3
"""Bound one owned synthetic Spotify reference measurement; no player control."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import signal
import subprocess
import threading
import time

folder = Path(__file__).resolve().parent
root = folder.parent.parent
binary = root / 'work/audioqueue-first-start-build/.build/arm64-apple-macosx/debug/filo-lab'
report = folder / 'false-direct-start.json'
stderr_file = folder / 'false-direct-start.stderr'
watchdog = folder / 'false-direct-start-watchdog.json'
reference = folder / 'fixture/filo tap autostart reference 44100 stereo 24bit WAV.wav'
for target in [report, stderr_file, watchdog]:
    if target.exists() or target.is_symlink():
        raise SystemExit('Refusing existing output: ' + target.name)
argv = [str(binary), 'verify-reference', '--device', 'WALKMAN', '--source', 'BlackHole 2ch',
        '--reference', str(reference),
        '--player', 'com.spotify.client', '--seconds', '30', '--inspect-rejection']
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
begin = time.monotonic()
termination = 'normal'
with report.open('xb') as output, stderr_file.open('xb') as errors:
    process = subprocess.Popen(argv, cwd=root, stdin=subprocess.DEVNULL, stdout=output,
                               stderr=subprocess.PIPE, start_new_session=True)
    print(json.dumps({'startedPID': process.pid, 'startedUTC': started}), flush=True)
    def forward_errors():
        for line in iter(process.stderr.readline, b''):
            errors.write(line)
            errors.flush()
            print(line.decode('utf-8', errors='replace').rstrip(), flush=True)
    forwarding = threading.Thread(target=forward_errors, daemon=True)
    forwarding.start()
    try:
        status = process.wait(timeout=90)
    except subprocess.TimeoutExpired:
        termination = 'timeout-TERM'
        os.killpg(process.pid, signal.SIGTERM)
        try:
            status = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            termination = 'timeout-KILL'
            os.killpg(process.pid, signal.SIGKILL)
            status = process.wait(timeout=5)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        forwarding.join(timeout=5)
        process.stderr.close()
result = {'startedUTC': started, 'elapsedSeconds': time.monotonic()-begin,
          'exitCode': status, 'termination': termination, 'processExited': process.poll() is not None,
          'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
          'referenceSHA256': hashlib.sha256(reference.read_bytes()).hexdigest(),
          'experimentalTapAutoStart': False, 'captureSeconds': 30,
          'reportFile': report.name, 'stderrFile': stderr_file.name,
          'requiresRecoveryInspection': termination != 'normal',
          'scope': 'Known synthetic reference only; software callback and bounded rejected input, no receiver proof.'}
with watchdog.open('x') as output:
    json.dump(result, output, indent=2)
    output.write('\n')
print(json.dumps(result), flush=True)
raise SystemExit(0 if status == 0 and termination == 'normal' else 1)
