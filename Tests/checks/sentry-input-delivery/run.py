import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--label', required=True)
args = parser.parse_args()
archive = args.archive.resolve()
archive.mkdir(parents=True, exist_ok=True)
receipt = archive / (args.label + '.json')
log = archive / (args.label + '.log')
if receipt.exists() or log.exists():
    raise SystemExit('기존 시도 영수증을 보존하고 먼저 대조하세요.')


def block(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


paths = ['Sources/SillHost/HostSentryPlatform.swift', 'Sources/SillHost/InputInjector.swift',
         'Tests/checks/sentry-input-delivery/Main.swift', 'Tests/checks/sentry-input-delivery/run.py']
hashes = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in paths}
platform, injector, template = [(ROOT / p).read_text() for p in paths[:3]]
markers = ['private struct Curtain {', 'private var isProtected:', 'private func makeCurtain(',
           'private func updateCurtainText()', 'private func invalidate(', 'private func filter(']
bodies = {m: block(platform, m) for m in markers}
level = next(line.strip() for line in platform.splitlines() if 'private static let curtainLevel =' in line)
post = block(injector, 'private func post(_ event: CGEvent)')
assert post.count('event.post(tap: .cghidEventTap)') == 1
inert_post = post.replace('event.post(tap: .cghidEventTap)', 'posted.append(event.copy()!)')
program = template.replace('__PRODUCTION_PLATFORM__', level + '\n' + '\n'.join(bodies.values()))
program = program.replace('__PRODUCTION_POST__', inert_post + '\n' + block(injector, 'private static func isKeyboard('))
record = {'scope': 'SDK 비표시 NSPanel과 실제 소스 추출 검사. CGEvent.post는 메모리 배열로 치환. tap·환경·버튼 관측은 주입.',
          'sourceHEAD': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
          'sourceSHA256': hashes,
          'bodySHA256': {m: hashlib.sha256(b.encode()).hexdigest() for m, b in bodies.items()},
          'postBodySHA256': hashlib.sha256(post.encode()).hexdigest(),
          'programSHA256': hashlib.sha256(program.encode()).hexdigest(), 'commands': []}
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
try:
    with tempfile.TemporaryDirectory(prefix='sdk-input-', dir=archive) as tmp, log.open('w') as output:
        out = Path(tmp)
        source = out / 'Main.swift'
        source.write_text(program)
        compiler = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
        sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
        base = [compiler, '-swift-version', '5', '-parse-as-library', '-sdk', sdk,
                '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(out / 'cache')]
        stub = out / 'Coordinator.swift'
        stub.write_text('import CoreGraphics\nenum StreamCoordinator { static func isSillVirtualDisplay(_ id: CGDirectDisplayID) -> Bool { false } }\n')
        commands = [base + ['-typecheck', str(ROOT / paths[0]), str(stub)],
                    base + [str(source), '-o', str(out / 'checks')], [str(out / 'checks')]]
        for command in commands:
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
print(json.dumps({k: record.get(k) for k in ['exitCode', 'passedAssertions', 'failedAssertions', 'sourceUnchanged', 'temporaryFilesRemoved', 'error']}, ensure_ascii=False))
print('RECEIPT ' + str(receipt))
raise SystemExit(record['exitCode'] if record['sourceUnchanged'] else 2)
