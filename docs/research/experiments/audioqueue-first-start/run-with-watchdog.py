#!/usr/bin/env python3
"""Bound execution of a task-owned, explicitly named AudioQueue experiment."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--mode', choices=['default', 'explicit-unity'], required=True)
p.add_argument('--stem', required=True)
a = p.parse_args()
if not a.stem or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in a.stem):
    p.error('stem must use lowercase letters, digits and hyphens')
root = Path(__file__).resolve().parent.parent
folder = root / 'work/audioqueue-first-start'
binary = folder / 'audioqueue-first-start'
receipt = folder / (a.stem + '.json')
stdout_path = folder / (a.stem + '.stdout')
stderr_path = folder / (a.stem + '.stderr')
watchdog = folder / (a.stem + '-watchdog.json')
for path in [receipt, stdout_path, stderr_path, watchdog]:
    if path.exists() or path.is_symlink():
        raise SystemExit('Refusing an existing experiment output: ' + path.name)
argv = [str(binary), '--reference', str(root / 'work/reference-server/filo-reference-44100-24.wav'),
        '--output', 'WALKMAN', '--mode', a.mode, '--receipt', str(receipt)]
binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
start_clock = time.monotonic()
termination = 'normal'
with stdout_path.open('xb') as out, stderr_path.open('xb') as err:
    proc = subprocess.Popen(argv, cwd=root, stdin=subprocess.DEVNULL, stdout=out, stderr=err, start_new_session=True)
    try:
        status = proc.wait(timeout=45)
    except subprocess.TimeoutExpired:
        termination = 'timeout-TERM'
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            status = proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            termination = 'timeout-KILL'
            os.killpg(proc.pid, signal.SIGKILL)
            status = proc.wait(timeout=5)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)
result = {'startedUTC': started, 'elapsedSeconds': time.monotonic() - start_clock,
          'mode': a.mode, 'binarySHA256': binary_hash, 'exitCode': status,
          'termination': termination, 'parentExited': proc.poll() is not None,
          'receiptPresent': receipt.exists(), 'receiptFile': receipt.name,
          'scope': 'Task-owned process group only; separate child-exit and audio-state checks remain required.'}
with watchdog.open('x') as f:
    json.dump(result, f, indent=2); f.write('\n')
print(json.dumps(result))
raise SystemExit(0 if status == 0 and termination == 'normal' else 1)
