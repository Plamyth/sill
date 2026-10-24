import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
archive = Path(sys.argv[1]).resolve()
archive.mkdir(parents=True, exist_ok=True)
label = sys.argv[2] if len(sys.argv) > 2 else 'checks'
receipt = archive / (label + '.json')
log_path = archive / (label + '.log')
if receipt.exists() or log_path.exists():
    raise SystemExit('기존 검증 영수증을 보존하고 다른 시도 이름으로 실행하세요.')
inputs = sorted((root / 'Sources/StreamProtocol').glob('*.swift')) + [
    root / 'Sources/SillHost/SentryAdmission.swift', Path(__file__).with_name('Main.swift'), Path(__file__)] + sorted(Path(__file__).parent.glob('*.json'))
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
record = {'scope': 'production DTO와 Admission 실행 및 macOS/iOS/visionOS SDK 타입 검사',
          'externalEffects': 0, 'physicalAcceptance': False, 'commands': [], 'sourceSHA256': hashes}
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
compiler = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
try:
    with tempfile.TemporaryDirectory(prefix='sentry-v2-') as scratch, log_path.open('wb') as log:
        out = Path(scratch)
        def run(args):
            result = subprocess.run(args, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            record['commands'].append({'args': args, 'exitCode': result.returncode})
            log.flush()
            if result.returncode:
                raise RuntimeError('검사 명령 실패')
        protocol = sorted(map(str, (root / 'Sources/StreamProtocol').glob('*.swift')))
        for sdk_name, target in [('macosx', 'arm64-apple-macosx14.0'), ('iphoneos', 'arm64-apple-ios17.0'), ('xros', 'arm64-apple-xros2.5')]:
            sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', sdk_name, '--show-sdk-path'], env=env, text=True).strip()
            base = [compiler, '-swift-version', '5', '-parse-as-library', '-package-name', 'sill',
                    '-sdk', sdk, '-target', target, '-module-cache-path', str(out / 'cache')]
            module = out / sdk_name
            module.mkdir()
            emit = ['-whole-module-optimization', '-emit-module', '-module-name', 'StreamProtocol']
            output = ['-emit-module-path', str(module / 'StreamProtocol.swiftmodule')]
            if sdk_name == 'macosx':
                emit += ['-emit-object']
                output += ['-o', str(module / 'StreamProtocol.o')]
            run(base + emit + protocol + output)
            run(base + ['-I', str(module), '-typecheck', str(root / 'Sources/SillHost/SentryAdmission.swift')])
            if sdk_name == 'macosx':
                run(base + ['-I', str(module), str(root / 'Sources/SillHost/SentryAdmission.swift'),
                    str(Path(__file__).with_name('Main.swift')), str(module / 'StreamProtocol.o'), '-o', str(out / 'checks')])
                run([str(out / 'checks'), str(archive)])
        record['exitCode'] = 0
    record['temporaryFilesRemoved'] = not out.exists()
except Exception as error:
    record.update(error=str(error), exitCode=2)
record['sourceUnchanged'] = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == sha for name, sha in hashes.items())
record['passedAssertions'] = sum(line.startswith('PASS ') for line in log_path.read_text(errors='replace').splitlines())
receipt.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in record.items() if k not in ['sourceSHA256', 'commands']}, ensure_ascii=False))
print(str(receipt))
sys.exit(record['exitCode'] if record['sourceUnchanged'] else 2)
