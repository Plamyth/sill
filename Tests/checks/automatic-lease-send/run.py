import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
host = root / 'Sources/SillHost'
paths = [host / name for name in ['HostMicrophoneGrant.swift', 'AutomaticDevicePrincipal.swift', 'AutomaticSessionAuthorization.swift']]
paths += [Path(__file__).with_name('Main.swift'), Path(__file__)]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}

def block(text, marker):
    start = text.index(marker)
    body = start
    if 'func ' in marker:
        body = text.index('(', start) + 1
        depth = 1
        while depth:
            depth += (text[body] == '(') - (text[body] == ')'); body += 1
    opening = text.index('{', body)
    end, depth = opening + 1, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]

production = paths[0].read_text()
fixture = paths[3].read_text()
for marker in ['package struct HostMicrophoneDestination:', 'package final class HostLocalOwnerGrant:', 'private struct Storage', 'func sendEnabled(']:
    fixture = fixture.replace('// ' + marker, block(production, marker))
with tempfile.TemporaryDirectory(prefix='automatic-lease-send-') as temporary:
    scratch = Path(temporary)
    generated = scratch / 'Main.swift'; generated.write_text(fixture)
    binary = scratch / 'check'
    subprocess.run(['xcrun', 'swiftc', '-package-name', 'sill', '-parse-as-library',
        '-module-cache-path', str(scratch / 'cache'), str(paths[1]), str(paths[2]), str(generated), '-o', str(binary)],
        check=True, timeout=180)
    subprocess.run([str(binary)], check=True, timeout=30)
assert all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest for name, digest in before.items())
print(json.dumps({'passed': True, 'sourceHashes': before, 'sourceUnchanged': True, 'scratchRemoved': not scratch.exists(),
                  'actualMicrophoneOrDeviceActions': 0}))
