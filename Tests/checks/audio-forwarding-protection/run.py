#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[2]
manifest = json.loads((here / 'fixtures/manifest.json').read_text())
protocol = list((root / 'Sources/StreamProtocol').glob('*.swift'))
for name, expected in manifest['files'].items():
    fixture = here / 'fixtures' / name
    assert hashlib.sha256(fixture.read_bytes()).hexdigest() == expected
    actual = root / 'Sources/StreamProtocol' / name
    if actual.exists():
        assert actual.read_bytes() == fixture.read_bytes()
    else:
        protocol.append(fixture)
host = [root / 'Sources/SillHost' / name for name in [
    'LocalAudioParticipants.swift', 'AudioForwardingContract.swift', 'AudioForwardingCoordinator.swift',
    'HostAudioPrivacyModel.swift', 'HostSentry.swift', 'SentryAdmission.swift', 'LocalAudioReturn.swift',
    'LocalAudioRelayLaunch.swift', 'AudioForwardingProtection.swift',
]]
relay_source = root / 'Sources/SillHost/LocalAudioRelay.swift'
relay = relay_source.read_text()
start = relay.index('struct LocalAudioRelayRuntimeExpectation {')
runtime_type = relay[start:relay.index('\n}\n', start) + 3]
inputs = protocol + host + [relay_source, here / 'Main.swift']
before = [hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs]
with tempfile.TemporaryDirectory(prefix='forwarding-protection-') as temporary:
    out = Path(temporary)
    runtime = out / 'RuntimeExpectation.swift'
    runtime.write_text(runtime_type)
    shared = ['xcrun', 'swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
    subprocess.run(shared + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')], check=True)
    subprocess.run(shared + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
        '-Xlinker', '-rpath', '-Xlinker', str(out), *map(str, host), str(runtime), str(here / 'Main.swift'),
        '-o', str(out / 'checks')], check=True)
    subprocess.run([str(out / 'checks')], check=True, timeout=30)
assert before == [hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs]
