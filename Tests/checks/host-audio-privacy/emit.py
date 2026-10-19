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
assert connection.index('route.encrypted') < connection.index('armAndVerify()')
assert connection.index('self.remote?.isPaired(fingerprint) == true') < connection.index('armAndVerify()')
assert app.index('audioPrivacy?.reconcile()') < app.index('let c = try nativeAudioStartup.construct {')
construction = block(app, 'let c = try nativeAudioStartup.construct')
assert construction.count('try StreamCoordinator(') == 1
assert 'microphoneOwner: microphoneOwner, audioPrivacy: audioPrivacy' in construction
assert 'let nativeAudioStartup = NativeAudioStartup()' in app
assert 'self.nativeAudioStartup = nativeAudioStartup' in app
assert 'HostAudioPrivacy(defaults: .standard, nativeStartup: nativeAudioStartup)' in app
assert app.index('coordinator = c') < app.index('await c.start(')
constructor = block(coordinator, 'package init(')
assert constructor.count('try ') == 1 and 'server = try StreamServer(' in constructor
revocation = block(coordinator, 'self.audioPrivacy?.revokeForLocalReturn =')
assert 'guard let self else { return false }' in revocation
assert 'return await self.prepareLocalAudioReturn()' in revocation
assert constructor.index('server = try StreamServer(') < constructor.index(revocation)
assert 'self.audioPrivacy?.inspectForLocalReturn =' in constructor
assert 'self?.localAudioReturnFacts() ?? .unknown' in constructor
factory = block((ROOT / 'Sources/SillHost/HostAudioPrivacy.swift').read_text(), 'package convenience init(defaults:')
assert 'localReturnCoverage' not in factory
assert 'nativeStartup: nativeStartup' in factory and 'verifiedAllParticipants' not in app + factory + coordinator
menu = (ROOT / 'Sources/SillMenuBar/StatusItemController.swift').read_text()
assert 'entry.subtitle = model.localAudioReturnUnavailableReason ?? model.localAudioReturnNotice' in menu
assert 'entry.enabled = !model.localAudioReturnPending && model.localAudioReturnUnavailableReason == nil' in menu
request = block(app, 'func requestLocalAudioReturn()')
assert request.index('if let reason = localAudioReturnUnavailableReason') < request.index('Task { @MainActor in')
assert 'self.audioPrivacy = synthetic ? nil : audioPrivacy' in coordinator
assert 'audioPrivacy: HostAudioPrivacy? = nil' in coordinator
assert 'privacy?.verify() == true' in owner and 'AudioInputHAL' not in owner
assert 'activeLease == nil' in owner and owner.index('activeLease == nil') < owner.index('target.acquire(')
assert 'AudioObjectSetPropertyData' not in owner and 'previous' not in owner

methods = [block(coordinator, 'private func ' + name + '(') for name in [
    'audioPrivacyReady', 'audioPrivacyChanged', 'microphoneCatalog', 'canEnableRemoteAudio',
    'audioRouteAuthorized', 'sendAudioRouteState', 'publishAudioRoutes', 'handleAudioRoute',
    'prepareLocalAudioReturn', 'localAudioReturnFacts', 'revokeRemoteAudio', 'stopRemoteAudioIfIdle', 'remoteAudioState'
]]
fixture = (HERE / 'CoordinatorFixture.swift').read_text()
fixture = fixture.replace('        // PRODUCTION_REVOCATION', revocation.replace('self.audioPrivacy?', 'privacy?'))
server = (ROOT / 'Sources/SillHost/StreamServer.swift').read_text()
server_methods = [block(server, marker) for marker in [
    'func setRemoteAudio(', 'func resetRemoteAudio(', 'func drainRemoteAudio(',
    'func broadcastRemoteAudio(', 'private func send(_ raw:'
]]
fixture = fixture.replace('    // PRODUCTION_SERVER_BOUNDARIES', '\n\n'.join(server_methods).replace('NWConnection', 'BoundaryConnection'))
fixture = fixture.replace('    // PRODUCTION_BOUNDARIES', '\n\n'.join(methods).replace('NWConnection', 'BoundaryConnection'))
source = {str(p.relative_to(ROOT)): p.read_bytes() for p in (ROOT / 'Sources/StreamProtocol').glob('*.swift')}
for name in ['HostAudioPrivacy', 'HostAudioPrivacyModel', 'LocalAudioReturn', 'LocalAudioParticipants', 'SillVirtualMicrophoneOwner', 'HALMicrophoneSink',
             'HostMicrophoneGrant', 'HostMicrophoneReceiver', 'AudioHardwareRoutes', 'RemoteAudioCaptureLifecycle', 'SystemAudioCapture']:
    path = ROOT / 'Sources/SillHost' / (name + '.swift')
    source[str(path.relative_to(ROOT))] = path.read_bytes()
files = {}
for name, data in source.items():
    folder = 'StreamProtocol' if '/StreamProtocol/' in name else 'HostPrivacyChecks'
    files['Sources/' + folder + '/' + Path(name).name] = data
files['Sources/HostPrivacyChecks/CoordinatorFixture.swift'] = fixture.encode()
for name in ['FakeHAL.swift', 'Main.swift', 'ParticipantFixture.swift']:
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
    'serverBodiesSHA256': [hashlib.sha256(data.encode()).hexdigest() for data in server_methods],
    'coordinatorBodiesSHA256': [hashlib.sha256(data.encode()).hexdigest() for data in methods],
    'appConstructionSHA256': hashlib.sha256(construction.encode()).hexdigest(),
    'coordinatorConstructorSHA256': hashlib.sha256(constructor.encode()).hexdigest(),
    'coordinatorRevocationSHA256': hashlib.sha256(revocation.encode()).hexdigest(),
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
