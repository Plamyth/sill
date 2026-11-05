from pathlib import Path
import hashlib
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
microphone = (root / 'visionOSClient/StreamClient+VisionMicrophone.swift').read_text()
assert 'if control.operation == .start {\n                    DispatchQueue.main.asyncAfter(deadline: .now() + 12)' in microphone
assert 'else if control.operation == .stop {\n                    DispatchQueue.main.asyncAfter(deadline: .now() + 6)' in microphone

sources = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
client = root / 'visionOSClient/VisionProviderCall.swift'
test = Path(__file__).with_name('main.swift')
stop_test = Path(__file__).with_name('StopOff.swift')
forwarding = root / 'visionOSClient/VisionAudioForwarding.swift'
intent = root / 'visionOSClient/VisionRemoteAudioIntent.swift'
authority = root / 'visionOSClient/VisionRemoteAudioAuthority.swift'
handoff = Path(__file__).with_name('WindowHandoff.swift')
fixture = root / 'Tests/checks/vision-audio-privacy/adapter.swift'
transport_source = root / 'iOSClient/StreamClient.swift'
inputs = sources + [client, test, stop_test, forwarding, intent, authority, handoff, fixture, transport_source]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
with tempfile.TemporaryDirectory(prefix='vision-provider-call-') as temporary:
    out = Path(temporary)
    swift = ['xcrun', 'swiftc', '-package-name', 'Sill', '-module-cache-path', str(out/'cache')]
    subprocess.run(swift + ['-emit-module', '-emit-library', '-module-name', 'StreamProtocol',
        *map(str, sources), '-o', str(out/'libStreamProtocol.dylib'),
        '-emit-module-path', str(out/'StreamProtocol.swiftmodule')], check=True)
    subprocess.run(swift + ['-I', str(out), '-L', str(out), '-lStreamProtocol', str(client), str(forwarding), str(intent), str(test),
        '-o', str(out/'checks')], check=True)
    subprocess.run([str(out/'checks')], env={**os.environ, 'DYLD_LIBRARY_PATH': str(out)}, check=True)
    source = client.read_text()
    def member(marker):
        start = source.index(marker)
        opening = source.index('{', start)
        depth = 1
        end = opening + 1
        while depth:
            depth += (source[end] == '{') - (source[end] == '}')
            end += 1
        return source[start:end]
    adapter = '\n'.join(member(marker) for marker in [
        '    func consumeVisionNativePreparedTarget(', '    var visionProviderCanStart:', '    var visionProviderCanStop:',
        '    func performVisionProviderCall(', '    func observeVisionProviderCalls('])
    (out/'Adapter.swift').write_text('import Foundation\nimport StreamProtocol\nextension StreamClient {\n' + adapter + '\n}\n')
    (out/'main.swift').write_text(stop_test.read_text())
    subprocess.run(swift + ['-I', str(out), '-L', str(out), '-lStreamProtocol',
        str(client), str(forwarding), str(intent), str(out/'Adapter.swift'), str(out/'main.swift'),
        '-o', str(out/'stop-checks')], check=True)
    subprocess.run([str(out/'stop-checks')], env={**os.environ, 'DYLD_LIBRARY_PATH': str(out)}, check=True)
    store_source = authority.read_text()
    store = store_source[store_source.index('final class VisionRemoteAudioStore {'):store_source.rindex('\n#endif')]
    (out/'Store.swift').write_text('import Foundation\nimport StreamProtocol\n' + store)
    shared_adapter = '\n'.join(member(marker) for marker in [
        '    var visionProviderCanStart:', '    var visionProviderCanStop:', '    func performVisionProviderCall(',
        '    func observeVisionProviderCalls(', '    private func scheduleVisionProviderQuery(',
        '    func receiveVisionProviderCall('])
    shared_adapter = shared_adapter.replace('VisionRemoteAudioStore.shared', 'store').replace('    private func scheduleVisionProviderQuery(', '    func scheduleVisionProviderQuery(')
    (out/'HandoffAdapter.swift').write_text('import Foundation\nimport StreamProtocol\nextension StreamClient {\n' + shared_adapter + '\n}\n')
    raw_transport = transport_source.read_text()
    transport = raw_transport[raw_transport.index('    func receiveVisionAudioCatalogAcknowledgement('):raw_transport.index('    func updateVisionMacAudioRoutes(')]
    transport = transport.replace('VisionRemoteAudioStore.shared', 'store')
    (out/'CatalogTransport.swift').write_text('import Foundation\nimport StreamProtocol\nextension StreamClient {\n' + transport + '\n}\n')
    (out/'main.swift').write_bytes(handoff.read_bytes())
    subprocess.run(swift + ['-D', 'CALL_HANDOFF_FIXTURE', '-I', str(out), '-L', str(out), '-lStreamProtocol',
        str(client), str(forwarding), str(intent), str(authority), str(out/'Store.swift'), str(fixture),
        str(out/'HandoffAdapter.swift'), str(out/'CatalogTransport.swift'), str(out/'main.swift'), '-o', str(out/'handoff-checks')], check=True)
    subprocess.run([str(out/'handoff-checks')], env={**os.environ, 'DYLD_LIBRARY_PATH': str(out)}, check=True)
assert before == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
print('SOURCE_UNCHANGED=true; SCRATCH_REMOVED=' + str(not out.exists()).lower())
