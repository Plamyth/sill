"""통과한 검사 입력과 현재 소스가 같을 때만 부모 SDK용 동결 영수증을 쓴다."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / '.build/checks/ipad-sentry-observation'
result = json.loads((OUT / 'checks.json').read_text())
assert result['status'] == 'passed'
manifest = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in result['sourceFiles']}
assert manifest == result['sourceFiles'], '검사 뒤 소스가 바뀌었습니다. 다시 검사해야 합니다.'
source_sha = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
assert source_sha == result['sourceCodeSha256']
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
assert head == 'e88f8dc0e48bb9a75ebdadb9d66f68fef547fd36'
tracked = subprocess.check_output(['git', 'diff', '--binary'], cwd=ROOT)
untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard'], cwd=ROOT, text=True).splitlines()
for path in untracked:
    part = subprocess.run(['git', 'diff', '--no-index', '--binary', '--', '/dev/null', path], cwd=ROOT, stdout=subprocess.PIPE, check=False)
    assert part.returncode == 1, path
    tracked += part.stdout
(OUT / 'implementation.diff').write_bytes(tracked)
(OUT / 'source-sha256.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
log = (OUT / 'checks.log').read_text()
runtime = [line for line in log.splitlines() if line.startswith('소비자 회귀 ')][-1]
marker = dict(status='sdk-ready-source-frozen', worktree=str(ROOT), branch='codex/ipad-sentry-control-20261025',
              baseCommit=head, sourceCodeSha256=source_sha, sourceFiles=manifest,
              diffSha256=hashlib.sha256(tracked).hexdigest(), runtimeResult=runtime,
              staticCheckCount=len(result['staticChecks']), sdkBuild='pending-parent', independentReview='pending-parent',
              authoritativeHostDTO='pending-source-and-fixture',
              nativeCodexCall='unsupported-no-native-producer',
              deviceNetworkKeychainHostActions=0, committed=False)
(OUT / 'sdk-ready.json').write_text(json.dumps(marker, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in marker.items() if k != 'sourceFiles'}, ensure_ascii=False, indent=2))
