#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

folder = Path(__file__).resolve().parent
repo = folder.parent.parent
binary = folder / 'audioqueue-first-start'
reference = repo / 'work/reference-server/filo-reference-44100-24.wav'
checks = []
def run(name, args, code, required):
    result = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True, timeout=5)
    text = result.stdout + result.stderr
    passed = result.returncode == code and required in text
    checks.append({'name': name, 'exitCode': result.returncode, 'passed': passed, 'output': text.strip().replace(str(repo), '<repo>')})
    assert passed, (name, result.returncode, text)
run('help', ['--help'], 0, 'TapAutoStart=false')
run('canonical full integer payload', ['--offline-check', '--reference', reference], 0, 'all 441000 integer/Float32 samples verified')
for number in range(3):
    run(f'signal lifecycle {number + 1}', ['--signal-check'], 0, 'SIGNAL_CHECK_OK')
run('invalid mode before audio', ['--reference', reference, '--mode', 'unexpected', '--output', 'WALKMAN', '--receipt', 'never-created.json'], 1, 'Usage:')
with tempfile.TemporaryDirectory(prefix='filo-audioqueue-offline-', dir=folder) as temporary:
    temporary = Path(temporary)
    existing = temporary / 'existing.json'
    existing.write_bytes(b'SENTINEL\n')
    for mode in ('default', 'explicit-unity'):
        run(f'{mode} existing receipt refused before audio', ['--reference', reference, '--mode', mode, '--output', 'WALKMAN', '--receipt', existing], 1, 'Receipt must be new')
        assert existing.read_bytes() == b'SENTINEL\n'
    changed = bytearray(reference.read_bytes())
    changed[-1] ^= 1
    altered = temporary / 'altered.wav'
    altered.write_bytes(changed)
    run('altered final integer rejected before audio', ['--offline-check', '--reference', altered], 1, 'SHA-256 mismatch')
source = (folder / 'main.swift').read_text()
assert not re.search(r'AudioQueuePrime\s*\(', source)
assert len(re.findall(r'AudioQueueStart\s*\(', source)) == 1
start = source.index('let status = AudioQueueStart(')
assert source.rindex('case "GO":', 0, start) < start < source.index('case "STATUS":', start)
checks.append({'name': 'static first-start sequencing', 'passed': True, 'details': 'No Prime call; exactly one AudioQueueStart, inside GO; no silent renderer.'})
manifest = json.loads((folder / 'build-manifest.json').read_text())
assert manifest['sourceSHA256'] == hashlib.sha256((folder / 'main.swift').read_bytes()).hexdigest()
assert manifest['binarySHA256'] == hashlib.sha256(binary.read_bytes()).hexdigest()
result = {'scope': 'Offline only; no AudioQueue or HAL calls executed.', 'checks': checks, 'passed': all(c['passed'] for c in checks), 'sourceSHA256': manifest['sourceSHA256'], 'binarySHA256': manifest['binarySHA256']}
(folder / 'offline-checks.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
print(json.dumps({'passed': result['passed'], 'checks': len(checks), 'sourceSHA256': result['sourceSHA256'], 'binarySHA256': result['binarySHA256']}, indent=2))
