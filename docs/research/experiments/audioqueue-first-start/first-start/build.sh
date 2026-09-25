#!/bin/bash
set -euo pipefail
filo_probe_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -ne 1 ]; then
    echo "Usage: build.sh SCRATCH_DEBUG_DIRECTORY" >&2
    exit 2
fi
filo_scratch_bin="$(cd "$1" && pwd)"
filo_scratch_root="$(cd "$filo_scratch_bin/../../.." && pwd)"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
filo_probe_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -warnings-as-errors -sdk "$filo_probe_sdk" -target arm64-apple-macosx14.4 \
    -I "$filo_scratch_bin/Modules" \
    -Xcc "-fmodule-map-file=$filo_scratch_bin/FiloPCM.build/module.modulemap" \
    -I "$filo_scratch_root/Sources/FiloPCM/include" \
    "$filo_probe_dir/main.swift" \
    "$filo_scratch_bin"/FiloCore.build/*.o "$filo_scratch_bin"/FiloPCM.build/*.o \
    -o "$filo_probe_dir/audioqueue-first-start"
python3 - "$filo_probe_dir" "$filo_scratch_bin" "$filo_scratch_root" <<'PY'
import hashlib, json, pathlib, subprocess, sys
out, binpath, root = map(pathlib.Path, sys.argv[1:])
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
objects = sorted(binpath.glob('FiloCore.build/*.o')) + sorted(binpath.glob('FiloPCM.build/*.o'))
manifest = {
    'scope': 'Isolated first-start experiment; TapAutoStart=false in the scratch FiloCore.',
    'swiftVersion': subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True).strip(),
    'target': 'arm64-apple-macosx14.4', 'warningsAsErrors': True,
    'scratchProvenance': json.loads((root / 'provenance.json').read_text()),
    'scratchProvenanceSHA256': sha(root / 'provenance.json'),
    'sourceSHA256': sha(out / 'main.swift'), 'binarySHA256': sha(out / 'audioqueue-first-start'),
    'buildScriptSHA256': sha(out / 'build.sh'),
    'linkedObjectSHA256': {str(p.relative_to(binpath)): sha(p) for p in objects},
    'moduleSHA256': {str(p.relative_to(binpath)): sha(p) for p in sorted((binpath / 'Modules').glob('FiloCore.*')) if p.is_file()},
}
(out / 'build-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
print(json.dumps({k: manifest[k] for k in ('sourceSHA256', 'binarySHA256', 'buildScriptSHA256')}, indent=2))
PY
