"""실제 Core 소켓에 데이터 없이 연결해 audit-token peer 판정만 확인한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess

here = Path(__file__).resolve().parent
repo = here.parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--expected', choices=['refused', 'verified'], required=True)
parser.add_argument('--module-cache', type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
endpoint = Path.home() / 'Library/Application Support/CodexControlRoom/command.sock'

def snapshot():
    parent, item = endpoint.parent.lstat(), endpoint.lstat()
    assert stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.getuid()
    assert stat.S_IMODE(parent.st_mode) == 0o700
    assert stat.S_ISSOCK(item.st_mode) and item.st_uid == os.getuid()
    assert stat.S_IMODE(item.st_mode) == 0o600
    assert endpoint.resolve() == endpoint
    listing = subprocess.check_output(['/usr/sbin/lsof', '-nP', '-a', '-U', str(endpoint)], text=True)
    rows = [line.split() for line in listing.splitlines()[1:] if line.endswith(str(endpoint))]
    assert len(rows) == 1 and rows[0][2] == 'ambrion', listing
    pid = int(rows[0][1])
    executable = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
    assert executable == '/Applications/Obsidian.app/Contents/Frameworks/Obsidian Helper (Renderer).app/Contents/MacOS/Obsidian Helper (Renderer)'
    return {'directory': [parent.st_dev, parent.st_ino, stat.S_IMODE(parent.st_mode)],
            'socket': [item.st_dev, item.st_ino, stat.S_IMODE(item.st_mode)],
            'listenerPID': pid, 'listenerExecutable': executable}

binary = args.output / 'actual-core-probe'
subprocess.run(['/usr/bin/xcrun', 'swiftc', str(repo / 'Sources/ProviderPeerVerifier/PeerAnchor.swift'),
    str(here / 'ActualCore.swift'), '-module-cache-path', str(args.module_cache or args.output / 'cache'), '-o', str(binary)],
    check=True, timeout=120)
before = snapshot()
value = json.loads(subprocess.check_output([str(binary)], text=True, timeout=15))
assert snapshot() == before, '실제 endpoint 또는 listener가 변경됐다'
assert value['state'] == args.expected, value
if args.expected == 'refused':
    assert value['reason'] == 'signatureMismatch', value
else:
    assert value['predicate']['pid'] == before['listenerPID']
value.update(endpoint=before, peerAnchorSHA256=hashlib.sha256(
    (repo / 'Sources/ProviderPeerVerifier/PeerAnchor.swift').read_bytes()).hexdigest())
(args.output / 'result.json').write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(value, ensure_ascii=False), flush=True)
