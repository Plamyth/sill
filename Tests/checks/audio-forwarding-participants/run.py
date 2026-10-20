#!/usr/bin/env python3
import hashlib
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
inputs = files + [source, here / 'Main.swift']
before = [hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs]
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
    command = ['xcrun', 'swiftc', '-parse-as-library', '-package-name', 'Sill',
        '-module-cache-path', str(out / 'cache'), *map(str, files), str(native), str(unused),
        str(here / 'Main.swift'), '-o', str(out / 'checks')]
    subprocess.run(command, check=True)
    subprocess.run([str(out / 'checks')], check=True, timeout=30)
assert before == [hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs]
