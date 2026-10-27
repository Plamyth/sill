"""실제 연결 메서드를 가상 시계·무네트워크 객체로 실행할 입력을 만든다."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'Tests/checks/reconnect-glue'))
from extract import block
sys.path.insert(0, str(ROOT / 'Tests/checks'))
from swift_platform import select_platform

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
stream = (ROOT / 'iOSClient/StreamClient.swift').read_text()
remote = (ROOT / 'iOSClient/StreamClient+Remote.swift').read_text()
state = (Path(__file__).parent / 'Standins.swift').read_text()
pieces = [block(stream, 'struct Reconnect {')]
for marker in ['func cancelRemoteDial()', 'func remoteDialFailed(', 'func sessionEnded(',
               'private func endWithNotice(', 'private func lostReconnect(',
               '@discardableResult\n    func reconnectIfListed()', 'private func reconnectOwnerIfDue(']:
    if marker in remote:
        pieces.append(block(remote, marker))
for marker in ['private func cameForward()', 'private func wentToBackground()', 'func disconnect()']:
    pieces.append(block(stream, marker))
body = select_platform('\n'.join(pieces), vision=False, ios=False)
failure_call = 'remoteDialFailed(macID: targetID, why: .automatic, failure: failure, candidate: candidate'
if 'retry: RemoteDialPolicy.RetryDisposition' in remote:
    failure_call += ', retry: RemoteDialPolicy.retryDisposition(for: ends)'
body += '\nfunc fail(_ ends: [RemoteDialPolicy.End]) {\nremoteDial = nil\nlet failure = RemoteDialPolicy.worst(ends.compactMap { RemoteDialPolicy.classify($0, candidate: candidate, usedTunnel: true) }) ?? .noAnswer\n' + failure_call + ')\n}\n'
body += '\nfunc seed() { reconnect = lostReconnect(session: nil, saved: saved, name: "Mac", remoteAllowed: true) }\nfunc foreground() { cameForward() }\nfunc background() { wentToBackground() }\n'
main = state + '\n' + body + '\n}\n' + (Path(__file__).parent / 'scenarios.swift').read_text()
files = {'main.swift': main, 'RemoteCopy.swift': 'import Foundation\nimport StreamProtocol\n' + block(remote, 'enum RemoteCopy {')}
for name in ['DiscoveryPolicy', 'RemoteDialPolicy', 'SavedMacs', 'GoodbyePolicy']:
    files[name + '.swift'] = (ROOT / ('iOSClient/' + name + '.swift')).read_text()
for path in (ROOT / 'Sources/StreamProtocol').glob('*.swift'):
    files['wire/' + path.name] = path.read_text()
connector = (ROOT / 'iOSClient/RemoteConnector.swift').read_text().replace('import Network\n', '')
clock = state[:state.index('enum NWError:')]
files['connector/RemoteConnector.swift'] = connector
files['connector/main.swift'] = clock + (Path(__file__).parent / 'connector.swift').read_text()
for name in ['main.swift', 'home.swift']:
    files['legacy/' + name] = 'import StreamProtocol\n' + (ROOT / 'Tests/checks/remote-rules' / name).read_text()
files['run.py'] = """import pathlib,subprocess,sys
root=pathlib.Path(__file__).parent
wire=sorted(str(p) for p in (root/'wire').glob('*.swift'))
commands=[['swiftc','-module-cache-path','./cache','-parse-as-library','-whole-module-optimization','-emit-module','-emit-object','-module-name','StreamProtocol',*wire,'-emit-module-path','StreamProtocol.swiftmodule','-o','wire.o'], ['swiftc','-module-cache-path','./cache','-I','.',*sorted(str(p) for p in root.glob('*.swift')),'wire.o','-o','checks'], ['./checks']]
commands += [['swiftc','-module-cache-path','./cache','-I','.',*sorted(str(p) for p in (root/'connector').glob('*.swift')), 'RemoteDialPolicy.swift','SavedMacs.swift','wire.o','-o','connector-checks'], ['./connector-checks']]
commands += [['swiftc','-module-cache-path','./cache','-I','.',*sorted(str(p) for p in (root/'legacy').glob('*.swift')), 'RemoteDialPolicy.swift','SavedMacs.swift','DiscoveryPolicy.swift','wire.o','-o','legacy-checks'], ['./legacy-checks']]
for command in commands:
 result=subprocess.run(command)
 if result.returncode: sys.exit(result.returncode)
"""
for name, text in files.items():
    (out / name).parent.mkdir(parents=True, exist_ok=True)
    (out / name).write_text(text)
(out / 'input-hashes.json').write_text(json.dumps({n: hashlib.sha256(t.encode()).hexdigest() for n, t in files.items()}, indent=2) + '\n')
print(json.dumps({'input': str(out), 'files': len(files), 'productionMethodsSHA256': hashlib.sha256(body.encode()).hexdigest()}))
