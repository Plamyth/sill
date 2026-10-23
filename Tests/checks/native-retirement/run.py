import hashlib
import json
from pathlib import Path
import subprocess
import sys

root, out = (Path(value).resolve() for value in sys.argv[1:])
out.mkdir(parents=True, exist_ok=False)
here = root / 'Tests/checks/native-retirement'
production = [root / 'Sources/SillHost' / (name + '.swift') for name in [
    'HostMicrophoneReceiver', 'HostMicrophoneGrant', 'MicrophoneIngress',
    'RemoteAudioCaptureLifecycle', 'SillVirtualMicrophoneOwner', 'HALMicrophoneSink']]
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
support = root / 'Tests/checks/microphone-uplink'
inputs = production + protocol + [support / (name + '.swift') for name in ['Main', 'Network', 'FakeHAL']] + [here / 'Main.swift', Path(__file__).resolve()]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
helpers = (support / 'Main.swift').read_text().split('@main struct Check {', 1)[0]
(out / 'Helpers.swift').write_text(helpers)
(out / 'FakeHAL.swift').write_text((support / 'FakeHAL.swift').read_text().replace('test.blackhole', 'BlackHole2ch_UID'))
owner = (root / 'Sources/SillHost/SillVirtualMicrophoneOwner.swift').read_text()
assert all(forbidden not in owner for forbidden in ['AudioInputHAL', 'AudioObjectSetPropertyData', 'previous: AudioDeviceID'])
commands = [
    ['swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache'),
     '-emit-library', '-emit-module', '-module-name', 'Network', str(support / 'Network.swift'),
     '-o', str(out / 'libNetwork.dylib'), '-emit-module-path', str(out / 'Network.swiftmodule')],
    ['swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache'),
     '-emit-library', '-emit-module', '-module-name', 'StreamProtocol', *map(str, protocol),
     '-o', str(out / 'libStreamProtocol.dylib'), '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')],
    ['swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache'),
     '-parse-as-library', '-I', str(out), '-L', str(out), '-lNetwork', '-lStreamProtocol',
     '-Xlinker', '-rpath', '-Xlinker', str(out), *map(str, production),
     str(out / 'Helpers.swift'), str(out / 'FakeHAL.swift'), str(here / 'Main.swift'), '-o', str(out / 'checks')],
    [str(out / 'checks')],
]
result = {'sourceHashes': before, 'scope': '실제 receiver·grant·ingress·capture lifecycle·virtual owner·HAL sink와 비활성 Network·HAL·privacy 경계',
          'physicalDefaultSetterAbsent': True, 'actualMediaOrDeviceActions': False, 'exitCode': 1, 'commands': []}
for index, command in enumerate(commands):
    check = subprocess.run(command, capture_output=True, text=True, timeout=120)
    (out / (str(index) + '.log')).write_text(check.stdout + check.stderr)
    print(check.stdout + check.stderr, end='', flush=True)
    result['commands'].append({'index': index, 'exitCode': check.returncode})
    result['exitCode'] = check.returncode
    if check.returncode:
        break
result['sourceUnchanged'] = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == value for name, value in before.items())
if not result['sourceUnchanged']:
    result['exitCode'] = 2
(out / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(result, ensure_ascii=False), flush=True)
raise SystemExit(result['exitCode'])
