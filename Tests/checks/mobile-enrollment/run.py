"""Compile production protocol and signer with the production in-memory identity prefix."""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile
import json
import hashlib
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--sdk-check', action='store_true')
parser.add_argument('--sdk-only', action='store_true')
parser.add_argument('--node', default=shutil.which('node'))
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parents[3]

def sdk_checks(swift, protocol):
    sdk_results = []
    for sdk, target in [('macosx', 'arm64-apple-macosx14.0'), ('iphoneos', 'arm64-apple-ios17.0'),
                        ('xros', 'arm64-apple-xros2.5')]:
        sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
        subprocess.run(swift + ['-typecheck', '-sdk', sdk_path, '-target', target,
            '-module-name', 'StreamProtocol', *map(str, protocol)], check=True)
        sdk_results.append({'sdk': sdk, 'path': sdk_path, 'target': target, 'status': 'passed',
                            'scope': 'all production StreamProtocol sources'})
    (args.output / 'sdk.json').write_text(json.dumps(sdk_results, indent=2))

with tempfile.TemporaryDirectory(prefix='mobile-enrollment-') as temporary:
    build = Path(temporary)
    swift = ['xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'Sill',
             '-module-cache-path', str(build / 'cache')]
    protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
    inputs = protocol + [root / 'Sources/SillHost/HostIdentity.swift', root / 'Sources/SillHost/MobileEnrollmentSigner.swift']
    inputs += sorted((root / 'Tests/checks/mobile-enrollment').glob('*'))
    before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs if p.is_file()}
    if args.sdk_only:
        sdk_checks(swift, protocol)
        raise SystemExit(0)
    subprocess.run(swift + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-o', str(build / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(build / 'StreamProtocol.swiftmodule')], check=True)
    identity = (root / 'Sources/SillHost/HostIdentity.swift').read_text()
    (build / 'HostIdentity.swift').write_text(identity[:identity.index("/// Where the Mac's")])
    subprocess.run(swift + ['-parse-as-library', '-I', str(build), '-L', str(build), '-lStreamProtocol',
        str(build / 'HostIdentity.swift'), str(root / 'Sources/SillHost/MobileEnrollmentSigner.swift'),
        str(root / 'Tests/checks/mobile-enrollment/Main.swift'), '-o', str(build / 'checks')], check=True)
    subprocess.run([str(build / 'checks'), str(args.output), str(root / 'Tests/checks/mobile-enrollment')],
        env={**os.environ, 'DYLD_LIBRARY_PATH': str(build)}, check=True)
    golden = json.loads((args.output / 'golden.json').read_text())
    challenge = golden['activeChallenge']
    array = [1, challenge['coreGeneration'], challenge['requestId'], challenge['nonce'],
             challenge['deviceFingerprint'], challenge['ownerPrincipal'], challenge['origin'], challenge['deadline']]
    python_bytes = json.dumps(array, separators=(',', ':'), ensure_ascii=True).encode()
    assert python_bytes == (args.output / 'active-request.raw.json').read_bytes()
    assert hashlib.sha256(python_bytes).hexdigest() == challenge['requestDigest']
    node = args.node
    if node is None:
        raise RuntimeError('JSON.stringify 교차 검증에 필요한 기존 Node 실행파일 없음')
    subprocess.run([node, '-e', """
const fs = require('fs'), crypto = require('crypto');
const g = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
const c = g.activeChallenge;
const raw = JSON.stringify([1,c.coreGeneration,c.requestId,c.nonce,c.deviceFingerprint,c.ownerPrincipal,c.origin,c.deadline]);
if (raw !== g.activeDigestInput || crypto.createHash('sha256').update(raw,'utf8').digest('hex') !== c.requestDigest)
  throw new Error('Swift와 JSON.stringify requestDigest 불일치');
console.log('Node JSON.stringify와 Swift compact 배열의 원문·SHA256 일치');
""", str(args.output / 'golden.json')], check=True)
    if args.sdk_check:
        sdk_checks(swift, protocol)
    after = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs if p.is_file()}
    assert before == after, '검사 도중 소스 변경'
    (args.output / 'tested-source-hashes.json').write_text(json.dumps({
        'before': before, 'after': after, 'unchanged': True,
        'compiler': subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True).strip(),
        'hostScope': 'production HostIdentity prefix through signRecord/verifyRecord; production MobileEnrollmentSigner',
        'runtimeAccepted': False
    }, indent=2))
