"""Production wire/authority checks. The worker runs only in a removed Mini execution copy."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--worker', action='store_true')
parser.add_argument('--evidence', type=Path)
parser.add_argument('--label', default='green')
args = parser.parse_args()

if args.worker:
    with tempfile.TemporaryDirectory(prefix='sentry-return-check-') as temporary:
        out = Path(temporary)
        compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
        common = [compiler, '-swift-version', '5', '-parse-as-library', '-package-name', 'sill',
                  '-module-cache-path', str(out / 'cache')]
        protocol = sorted(map(str, (root / 'Sources/StreamProtocol').glob('*.swift')))
        subprocess.run(common + ['-whole-module-optimization', '-emit-module', '-emit-object',
            '-module-name', 'StreamProtocol', *protocol, '-emit-module-path', str(out / 'StreamProtocol.swiftmodule'),
            '-o', str(out / 'StreamProtocol.o')], check=True)
        authority = root / 'Sources/SillHost/SentryReturnAuthority.swift'
        sources = [str(authority)] if authority.exists() else []
        subprocess.run(common + ['-I', str(out), *sources, str(here / 'Main.swift'),
            str(out / 'StreamProtocol.o'), '-o', str(out / 'checks')], check=True)
        subprocess.run([str(out / 'checks'), str(here)], check=True)
    print('임시 compiler 산출물 해제 완료')
else:
    if args.evidence is None:
        parser.error('--evidence requires a storage-route development-archive path')
    args.evidence.mkdir(parents=True, exist_ok=True)
    log = args.evidence / (args.label + '.log')
    receipt = args.evidence / (args.label + '.json')
    if log.exists() or receipt.exists():
        raise SystemExit('기존 증거를 덮어쓰지 않습니다. 새 검사 label을 사용하세요.')
    inputs = sorted((root / 'Sources/StreamProtocol').glob('*.swift')) + list(here.glob('*'))
    authority = root / 'Sources/SillHost/SentryReturnAuthority.swift'
    if authority.exists():
        inputs.append(authority)
    hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in inputs if p.is_file()}
    command = ['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(root),
        '--owner', os.environ['CODEX_THREAD_ID'], '--job', 'sentry-return-contract', '--',
        'python3', 'Tests/checks/sentry-return/run.py', '--worker']
    with log.open('wb') as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
    text = log.read_text(errors='replace')
    cleanup = any('"cleanup_verified": true' in line for line in text.splitlines())
    unchanged = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == sha for name, sha in hashes.items())
    record = dict(exitCode=result.returncode, cleanupVerified=cleanup, sourceUnchanged=unchanged,
        sourceSHA256=hashes, assertions=sum(line.startswith('PASS ') for line in text.splitlines()),
        runtimeAcceptance=False, externalEffects=0)
    receipt.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
    print(text[-14000:])
    print(json.dumps({k:v for k,v in record.items() if k != 'sourceSHA256'}, ensure_ascii=False))
    sys.exit(result.returncode if cleanup and unchanged else 2)
