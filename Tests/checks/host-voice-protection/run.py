import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
output, build = [Path(p).resolve() for p in sys.argv[1:]]
output.mkdir(parents=True, exist_ok=False)
(output / 'tmp').mkdir()
here = Path(__file__).resolve().parent

def block(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

coordinator = (root / 'Sources/SillHost/StreamCoordinator.swift').read_text()
methods = [block(coordinator, 'private func ' + name + '(').replace('NWConnection', 'BoundaryConnection') for name in [
    'nativeAudioBindingReady', 'audioPrivacyReady', 'audioPrivacyChanged', 'microphoneCatalog', 'canEnableRemoteAudio',
    'audioRouteAuthorized', 'sendAudioRouteState', 'publishAudioRoutes', 'handleAudioRoute']]
(output / 'CoordinatorFixture.swift').write_text((here / 'CoordinatorFixture.swift').read_text().replace('// PRODUCTION_BOUNDARIES', '\n'.join(methods)))
sources = [root / 'Sources/SillHost' / (name + '.swift') for name in [
    'HostAudioPrivacy', 'HostAudioPrivacyModel', 'HostExclusiveAudioSilence', 'LocalAudioReturn', 'LocalAudioParticipants',
    'SillVirtualMicrophoneOwner', 'HostMicrophoneGrant', 'HostMicrophoneReceiver', 'HALMicrophoneSink', 'AudioHardwareRoutes']]
sources += [here / 'Main.swift', here / 'FakeHAL.swift', here / 'LocalReturn.swift', here / 'Exclusive.swift', output / 'CoordinatorFixture.swift']
inputs = sorted(set(sources + [root / 'Sources/SillHost/StreamCoordinator.swift', root / 'Package.swift', here / 'CoordinatorFixture.swift', Path(__file__).resolve()] + list((root / 'Sources/StreamProtocol').glob('*.swift')) + [p for p in (root / 'Sources/AudioSilence').rglob('*') if p.is_file()]))
hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
modules = build / 'Modules'
objects = sorted((build / 'StreamProtocol.build').glob('*.o')) + sorted((build / 'AudioSilence.build').rglob('*.o'))
modulemap = build / 'AudioSilence.build/module.modulemap'
if not modules.is_dir():
    modules = build
    objects = [build / (name + '.o') for name in ['StreamProtocol', 'AudioSilence']]
    modulemap = build.parents[1] / 'Intermediates.noindex/GeneratedModuleMaps/AudioSilence.modulemap'
assert objects and modules.is_dir()
command = ['xcrun', 'swiftc', '-whole-module-optimization', '-parse-as-library', '-package-name', 'Sill', '-module-cache-path', str(output.parent / 'sdk-cache'),
           '-I', str(modules), '-Xcc', '-fmodule-map-file=' + str(modulemap), *map(str, sources), *map(str, objects), '-o', str(output / 'checks')]
record = {'scope': '생산 HAL 어댑터와 모델, 현재 coordinator 경계, 주입 HAL과 비활성 전송만 실행',
          'sourceSHA256': hashes, 'objectSHA256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in objects}, 'actualHardwareOrMediaActions': 0, 'commands': []}
for name, command in [('compile', command), ('checks', [str(output / 'checks')])]:
    result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=900 if name == 'compile' else 60,
                            env={**os.environ, 'TMPDIR': str(output / 'tmp')})
    (output / (name + '.log')).write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end='')
    record['commands'].append({'name': name, 'exitCode': result.returncode})
    if result.returncode: break
record['sourceUnchanged'] = all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == digest for p, digest in hashes.items())
(output / 'result.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
sys.exit(result.returncode if record['sourceUnchanged'] else 2)
