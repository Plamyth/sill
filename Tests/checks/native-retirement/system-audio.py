import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root, output, build = [Path(p).resolve() for p in sys.argv[1:]]
output.mkdir(parents=True, exist_ok=False)
(output / 'tmp').mkdir()
here = root / 'Tests/checks/native-retirement'
sources = [root / 'Sources/SillHost/SystemAudioCapture.swift', here / 'FakeSCStream.swift', here / 'SystemAudio.swift', Path(__file__).resolve()]
hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
objects = sorted((build / 'StreamProtocol.build').glob('*.o'))
modules = build / 'Modules'
if not modules.is_dir():
    modules = build
    objects = [build / 'StreamProtocol.o']
assert objects
base = ['xcrun', 'swiftc', '-whole-module-optimization', '-package-name', 'Sill', '-module-cache-path', str(output.parent / 'sdk-cache')]
commands = [
    base + ['-emit-library', '-emit-module', '-module-name', 'ScreenCaptureKit', str(here / 'FakeSCStream.swift'),
            '-o', str(output / 'libScreenCaptureKit.dylib'), '-emit-module-path', str(output / 'ScreenCaptureKit.swiftmodule')],
    base + ['-parse-as-library', '-I', str(output), '-I', str(modules), '-L', str(output), '-lScreenCaptureKit',
            '-Xlinker', '-rpath', '-Xlinker', str(output), str(sources[0]), str(here / 'SystemAudio.swift'),
            *map(str, objects), '-o', str(output / 'checks')],
    [str(output / 'checks')],
]
record = {'sourceHashes': hashes, 'actualHardwareOrMediaActions': 0, 'scope': '실제 SystemAudioCapture와 가짜 ScreenCaptureKit 주입 경계', 'commands': []}
for index, command in enumerate(commands):
    result = subprocess.run(command, capture_output=True, text=True, timeout=900 if index < 2 else 60,
                            env={**os.environ, 'TMPDIR': str(output / 'tmp')})
    (output / (str(index) + '.log')).write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end='', flush=True)
    record['commands'].append({'command': command, 'exitCode': result.returncode})
    if result.returncode:
        break
record['sourceUnchanged'] = all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == digest for p, digest in hashes.items())
record['exitCode'] = result.returncode if record['sourceUnchanged'] else 2
(output / 'result.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
raise SystemExit(record['exitCode'])
