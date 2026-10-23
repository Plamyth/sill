"""Compile and run pure production forwarding policy. No sockets, audio, permissions, apps or devices."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='vision-forwarding-') as temporary:
    output = Path(temporary)
    swift = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'cache')]
    subprocess.run(swift + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
        str(root / 'Sources/StreamProtocol/AudioForwarding.swift'), '-o', str(output / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(output / 'StreamProtocol.swiftmodule')], check=True)
    subprocess.run(swift + ['-I', str(output), '-L', str(output), '-lStreamProtocol',
        str(root / 'visionOSClient/VisionRemoteAudioIntent.swift'),
        str(root / 'visionOSClient/VisionRemoteAudioAuthority.swift'),
        str(root / 'visionOSClient/VisionAudioForwarding.swift'),
        str(root / 'Tests/checks/vision-forwarding/main.swift'), '-o', str(output / 'checks')], check=True)
    subprocess.run([str(output / 'checks')], env={**os.environ, 'DYLD_LIBRARY_PATH': str(output)}, check=True)
    privacy = output / 'privacy'
    result = subprocess.run([sys.executable, str(root / 'Tests/checks/vision-audio-privacy/run.py'),
                             str(root), str(privacy)], capture_output=True, text=True)
    print(result.stdout, flush=True)
    if result.returncode:
        print(result.stderr, flush=True)
        for log in sorted(privacy.rglob('*.log')):
            print(log.name + '\n' + log.read_text()[-8000:], flush=True)
        raise SystemExit(result.returncode)
    for name in ['policy.log', 'adapter.log', 'catalog-server.log']:
        print((privacy / name).read_text(), flush=True)
