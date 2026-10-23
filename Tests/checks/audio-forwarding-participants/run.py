#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[2]
host = root / 'Sources/SillHost'
source = host / 'LocalAudioReturn.swift'
startup = source.read_text().split('\nstruct LocalAudioState:', 1)[0]
assert 'package final class NativeAudioStartup' in startup
files = [host / name for name in ['LocalAudioParticipants.swift', 'AudioForwardingContract.swift',
    'AudioForwardingCoordinator.swift', 'AudioForwardingParticipants.swift']]
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
inputs = files + [source, here / 'Main.swift', here / 'run.py'] + protocol
before = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
protocol_hashes = {str(path.relative_to(root)): before[str(path.relative_to(root))] for path in protocol}
try:
    with tempfile.TemporaryDirectory(prefix='forwarding-participants-') as temporary:
        out = Path(temporary)
        native = out / 'NativeAudioStartup.swift'
        native.write_text(startup)
        unused = out / 'UnavailableLaunch.swift'
        unused.write_text('''enum LocalAudioRelayLaunch {
        enum Failure: Error { case unavailable }
        static func validateInstalledRuntime() throws -> Int { throw Failure.unavailable }
        static func requireLaunchSupport(_ value: Int) throws { throw Failure.unavailable }
    }
    ''')
        shared = ['xcrun', 'swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
        subprocess.run(shared + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
            *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'),
            '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')], check=True)
        command = shared + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
            '-Xlinker', '-rpath', '-Xlinker', str(out), *map(str, files), str(native), str(unused),
            str(here / 'Main.swift'), '-o', str(out / 'checks')]
        subprocess.run(command, check=True)
        subprocess.run([str(out / 'checks')], check=True, timeout=30)
finally:
    after = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    print(json.dumps({'sourceHashes': before, 'sharedModuleSourceHashes': protocol_hashes,
        'sourceUnchanged': before == after, 'actualMediaOrDeviceActions': False}, sort_keys=True), flush=True)
    assert before == after
