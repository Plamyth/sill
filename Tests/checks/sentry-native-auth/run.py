import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--label', required=True)
parser.add_argument('--baseline', action='store_true')
args = parser.parse_args()
archive = args.archive.resolve()
archive.mkdir(parents=True, exist_ok=True)
receipt, log = [archive / (args.label + suffix) for suffix in ['.json', '.log']]
if receipt.exists() or log.exists():
    raise SystemExit('기존 검사 영수증을 보존하고 대조하세요.')


def block(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


paths = ['Sources/SillHost/HostSentryPlatform.swift', 'Sources/SillHost/StreamCoordinator.swift',
         'Tests/checks/sentry-native-auth/Main.swift', 'Tests/checks/sentry-native-auth/run.py']
hashes = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in paths}
current = (ROOT / paths[0]).read_text()
base = 'edc219582e153f142f832d35f968e69b2bbafd3c'
source = subprocess.check_output(['git', 'show', base + ':' + paths[0]], cwd=ROOT, text=True) if args.baseline else current
markers = ['private var isProtected:', 'private func invalidate(', 'private func filter(',
           'private func updateCurtainText()', 'var reason: String?']
bodies = {m: block(source, m) for m in markers}
program = (ROOT / paths[2]).read_text().replace('__PRODUCTION__', re.sub(r'\bCGEvent\b', 'Event', '\n'.join(bodies.values())))
record = {'scope': '실제 Platform 본문 추출과 가짜 창 목록·이벤트로 비허용 검사. OS 창 결박/키 중계/커튼 하향 구현 없음. 실제 prompt/post/Host/UI/HAL/journal 0.',
          'nativeUIAccepted': False, 'sourceHEAD': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
          'baseline': base if args.baseline else None, 'sourceSHA256': hashes, 'baselineMissingAPIs': [],
          'bodySHA256': {m: hashlib.sha256(b.encode()).hexdigest() for m, b in bodies.items()}, 'commands': []}
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
try:
    with tempfile.TemporaryDirectory(prefix='native-auth-', dir=archive) as tmp, log.open('w') as output:
        out = Path(tmp)
        sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
        compiler = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
        flags = [compiler, '-swift-version', '5', '-parse-as-library', '-sdk', sdk, '-target', 'arm64-apple-macosx14.0',
                 '-module-cache-path', str(out / 'cache')]
        original, fixture, stub = [out / name for name in ['Platform.swift', 'Main.swift', 'Coordinator.swift']]
        original.write_text(source)
        fixture.write_text(program)
        stub.write_text('import CoreGraphics\nenum StreamCoordinator { static func isSillVirtualDisplay(_ id: CGDirectDisplayID) -> Bool { false } }\n')
        for command in [flags + ['-typecheck', str(original), str(stub)],
                        flags + [str(fixture), '-o', str(out / 'checks')], [str(out / 'checks')]]:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=120)
            record['commands'].append({'command': command, 'exitCode': result.returncode})
            if result.returncode:
                break
        record['exitCode'] = result.returncode
    record['temporaryFilesRemoved'] = not out.exists()
except Exception as error:
    record.update(exitCode=2, error=str(error))
record['sourceUnchanged'] = all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h for p, h in hashes.items())
lines = log.read_text().splitlines() if log.exists() else []
record['passedAssertions'] = sum(line.startswith('PASS ') for line in lines)
record['failedAssertions'] = [line for line in lines if line.startswith('FAIL ')]
receipt.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: record.get(k) for k in ['exitCode', 'passedAssertions', 'failedAssertions', 'sourceUnchanged', 'temporaryFilesRemoved', 'nativeUIAccepted', 'error']}, ensure_ascii=False))
print('RECEIPT ' + str(receipt))
raise SystemExit(record['exitCode'] if record['sourceUnchanged'] else 2)
