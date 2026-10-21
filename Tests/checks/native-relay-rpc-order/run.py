import hashlib
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
assert sys.argv[2:] in [[], ['http-admission'], ['conflict'], ['registered'], ['bootstrap'], ['evidence']]
check = root / 'Tests/checks/native-relay-rpc-order'
names = ['Sources/SillHost/LocalAudioRelay.swift', 'Sources/SillHost/LocalAudioParticipants.swift',
         'Sources/SillHost/AudioForwardingContract.swift', 'Sources/SillHost/RemoteAccess.swift',
         'Sources/SillHost/AudioForwardingCoordinator.swift']
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
sources = [root / n for n in names] + sorted(check.glob('*.swift')) + [check / 'child.py', Path(__file__).resolve()] + protocol
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
    access = (root / names[3]).read_text()
    paired = access[access.index('struct AudioForwardingPairedDevice:'):access.index('\n/// Pairing')]
    (out / 'Paired.swift').write_text('import Foundation\nimport StreamProtocol\n' + paired.replace('fileprivate init(', 'init('))
    (out / 'Registry.swift').write_text((root / names[1]).read_text() + '\n' + (check / 'RegistryProbe.swift').read_text())
    binary = out / 'checks'
    shared = ['swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
    module = subprocess.run(shared + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')], timeout=120, capture_output=True, text=True)
    print(module.stdout + module.stderr, end='')
    compile_result = None
    if module.returncode == 0:
        compile_result = subprocess.run(shared + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
            '-Xlinker', '-rpath', '-Xlinker', str(out), str(out / 'Relay.swift'), str(out / 'Registry.swift'),
            str(root / names[2]), str(root / names[4]), str(out / 'Paired.swift'), str(check / 'Main.swift'),
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
    after = hashes()
    receipt = dict(protocolCompileExit=module.returncode, compileExit=compile_result.returncode if compile_result else None,
        checksExit=executed.returncode if executed else None,
        sourceHashes=before, sharedModuleSourceHashes=protocol_hashes, sourceUnchanged=before == after,
        extractedRelaySHA256=hashlib.sha256(source.encode()).hexdigest(),
        actualMediaOrDeviceActions=False)
    print(json.dumps(receipt, sort_keys=True))
    sys.exit(0 if compile_result is not None and compile_result.returncode == 0 and executed and executed.returncode == 0 and before == after else 1)
