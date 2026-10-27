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
pieces = [block(stream, marker) for marker in ['struct Reconnect {', 'private struct VisionStartupTarget {',
                                              'private enum StartupAutoConnection {']]
for marker in ['func cancelRemoteDial()', 'func remoteDialFailed(', 'func sessionEnded(',
               'private func endWithNotice(', 'private func lostReconnect(',
               '@discardableResult\n    func reconnectIfListed()',
               'func beginVisionSavedMacReconnect(']:
    if marker in remote:
        pieces.append(block(remote, marker))
for marker in ['private func cameForward()', 'private func wentToBackground(', 'func disconnect()',
               'func retireVisionWindow()', 'func stopSavedMacAutoConnect()',
               'private func tryVisionSavedMacAutoConnect(']:
    pieces.append(block(stream, marker))
winner = block(remote, 'private func remoteWinner(')
deadline = winner[winner.index('let deadline = DispatchWorkItem'):winner.rindex('\n    }')]
end_session = block(stream, 'private func endSession(')
pieces += ['func armProductionDeadline(_ c: NWConnection) {\n' + deadline + '\n}', end_session]
connection_lost = block(stream, 'func connectionLost(')
assert 'guard self.connection === c else { return }' in connection_lost
assert 'self.endSession(error: error, end: end)' in connection_lost
pieces.append('''func connectionLost(_ c: NWConnection, error: NWError? = nil, end: RemoteDialPolicy.End? = nil) {
    guard connection === c else { return }
    endSession(error: error, end: end)
}''')
selected = '\n'.join(pieces).replace('#if os(iOS) || os(visionOS)', '#if os(visionOS)')
selected = selected.replace('#if os(visionOS) && DEBUG && targetEnvironment(simulator)', '#if DEBUG && targetEnvironment(simulator)')
body = select_platform(selected, vision=True)
failure_call = 'remoteDialFailed(macID: targetID, why: .automatic, failure: failure, candidate: candidate'
if 'retry: RemoteDialPolicy.RetryDisposition' in remote:
    failure_call += ', retry: RemoteDialPolicy.retryDisposition(for: ends)'
body += '\nfunc fail(_ ends: [RemoteDialPolicy.End]) {\nremoteDial = nil\nlet failure = RemoteDialPolicy.worst(ends.compactMap { RemoteDialPolicy.classify($0, candidate: candidate, usedTunnel: true) }) ?? .noAnswer\n' + failure_call + ')\n}\n'
body += '\nfunc seed() { reconnect = lostReconnect(session: nil, saved: saved, name: "Mac", remoteAllowed: true) }\nfunc foreground() { cameForward() }\nfunc background() { wentToBackground() }\n'
body += '''
private var startupAutoConnection = StartupAutoConnection.stopped
private var startupRemoteCheck: DispatchWorkItem?
func armStartup() {
    startupAutoConnection = .waiting(VisionStartupTarget(macID: targetID, pin: saved.fingerprintData!,
        recognitionKey: saved.recognitionKeyData!, preferredID: nil, devicePin: DeviceIdentity.existing()!.fingerprint))
    tryVisionSavedMacAutoConnect()
}
func startupClosure() -> () -> Void { startupRemoteCheck!.body }
func startupStopped() -> Bool { if case .stopped = startupAutoConnection { return true }; return false }
'''
main = state + '\n' + body + '\n}\n' + (Path(__file__).parent / 'scenarios.swift').read_text()
files = {'main.swift': main, 'RemoteCopy.swift': 'import Foundation\nimport StreamProtocol\n' + block(remote, 'enum RemoteCopy {')}
for name in ['DiscoveryPolicy', 'RemoteDialPolicy', 'SavedMacs', 'GoodbyePolicy']:
    files[name + '.swift'] = (ROOT / ('iOSClient/' + name + '.swift')).read_text()
for path in (ROOT / 'Sources/StreamProtocol').glob('*.swift'):
    files['wire/' + path.name] = path.read_text()
connector = (ROOT / 'iOSClient/RemoteConnector.swift').read_text().replace('import Network\n', '')
clock = state[:state.index('enum NWError:')]
clock = clock.replace('    func async(execute: @escaping () -> Void) { execute() }\n', '')
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
(out / 'extraction.json').write_text(json.dumps({
    'platform': 'Vision 조건부 선택, macOS 실행용 가상 시계·네트워크·음성·창 객체',
    'sourceSHA256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in [ROOT / 'iOSClient/StreamClient.swift', ROOT / 'iOSClient/StreamClient+Remote.swift',
                               ROOT / 'iOSClient/RemoteConnector.swift', ROOT / 'iOSClient/RemoteDialPolicy.swift']},
    'deadlineSHA256': hashlib.sha256(deadline.encode()).hexdigest(),
    'endSessionSHA256': hashlib.sha256(end_session.encode()).hexdigest(),
    'connectionLostAdapter': '현재 peer 정체성 확인 후 실제 endSession 전달. 네트워크·rescue·media 정리는 제외.',
}, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'input': str(out), 'files': len(files), 'productionMethodsSHA256': hashlib.sha256(body.encode()).hexdigest()}))
