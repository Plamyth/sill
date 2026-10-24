import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
archive = Path(sys.argv[1]).resolve()
record = {'scope': '기존 Sentry/curtain lifecycle/cursor의 production 본문, 주입된 OS 경계만 실행',
          'physicalAcceptance': False, 'externalEffects': 0, 'commands': []}
log_path, receipt = archive / 'legacy.log', archive / 'legacy.json'
if log_path.exists() or receipt.exists():
    raise SystemExit('기존 영수증 보존 필요')
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
try:
    with tempfile.TemporaryDirectory(prefix='sentry-v2-legacy-') as scratch, log_path.open('wb') as log:
        out = Path(scratch)
        def run(args):
            result = subprocess.run(args, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            log.flush()
            record['commands'].append({'args': args, 'exitCode': result.returncode})
            if result.returncode:
                raise RuntimeError('검사 실패')
        run([sys.executable, '-B', str(root / 'Tests/checks/sentry/emit-curtains.py'), '--output', str(out / 'fixture')])
        record['extraction'] = json.loads((out / 'fixture/manifest.json').read_text())
        compiler = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
        sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
        base = [compiler, '-swift-version', '5', '-parse-as-library', '-whole-module-optimization', '-package-name', 'sill',
                '-sdk', sdk, '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(out / 'cache')]
        protocol = sorted(map(str, (root / 'Sources/StreamProtocol').glob('*.swift')))
        run(base + ['-emit-module', '-emit-object', '-module-name', 'StreamProtocol'] + protocol +
            ['-emit-module-path', str(out / 'StreamProtocol.swiftmodule'), '-o', str(out / 'StreamProtocol.o')])
        run(base + ['-I', str(out), str(root / 'Sources/SillHost/SentryAdmission.swift'), str(root / 'Sources/SillHost/HostSentry.swift'),
            str(out / 'fixture/Main.swift'), str(out / 'fixture/CurtainChecks.swift'), str(out / 'fixture/CursorChecks.swift'),
            str(out / 'StreamProtocol.o'), '-o', str(out / 'checks')])
        for args in [[], ['--curtains'], ['--refresh'], ['--cursor']]:
            run([str(out / 'checks')] + args)
        record['exitCode'] = 0
    record['temporaryFilesRemoved'] = not out.exists()
except Exception as error:
    record.update(error=str(error), exitCode=2)
record['passedAssertions'] = sum(line.startswith('PASS ') for line in log_path.read_text(errors='replace').splitlines())
receipt.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in record.items() if k not in ['commands', 'extraction']}, ensure_ascii=False))
sys.exit(record['exitCode'])
