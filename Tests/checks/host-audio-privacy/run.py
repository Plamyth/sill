#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=False)
build = output / 'build'
modules = build / 'Modules'
modules.mkdir(parents=True)
protocol = build / 'StreamProtocol.build'
silence = build / 'AudioSilence.build'
protocol.mkdir()
silence.mkdir()
sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
inputs = [p for directory in ['Sources/StreamProtocol', 'Sources/SillHost', 'Sources/AudioSilence',
                              'Tests/checks/host-audio-privacy', 'Tests/checks/host-voice-protection']
          for p in (root / directory).rglob('*') if p.is_file()]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
modulemap = silence / 'module.modulemap'
modulemap.write_text('module AudioSilence { header "' + str(root / 'Sources/AudioSilence/include/AudioSilence.h') + '" export * }\n')
record = {'sourceSHA256': hashes, 'SDK': sdk, 'actualPropertyWrites': 0, 'audioStreamsStarted': 0,
          'hostUIOrDeviceOrServiceActions': 0, 'scope': '생산 HAL과 모델 및 journal을 주입 HAL로 실행', 'commands': []}
with tempfile.TemporaryDirectory(prefix='sill-stream-') as compiler_tmp:
    base = ['xcrun', 'swiftc', '-sdk', sdk, '-target', 'arm64-apple-macosx14.0',
            '-module-cache-path', str(output / 'sdk-cache')]
    commands = [
        ('protocol', base + ['-parse-as-library', '-whole-module-optimization', '-emit-module', '-emit-object',
            '-module-name', 'StreamProtocol', '-package-name', 'Sill',
            *map(str, sorted((root / 'Sources/StreamProtocol').glob('*.swift'))),
            '-emit-module-path', str(modules / 'StreamProtocol.swiftmodule'), '-o', str(protocol / 'StreamProtocol.o')]),
        ('silence', ['xcrun', 'clang', '-isysroot', sdk, '-c', str(root / 'Sources/AudioSilence/AudioSilence.c'),
                     '-I', str(root / 'Sources/AudioSilence/include'), '-o', str(silence / 'AudioSilence.o')]),
        ('voice-and-stream', [sys.executable, '-B', str(root / 'Tests/checks/host-voice-protection/run.py'),
                              str(output / 'regression'), str(build)])]
    for name, command in commands:
        result = subprocess.run(command, cwd=root, text=True, capture_output=True, timeout=600,
                                env={**os.environ, 'TMPDIR': compiler_tmp, 'PYTHONDONTWRITEBYTECODE': '1'})
        (output / (name + '.log')).write_text(result.stdout + result.stderr)
        print(result.stdout + result.stderr, end='', flush=True)
        record['commands'].append({'name': name, 'exitCode': result.returncode})
        if result.returncode:
            break
record['sourceUnchanged'] = hashes == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
record['exitCode'] = result.returncode if record['sourceUnchanged'] else 2
(output / 'result.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print('STREAM_RESULT ' + json.dumps(record, ensure_ascii=False), flush=True)
sys.exit(record['exitCode'])
