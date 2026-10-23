#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import sys
import shutil
from contextlib import contextmanager

root = Path(__file__).resolve().parents[3]
sources = [root / name for name in [
    'Sources/SillHost/LocalAudioParticipants.swift',
    'Sources/SillHost/AudioForwardingContract.swift',
    'Sources/SillHost/AudioForwardingCoordinator.swift',
    'Tests/checks/audio-forwarding-coordinator/Main.swift',
]]
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
inputs = sources + protocol + [Path(__file__).resolve()]
before = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
protocol_hashes = {str(path.relative_to(root)): before[str(path.relative_to(root))] for path in protocol}
@contextmanager
def owned_output():
    path = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else Path(tempfile.mkdtemp(prefix='audio-forwarding-coordinator-'))
    if len(sys.argv) == 2: path.mkdir(parents=True, exist_ok=False)
    try: yield str(path)
    finally: shutil.rmtree(path)
try:
    with owned_output() as temporary:
        out = Path(temporary)
        binary = out / 'checks'
        shared = ['xcrun', 'swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
        subprocess.run(shared + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
            *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'),
            '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')], check=True)
        subprocess.run(shared + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
            '-Xlinker', '-rpath', '-Xlinker', str(out), *map(str, sources), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)
finally:
    after = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    print(json.dumps({'sourceHashes': before, 'sharedModuleSourceHashes': protocol_hashes,
        'sourceUnchanged': before == after, 'actualMediaOrDeviceActions': False}, sort_keys=True), flush=True)
    assert before == after
