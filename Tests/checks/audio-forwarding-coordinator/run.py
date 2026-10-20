#!/usr/bin/env python3
import hashlib
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
before = [hashlib.sha256(path.read_bytes()).hexdigest() for path in sources]
@contextmanager
def owned_output():
    path = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else Path(tempfile.mkdtemp(prefix='audio-forwarding-coordinator-'))
    if len(sys.argv) == 2: path.mkdir(parents=True, exist_ok=False)
    try: yield str(path)
    finally: shutil.rmtree(path)
with owned_output() as temporary:
    out = Path(temporary)
    binary = out / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(out / 'cache'),
                    *map(str, sources), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
assert before == [hashlib.sha256(path.read_bytes()).hexdigest() for path in sources]
