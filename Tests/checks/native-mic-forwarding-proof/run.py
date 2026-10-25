"""Production privacy/owner/receiver/HAL, with inert HAL and no product process."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
host = root / 'Sources/SillHost'
names = ['HostAudioPrivacyModel', 'LocalAudioParticipants', 'SillVirtualMicrophoneOwner',
         'HostMicrophoneGrant', 'HostMicrophoneReceiver', 'HALMicrophoneSink']
sources = [host / (name + '.swift') for name in names]
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
fake = root / 'Tests/checks/host-voice-protection/FakeHAL.swift'
network = root / 'Tests/checks/microphone-uplink/Network.swift'
inputs = sources + protocol + [fake, network, here / 'Main.swift', Path(__file__).resolve(),
    host / 'LocalAudioReturn.swift', host / 'HostAudioPrivacy.swift', host / 'StreamCoordinator.swift']
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
record = {'sourceSHA256': hashes, 'actualMicrophoneOrHALWrites': 0, 'actualStreamStarts': 0,
          'hostUIOrDeviceActions': 0, 'fullRelease': False, 'nodeOrJava': False, 'commands': []}
with tempfile.TemporaryDirectory(prefix='native-mic-proof-') as temporary:
    out = Path(temporary)
    # Keep complete production types; exclude only the installed-app factories/auth UI.
    core = (host / 'HostAudioPrivacy.swift').read_text().split('\nextension HostAudioPrivacy {', 1)[0]
    startup = (host / 'LocalAudioReturn.swift').read_text().split('\n@MainActor\nfinal class LocalAudioAuthentication', 1)[0]
    generated = {'CoreAudioPrivacyHAL.swift': core, 'NativeAudioStartup.swift': startup}
    coordinator = (host / 'StreamCoordinator.swift').read_text()
    start = coordinator.index('    private func nativeAudioBindingReady(')
    end = coordinator.index('\n    private func audioPrivacyReady()', start)
    boundary = coordinator[start:end].replace('private func', 'func')
    generated['BindingBoundary.swift'] = '''import Foundation
import Network
@MainActor final class BindingBoundary {
    struct Route { let fingerprint: Data? }
    var routes: [ObjectIdentifier: Route] = [:]
    var authenticated = true
    var nativeAudioBindingAuthorized: ((Data, PrivacyAudioScope) -> Bool)?
    func audioRouteAuthorized(_ connection: NWConnection) -> Bool { authenticated }
''' + boundary + '\n}\n'
    for name, text in generated.items():
        (out / name).write_text(text)
    record['productionExtractionSHA256'] = {k: hashlib.sha256(v.encode()).hexdigest() for k, v in generated.items()}
    base = ['xcrun', 'swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
    commands = [
        ('network', base + ['-emit-library', '-emit-module', '-module-name', 'Network', str(network),
            '-o', str(out / 'libNetwork.dylib'), '-emit-module-path', str(out / 'Network.swiftmodule')]),
        ('protocol', base + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
            *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'),
            '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')]),
        ('compile', base + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol', '-lNetwork',
            '-Xlinker', '-rpath', '-Xlinker', str(out), *map(str, sources),
            *[str(out / name) for name in generated], str(fake), str(here / 'Main.swift'), '-o', str(out / 'checks')]),
        ('checks', [str(out / 'checks')])]
    for name, command in commands:
        result = subprocess.run(command, cwd=root, text=True, capture_output=True, timeout=180,
                                env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        print(result.stdout + result.stderr, end='', flush=True)
        record['commands'].append({'name': name, 'exitCode': result.returncode})
        if result.returncode:
            break
record['exitCode'] = result.returncode
record['sourceUnchanged'] = all(hashlib.sha256((root / p).read_bytes()).hexdigest() == h for p, h in hashes.items())
record['scratchRemoved'] = not out.exists()
print('RESULT_JSON ' + json.dumps(record, sort_keys=True), flush=True)
raise SystemExit(record['exitCode'] if record['sourceUnchanged'] and record['scratchRemoved'] else 2)
