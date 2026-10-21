import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
host = [root / 'Sources/SillHost' / (name + '.swift') for name in
        ['InputInjector', 'KeyStrokes', 'GestureChords', 'Stats', 'PointerControl', 'PointerWatch']]
inputs = protocol + host + [here / 'main.swift', Path(__file__)]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
with tempfile.TemporaryDirectory(prefix='input-authorization-') as temporary:
    scratch = Path(temporary)
    base = ['xcrun', 'swiftc', '-package-name', 'sill', '-module-cache-path', str(scratch / 'cache')]
    subprocess.run(base + ['-emit-module', '-emit-library', '-module-name', 'StreamProtocol', *map(str, protocol),
        '-emit-module-path', str(scratch / 'StreamProtocol.swiftmodule'), '-o', str(scratch / 'libStreamProtocol.dylib')], check=True, timeout=180)
    binary = scratch / 'checks'
    subprocess.run(base + ['-parse-as-library', '-I', str(scratch), '-L', str(scratch), '-lStreamProtocol',
        '-Xlinker', '-rpath', '-Xlinker', str(scratch), *map(str, host), str(here / 'main.swift'), '-o', str(binary)], check=True, timeout=180)
    subprocess.run([str(binary)], check=True, timeout=30)
assert all(hashlib.sha256((root / path).read_bytes()).hexdigest() == digest for path, digest in before.items())
print(json.dumps({'passed': True, 'sourceHashes': before, 'sourceUnchanged': True, 'scratchRemoved': not scratch.exists(),
                  'actualInputPosting': False, 'deviceOrHALActions': 0}))
