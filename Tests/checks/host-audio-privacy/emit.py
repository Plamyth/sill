#!/usr/bin/env python3
"""Emit an isolated injected test package only. The parent owns compilation and execution."""
import argparse
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True, help='parent-owned approved scratch/RAM directory')
args = parser.parse_args()
output = args.output.resolve()
if output.exists():
    raise SystemExit('output must be a new directory; preserve any previous attempt')


def block(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


coordinator = (ROOT / 'Sources/SillHost/StreamCoordinator.swift').read_text()
app = (ROOT / 'Sources/SillMenuBar/AppModel.swift').read_text()
owner = (ROOT / 'Sources/SillHost/SillVirtualMicrophoneOwner.swift').read_text()
connection = block(coordinator, 'server.onClientConnected =')
assert connection.index('armAndVerify()') < connection.index('self.sendCatalog(to: connection)')
assert app.index('audioPrivacy?.reconcile()') < app.index('let c = try StreamCoordinator(')
assert 'self.audioPrivacy = synthetic ? nil : audioPrivacy' in coordinator
assert 'audioPrivacy: HostAudioPrivacy? = nil' in coordinator
assert 'privacy?.verify() == true' in owner and 'AudioInputHAL' not in owner
assert 'activeLease == nil' in owner and owner.index('activeLease == nil') < owner.index('target.acquire(')
assert 'AudioObjectSetPropertyData' not in owner and 'previous' not in owner

methods = [block(coordinator, 'private func ' + name + '(') for name in [
    'audioPrivacyReady', 'audioPrivacyChanged', 'microphoneCatalog', 'canEnableRemoteAudio',
    'audioRouteAuthorized', 'sendAudioRouteState', 'publishAudioRoutes', 'handleAudioRoute'
]]
fixture = (HERE / 'CoordinatorFixture.swift').read_text()
fixture = fixture.replace('    // PRODUCTION_BOUNDARIES', '\n\n'.join(methods).replace('NWConnection', 'BoundaryConnection'))
source = {str(p.relative_to(ROOT)): p.read_bytes() for p in (ROOT / 'Sources/StreamProtocol').glob('*.swift')}
for name in ['HostAudioPrivacy', 'HostAudioPrivacyModel', 'SillVirtualMicrophoneOwner', 'HALMicrophoneSink',
             'HostMicrophoneGrant', 'HostMicrophoneReceiver', 'AudioHardwareRoutes']:
    path = ROOT / 'Sources/SillHost' / (name + '.swift')
    source[str(path.relative_to(ROOT))] = path.read_bytes()
files = {}
for name, data in source.items():
    folder = 'StreamProtocol' if '/StreamProtocol/' in name else 'HostPrivacyChecks'
    files['Sources/' + folder + '/' + Path(name).name] = data
files['Sources/HostPrivacyChecks/CoordinatorFixture.swift'] = fixture.encode()
for name in ['FakeHAL.swift', 'Main.swift']:
    files['Sources/HostPrivacyChecks/' + name] = (HERE / name).read_bytes()
files['Package.swift'] = b'''// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "HostAudioPrivacyChecks", platforms: [.macOS(.v14)], targets: [
    .target(name: "StreamProtocol"),
    .executableTarget(name: "HostPrivacyChecks", dependencies: ["StreamProtocol"])
])
'''
manifest = {
    'base': '0dd10d1f9463001531416f37d756214b0ff32456',
    'productionSHA256': {name: hashlib.sha256(data).hexdigest() for name, data in source.items()},
    'coordinatorBodiesSHA256': [hashlib.sha256(data.encode()).hexdigest() for data in methods],
    'emittedSHA256': {name: hashlib.sha256(data).hexdigest() for name, data in files.items()},
    'scope': 'Injected HAL and substituted transport only. No native hardware calls or source-guard acceptance.'
}
output.mkdir(parents=True)
for name, data in files.items():
    path = output / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({'output': str(output), 'files': len(files), 'executed': False}))
