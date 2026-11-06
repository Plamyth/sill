"""Compile exact shared production protocol, then run bounded inert wire checks."""
from pathlib import Path
import hashlib
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
INPUTS = sorted((ROOT / 'Sources/StreamProtocol').glob('*.swift')) + [HERE / 'main.swift', Path(__file__).resolve()]
ENV = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')

def hashes():
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in INPUTS}

def run(args, budget=180):
    subprocess.run(list(map(str, args)), check=True, timeout=budget, cwd=ROOT, env=ENV)

before = hashes()
try:
    with tempfile.TemporaryDirectory(prefix='.ipad-craft-wire-', dir=ROOT) as scratch:
        out = Path(scratch)
        swift = ['xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'Sill', '-module-cache-path', out / 'cache']
        run(swift + ['-emit-module', '-emit-library', '-module-name', 'StreamProtocol',
            *sorted((ROOT / 'Sources/StreamProtocol').glob('*.swift')),
            '-emit-module-path', out / 'StreamProtocol.swiftmodule', '-o', out / 'libStreamProtocol.dylib'])
        run(swift + ['-I', out, '-L', out, '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', out,
            HERE / 'main.swift', '-o', out / 'checks'])
        run([out / 'checks'], 15)
finally:
    assert before == hashes(), 'production sources changed'
    assert not Path(scratch).exists(), 'owned scratch remains'
    print('INPUT_SOURCES_UNCHANGED=true; SCRATCH_REMOVED=true')
