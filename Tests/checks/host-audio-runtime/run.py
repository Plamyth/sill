#!/usr/bin/env python3
"""부모가 Mini에서 실행하는 실제 production 소스 결합 검사."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path, nargs='?', help='부모가 배정한 비어 있는 격리 출력 경로')
parser.add_argument('--emit-only', action='store_true', help='Swift 실행 없이 정확한 컴파일 입력만 생성')
args = parser.parse_args()
temporary = tempfile.TemporaryDirectory(prefix='host-audio-runtime-') if args.output is None else None
output = Path(temporary.name) if temporary else args.output.resolve()
if not temporary:
    output.mkdir(parents=True, exist_ok=False)
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
fallback = root / 'Tests/checks/audio-forwarding-protection/fixtures'
manifest_path = fallback / 'manifest.json'
manifest = json.loads(manifest_path.read_text())
for name, expected in manifest['files'].items():
    fixture = fallback / name
    assert hashlib.sha256(fixture.read_bytes()).hexdigest() == expected
    actual = root / 'Sources/StreamProtocol' / name
    if actual.exists():
        assert actual.read_bytes() == fixture.read_bytes(), name
    else:
        protocol.append(fixture)

host = [root / 'Sources/SillHost' / name for name in [
    'LocalAudioParticipants.swift', 'AudioForwardingContract.swift', 'AudioForwardingCoordinator.swift',
    'AudioForwardingParticipants.swift', 'AudioForwardingProtection.swift', 'HostAudioPrivacyModel.swift',
    'HostSentry.swift', 'SentryAdmission.swift', 'LocalAudioReturn.swift', 'LocalAudioRelay.swift',
    'HostAudioForwardingRuntime.swift',
]]
remote = root / 'Sources/SillHost/RemoteAccess.swift'
coordinator = root / 'Sources/SillHost/StreamCoordinator.swift'
hal_fixture = root / 'Tests/checks/audio-forwarding-protection/Main.swift'
launch = root / 'Sources/SillHost/LocalAudioRelayLaunch.swift'
inputs = protocol + host + [remote, coordinator, hal_fixture, launch, manifest_path, *sorted(here.glob('*.*'))]
before = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}


def declaration(path, beginning):
    text = path.read_text()
    start = text.index(beginning)
    return text[start:text.index('\n}\n', start) + 3]


context = output / 'ConnectionContext.swift'
context.write_text('import Foundation\nimport StreamProtocol\n' +
                   declaration(remote, 'struct AudioForwardingPairedDevice:') +
                   '\nfunc runtimeFixturePeer(id: AudioForwardingDeviceID, generation: UUID) -> AudioForwardingPairedDevice {\n'
                   '    .init(id: id, pairingGeneration: generation)\n}\n' +
                   declaration(coordinator, '@MainActor\nstruct AudioForwardingConnectionContext'))
hal = output / 'HALBoundary.swift'
text = hal_fixture.read_text()
hal.write_text('import Foundation\nimport StreamProtocol\n' +
               text[text.index('@MainActor\nfinal class FakeHAL:'):text.index('@MainActor\nfinal class AuthenticationGate')])
assert 'LocalAudioRelayLaunch.makeForwardingRelay(participants: self.privacy.participants)' in host[-1].read_text()
assert not any(word in host[-1].read_text() for word in ('work.cancel(', 'task.cancel(', 'monitor.cancel('))
assert 'forwardingRegister(' not in host[-1].read_text() and 'forwardingRevoke(' not in host[-1].read_text()
assert not any(word in host[-1].read_text() for word in ('print(', 'NSLog(', 'Logger('))

shared = ['xcrun', 'swiftc', '-package-name', 'Sill', '-module-cache-path', str(output / 'cache')]
compile_protocol = shared + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
    *map(str, protocol), '-o', str(output / 'libStreamProtocol.dylib'),
    '-emit-module-path', str(output / 'StreamProtocol.swiftmodule')]
compile_host = shared + ['-parse-as-library', '-I', str(output), '-L', str(output), '-lStreamProtocol',
    '-Xlinker', '-rpath', '-Xlinker', str(output), *map(str, host), str(context), str(hal),
    str(here / 'Boundary.swift'), str(here / 'Main.swift'), '-o', str(output / 'checks')]
commands = [compile_protocol, compile_host, [str(output / 'checks'), str(output / 'cases'), str(here / 'child.py')]]
print(json.dumps({'sourceHashes': before, 'commands': commands, 'emitOnly': args.emit_only,
                  'actualHALOrServiceActions': False}, ensure_ascii=False), flush=True)
try:
    if not args.emit_only:
        print(subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True).strip(), flush=True)
        print(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip(), flush=True)
        (output / 'cases').mkdir()
        subprocess.run(compile_protocol, check=True, timeout=180)
        subprocess.run(compile_host, check=True, timeout=180)
        result = subprocess.run(commands[-1], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
        assert 'R' * 43 not in result.stdout + result.stderr, 'credential 원문 로그 유출'
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode:
            for events in sorted((output / 'cases').glob('*/events.jsonl'), key=lambda p: p.stat().st_mtime)[-3:]:
                print('FAILED_CASE_EVENTS', events.parent.name, events.read_text()[-12000:], flush=True)
        result.check_returncode()
finally:
    after = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    if temporary:
        temporary.cleanup()
    print(json.dumps({'sourceUnchanged': before == after, 'output': str(output),
                      'outputRetainedForParent': temporary is None, 'temporaryOutputRemoved': temporary is not None and not output.exists()}), flush=True)
    assert before == after
