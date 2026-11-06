import hashlib
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
assert sys.argv[2:] in [[], ['http-admission'], ['conflict'], ['registered'], ['bootstrap'], ['evidence'], ['latency']]
check = root / 'Tests/checks/native-relay-rpc-order'
names = ['Sources/SillHost/LocalAudioRelay.swift', 'Sources/SillHost/LocalAudioParticipants.swift',
         'Sources/SillHost/AudioForwardingContract.swift', 'Sources/SillHost/RemoteAccess.swift',
         'Sources/SillHost/AudioForwardingCoordinator.swift', 'Sources/SillHost/HostLog.swift',
         'Sources/SillHost/ProviderCallBridge.swift']
server_path = root / 'Sources/SillHost/StreamServer.swift'
role_path = root / 'Sources/SillHost/StreamPeerRole.swift'
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
sources = [root / n for n in names] + sorted(check.glob('*.swift')) + [check / 'child.py', Path(__file__).resolve(), server_path, role_path] + protocol
def block(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]
def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
before = hashes()
protocol_hashes = {str(p.relative_to(root)): before[str(p.relative_to(root))] for p in protocol}
with tempfile.TemporaryDirectory(prefix='relay-rpc-check-') as scratch:
    out = Path(scratch)
    source = (root / names[0]).read_text() + '\n' + (check / 'Probe.swift').read_text()
    source += '''
extension LocalAudioRelay {
    var checkBootstrapBoot: UUID? { if case .connected(let boot) = state { boot } else { nil } }
    var checkBootstrapRegisteredBoot: UUID? { registeredBoot }
    func checkBootstrapReplaceBoot(_ boot: UUID) { state = .connected(boot); registeredBoot = boot }
    func checkEvidenceReplaceRegisteredBoot(_ boot: UUID) { registeredBoot = boot }
}
'''
    (out / 'Relay.swift').write_text(source)
    server_fixture = (check / 'ServerLatency.swift').read_text()
    for marker in ['final class ForwardingExchange:', 'private func receiveForwarding(', 'func sendForwardingState(']:
        server_fixture = server_fixture.replace('// ' + marker, block(server_path.read_text(), marker).removeprefix('private '))
    (out / 'Server.swift').write_text(server_fixture)
    access = (root / names[3]).read_text()
    paired = access[access.index('struct AudioForwardingPairedDevice:'):access.index('\n/// Pairing')]
    (out / 'Paired.swift').write_text('import Foundation\nimport StreamProtocol\n' + paired.replace('fileprivate init(', 'init('))
    bridge = (root / names[6]).read_text()
    models = bridge[:bridge.index('struct ProviderCallSignedEnvelope:')]
    models += bridge[bridge.index('struct ProviderCallChallenge:'):bridge.index('private struct ProviderIdentityBody:')]
    (out / 'Models.swift').write_text(models)
    (out / 'Registry.swift').write_text((root / names[1]).read_text() + '\n' + (check / 'RegistryProbe.swift').read_text())
    binary = out / 'checks'
    shared = ['swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
    module = subprocess.run(shared + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')], timeout=120, capture_output=True, text=True)
    print(module.stdout + module.stderr, end='')
    compile_result = None
    parsed = subprocess.run(['swiftc', '-frontend', '-parse', str(server_path)], timeout=120, capture_output=True, text=True)
    print(parsed.stdout + parsed.stderr, end='')
    if module.returncode == 0 and parsed.returncode == 0:
        compile_result = subprocess.run(shared + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
            '-Xlinker', '-rpath', '-Xlinker', str(out), str(out / 'Relay.swift'), str(out / 'Registry.swift'),
            str(root / names[2]), str(root / names[4]), str(root / names[5]), str(out / 'Models.swift'),
            str(out / 'Paired.swift'), str(check / 'Main.swift'), str(check / 'Latency.swift'), str(out / 'Server.swift'), str(role_path),
            '-o', str(binary)], timeout=120, capture_output=True, text=True)
        print(compile_result.stdout + compile_result.stderr, end='')
    executed = None
    if compile_result is not None and compile_result.returncode == 0:
        worker = subprocess.Popen([str(binary), str(check / 'child.py'), str(out), *sys.argv[2:]],
            start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            output, _ = worker.communicate(timeout=90)
        except subprocess.TimeoutExpired:
            os.killpg(worker.pid, signal.SIGKILL)
            output, _ = worker.communicate()
        finally:
            try:
                os.killpg(worker.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        executed = worker
        print(output, end='')
        if sys.argv[2:] == ['latency']:
            assert not any(prefix in output for prefix in ['audio.trace relayRPC ', 'audio.trace relayRead ', 'audio.trace forwardingReply ']), 'diagnostics reached synchronous stdout'
    after = hashes()
    receipt = dict(protocolCompileExit=module.returncode, serverSyntaxExit=parsed.returncode, compileExit=compile_result.returncode if compile_result else None,
        checksExit=executed.returncode if executed else None,
        sourceHashes=before, sharedModuleSourceHashes=protocol_hashes, sourceUnchanged=before == after,
        extractedRelaySHA256=hashlib.sha256(source.encode()).hexdigest(),
        actualMediaOrDeviceActions=False)
    print(json.dumps(receipt, sort_keys=True))
    sys.exit(0 if compile_result is not None and compile_result.returncode == 0 and executed and executed.returncode == 0 and before == after else 1)
