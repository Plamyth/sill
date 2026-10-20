#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import sys
import shutil
from contextlib import contextmanager

here = Path(__file__).resolve().parent
root = here.parents[2]
manifest = json.loads((here / 'fixtures/manifest.json').read_text())
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
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
    'LocalAudioRelayLaunch.swift', 'LocalAudioRelayClosure.swift', 'LocalAudioRelayMachO.swift',
    'LocalAudioRelay.swift', 'AudioForwardingProtection.swift',
]]
relay_source = root / 'Sources/SillHost/RemoteAccess.swift'
relay = relay_source.read_text()
start = relay.index('struct AudioForwardingPairedDevice:')
runtime_type = relay[start:relay.index('\n}\n', start) + 3]
inputs = protocol + host + [relay_source, here / 'Main.swift', here / 'run.py', here / 'fixtures/manifest.json']
before = [hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs]
input_manifest = {str(p.relative_to(root)): digest for p, digest in zip(inputs, before)}
protocol_hashes = {str(p.relative_to(root)): input_manifest[str(p.relative_to(root))] for p in protocol}
print('INPUT_SHA256', hashlib.sha256(json.dumps(input_manifest, sort_keys=True).encode()).hexdigest(), flush=True)
print('SWIFTC', subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True).strip(), flush=True)
print('MACOS_SDK', subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip(), flush=True)
print('검증 범위는 fixture 프로토콜과 실제 보호 모델입니다. 전체 앱 SDK 빌드·실제 HAL·표면·센서·설치·기기 수용은 검증하지 않습니다.', flush=True)
@contextmanager
def owned_output():
    path = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else Path(tempfile.mkdtemp(prefix='forwarding-protection-'))
    if len(sys.argv) == 2: path.mkdir(parents=True, exist_ok=False)
    try: yield str(path)
    finally:
        shutil.rmtree(path)
        print('OUTPUT_REMOVED', not path.exists())
try:
    with owned_output() as temporary:
        out = Path(temporary)
        runtime = out / 'RuntimeExpectation.swift'
        runtime.write_text('import Foundation\nimport StreamProtocol\n' + runtime_type)
        shared = ['xcrun', 'swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
        subprocess.run(shared + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
            *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'),
            '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')], check=True, timeout=180)
        subprocess.run(shared + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
            '-Xlinker', '-rpath', '-Xlinker', str(out), *map(str, host), str(runtime), str(here / 'Main.swift'),
            '-o', str(out / 'checks')], check=True, timeout=180)
        subprocess.run([str(out / 'checks')], check=True, timeout=30)
finally:
    after = [hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs]
    print(json.dumps({'sourceHashes': input_manifest, 'sharedModuleSourceHashes': protocol_hashes,
        'sourceUnchanged': before == after, 'actualMediaOrDeviceActions': False}, sort_keys=True), flush=True)
    assert before == after
    print('SOURCE_UNCHANGED', True, flush=True)
