#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[2]
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
sources = protocol + [here / 'Main.swift', Path(__file__).resolve()]
def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
before = hashes()
with tempfile.TemporaryDirectory(prefix='forwarding-wire-') as temporary:
    scratch = Path(temporary)
    library = scratch / 'libStreamProtocol.dylib'
    subprocess.run(['swiftc', '-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-emit-module-path', str(scratch / 'StreamProtocol.swiftmodule'),
        '-module-cache-path', str(scratch / 'cache'), '-o', str(library)], check=True)
    binary = scratch / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', '-I', str(scratch), '-L', str(scratch),
        '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(scratch),
        '-module-cache-path', str(scratch / 'cache'), str(here / 'Main.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
assert before == hashes(), '검사 중 입력 소스가 바뀌었습니다.'
print(json.dumps({'sourceHashes': before, 'sourceUnchanged': True, 'scratchRemoved': not scratch.exists(),
    'actualMediaOrDeviceActions': False}, sort_keys=True))
