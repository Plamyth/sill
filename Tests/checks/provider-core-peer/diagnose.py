"""명령을 전송하지 않고 실제 Core peer 검증의 마지막 거절 조건을 구분한다."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
repo = here.parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--fixture', action='store_true')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
source = (repo / 'Sources/ProviderPeerVerifier/PeerAnchor.swift').read_text()
old = '''        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              size == MemoryLayout<pid_t>.size, pid > 0,
              try token(fd) == before,
              SecCodeCheckValidity(dynamic, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw Failure.peerChanged
        }'''
new = '''        let pidResult = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size)
        let pidErrno = errno
        var diagnostic: [String: Any] = ["stage": "peerPID", "pidResult": pidResult,
            "pidErrno": pidResult == 0 ? 0 : pidErrno, "pidSize": size, "pid": pid]
        defer {
            if let bytes = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
                FileHandle.standardError.write(bytes + Data([10]))
            }
        }
        guard pidResult == 0, size == MemoryLayout<pid_t>.size, pid > 0 else { throw Failure.peerChanged }
        diagnostic["stage"] = "peerToken"
        let tokenEqual = try token(fd) == before
        diagnostic["tokenEqual"] = tokenEqual
        guard tokenEqual else { throw Failure.peerChanged }
        diagnostic["stage"] = "dynamicCode"
        let finalStatus = SecCodeCheckValidity(dynamic, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
        diagnostic["finalStatus"] = finalStatus
        guard finalStatus == errSecSuccess else { throw Failure.peerChanged }'''
assert source.count(old) == 1
with tempfile.TemporaryDirectory(prefix='peerchanged-') as temporary:
    transformed = Path(temporary) / 'PeerAnchor.swift'
    instrumented = source.replace(old, new)
    if args.fixture:
        instrumented = instrumented.replace('import Security\n', '').replace('getsockopt(', 'fixtureGetSockOpt(')
    transformed.write_text(instrumented)
    binary = args.output / 'actual-core-diagnostic'
    env = {**os.environ, 'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'}
    inputs = [here / 'FixtureSecurity.swift', here / 'Checks.swift'] if args.fixture else [here / 'ActualCore.swift']
    subprocess.run(['/usr/bin/xcrun', 'swiftc', str(transformed), *map(str, inputs),
        '-module-cache-path', str(args.output / 'cache'), '-o', str(binary)],
        env=env, check=True, timeout=120)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
    observation = json.loads(result.stdout) if result.returncode == 0 and not args.fixture else None
    completed = result.returncode == 0 and (args.fixture or observation.get('state') in ['verified', 'refused'])
    verified = completed and not args.fixture and observation['state'] == 'verified'
    value = dict(exitCode=result.returncode, stdout=result.stdout, stderr=result.stderr,
        observationCompleted=completed, peerVerified=verified, fixture=args.fixture,
        productionSourceChanged=False, installedHostOrCoreChanged=False)
    (args.output / 'result.json').write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(value, ensure_ascii=False))
    raise SystemExit(0 if completed and (args.fixture or verified) else 2 if completed else 1)
