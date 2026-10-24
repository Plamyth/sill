"""실제 소비자와 reader를 실행한다. 전송·TLS·기기 identity는 메모리 stand-in이다."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
OUT = ROOT / '.build/checks/ipad-sentry-observation'
OUT.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(ROOT / 'Tests/checks'))
from swift_platform import select_platform


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    for end in range(opening + 1, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(marker)


checks = []


def source_manifest():
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard'], cwd=ROOT, text=True).splitlines()
    paths = sorted(p for p in paths if p == 'Package.swift' or (p.startswith(('iOSClient/', 'visionOSClient/', 'Sources/StreamProtocol/')) and Path(p).suffix in {'.swift', '.pbxproj', '.plist', '.xcconfig'}) or p.startswith(('Tests/checks/ipad-sentry-observation/', 'Tests/checks/sentry-control-v2/')) and Path(p).suffix in {'.swift', '.py', '.json', '.md'})
    return {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in paths}


before = source_manifest()


def check(label, condition):
    assert condition, label
    checks.append(label)
    print('PASS ' + label, flush=True)


stream = (ROOT / 'iOSClient/StreamClient.swift').read_text()
ui = (ROOT / 'iOSClient/HostSettingsPanel.swift').read_text()
extension = (ROOT / 'iOSClient/StreamClient+Sentry.swift').read_text()
ios = select_platform(stream, vision=False, ios=True)
vision = select_platform(stream, vision=True)
base = subprocess.check_output(['git', 'show', '3beab7f8abd337c082617a31e53224759e35719f:iOSClient/StreamClient.swift'], cwd=ROOT, text=True)
base_vision = select_platform(base, vision=True)
connection = block(ios, 'var connection: NWConnection?')
check('connection setter에서 즉시 관찰·제어 무효화', connection.index('sentryObservation.bind(') < connection.index('replacePresentationConnection(') and 'sentryControl.bind(' in connection)
catalog = ios[ios.index('case .windowList:', ios.index('private func handle(')):]
main = catalog[catalog.index('DispatchQueue.main.async {'):]
observe_sentry = block(extension, 'func observeIPadSentry(')
check('현재 peer 검사 뒤 main에서 raw catalog 관찰', 'dispatchPrecondition(condition: .onQueue(.main))' in observe_sentry and observe_sentry.index('guard connection === peer') < observe_sentry.index('sentryObservation.observe(catalog: catalog, from: ObjectIdentifier(peer))') and main.index('guard self.connection === from') < main.index('self.observeIPadSentry(catalog: data, from: peer)'))
prefix = catalog[:catalog.index('                // A remote session,')]
check('audio fixture catalog prefix에 Sentry 의존성 추가 0', 'sentry' not in prefix.lower())
check('세션 admission 뒤 실제 권한·제어 관찰', main.index('self.homeSessionReady()') < main.index('self.observeIPadSentry(catalog: data, from: peer)'))
check('기존 measurement tick으로 timeout 검사', 'sentryControl.checkTimeout(now: ProcessInfo.processInfo.systemUptime)' in block(ios, 'private func closeWindow('))
for marker in ['private func replacePresentationConnection(', 'private func observeVisionInputCatalog(', 'private func applyVisionInputCatalog(', 'func captureInputSender()', 'private func sendInput(_ event: InputEvent, binding:', 'private func sendPresentedInput(']:
    check(marker + ' 원 input epoch/fence 코드 불변', block(ios, marker) == block(select_platform(base, vision=False, ios=True), marker))
check('Vision에 iPad Sentry published·함수·UI 없음', 'sentryControl' not in vision and 'sentryObservation' not in vision and 'sentryReport' not in select_platform(ui, vision=True))
for marker in ['var connection: NWConnection?', 'private func handle(', 'private func closeWindow(']:
    check(marker + ' Vision 실행 코드 불변', block(vision, marker) == block(base_vision, marker))
check('native kind214 switch 수신 wiring', 'case .sentryState:\n            receiveIPadSentry(data, from: peer)' in block(ios, 'private func handle('))
check('MessageReader 원본 불변', (ROOT / 'iOSClient/MessageReader.swift').read_text() == subprocess.check_output(['git', 'show', '3beab7f8abd337c082617a31e53224759e35719f:iOSClient/MessageReader.swift'], cwd=ROOT, text=True))
view = block(ui, 'private var sentryReport:')
check('명시 on/off·수동 조회 버튼의 정확한 desired', all(s in view for s in ['Button { client.setIPadSentry(desired: true) }', 'Button { client.setIPadSentry(desired: false) }', 'Button { client.queryIPadSentry() }']) and view.count('.frame(minHeight: 44)') == 3)
check('Sentry UI 자동 송신 경로 없음', all(s not in view for s in ['.onChange', '.onAppear', '.task(', 'Toggle(']))
check('상태·설명 접근성 및 버튼 그룹 보존', '.accessibilityElement(children: .contain)' in view and '.accessibilityHint(' in view and 'Text("센트리")' in view and 'client.sentryControl.canSet' in view)
check('Sentry trust는 자체 device identity·pinned TLS·saved Mac만 사용', all(s in extension for s in ['DeviceIdentity.existing()', 'RemoteTLS.peerFingerprint(peer) == pin', 'RemoteTLS.negotiatedALPN(peer) == RemoteTLS.sessionALPN', 'saved.revoked != true', 'saved.newKey != true']) and all(s not in extension for s in ['audioForwarding', 'allowsActions', 'loadOrCreate', 'SecItem', 'URLSession']))
check('새 timer 없음', all(s not in extension + (ROOT / 'iOSClient/IPadSentryControl.swift').read_text() for s in ['makeTimer', 'asyncAfter', 'Timer(', 'Task.sleep']))
project = (ROOT / 'iOSClient/Sill.xcodeproj/project.pbxproj').read_text()
for name in ['IPadSentryObservation.swift', 'IPadSentryControl.swift', 'StreamClient+Sentry.swift']:
    check(name + ' iPad·iPhone build 참조', project.count('/* ' + name + ' in Sources */ =') == 2 and project.count('path = "' + name + '";') + project.count('path = ' + name + ';') == 1)
base_commit = '3beab7f8abd337c082617a31e53224759e35719f'
host_commit = 'e17ec2abec7d9ea47b6262531674fc17fe22c6af'
host_tree = '667e2199977d0cc8ac600e79682095613284b9a2'
handoff = json.loads(Path('/Volumes/BT-Workspace/Development-Archives/CCR-Vision/sentry-control-v2-contract-20261025/handoff.json').read_text())
common = {'Sources/StreamProtocol/Sentry.swift', 'Sources/StreamProtocol/SentryControl.swift',
          'Tests/checks/sentry-control-v2/fixtures.json', 'Tests/checks/sentry-control-v2/request.schema.json',
          'Tests/checks/sentry-control-v2/response.schema.json'}
check('작업 기준 commit 계보 유지', subprocess.run(['git', 'merge-base', '--is-ancestor', base_commit, 'HEAD'], cwd=ROOT).returncode == 0)
check('Host handoff commit/tree exact', handoff['commit'] == host_commit and handoff['tree'] == host_tree and subprocess.check_output(['git', 'rev-parse', host_commit + '^{tree}'], cwd=ROOT, text=True).strip() == host_tree)
for path in sorted(common):
    data = (ROOT / path).read_bytes()
    check('공통 5파일 exact blob·handoff SHA ' + path, data == subprocess.check_output(['git', 'show', host_commit + ':' + path], cwd=ROOT) and hashlib.sha256(data).hexdigest() == handoff['fileSHA256'][path])
host_fixture = json.loads((ROOT / 'Tests/checks/sentry-control-v2/fixtures.json').read_text())
for name in ['On', 'Off']:
    check('Host 원 request raw SHA256 ' + name, hashlib.sha256(host_fixture['request' + name + 'Raw'].encode()).hexdigest() == host_fixture['request' + name + 'SHA256'])
allowed = {'iOSClient/IPadSentryObservation.swift', 'iOSClient/IPadSentryControl.swift',
           'iOSClient/StreamClient+Sentry.swift', 'iOSClient/HostSettingsPanel.swift'} | common
# 세 source-request 검사 파일은 부모의 별도 워크트리 통합 범위다.
parent_scope = {'Tests/checks/source-request/run.py', 'Tests/checks/source-request/transport.py', 'Tests/checks/source-request/Client.swift'}
feature_commit = '5f10b3f823624b708a01a617ee3283146a76465c'
check('검수된 Sentry 기능 commit 계보 유지', subprocess.run(['git', 'merge-base', '--is-ancestor', feature_commit, 'HEAD'], cwd=ROOT).returncode == 0)
changed = subprocess.check_output(['git', 'diff', '--name-only', base_commit, feature_commit], cwd=ROOT, text=True).splitlines()
untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard'], cwd=ROOT, text=True).splitlines()
check('기록된 Sentry 기능 commit의 변경 범위 유지', all(p in allowed or p in parent_scope or p.startswith('Tests/checks/ipad-sentry-observation/') for p in changed))
check('Sentry 검사 입력의 미추적 파일 없음', not any(p in allowed or p.startswith('Tests/checks/ipad-sentry-observation/') for p in untracked))
wire = (ROOT / 'Sources/StreamProtocol/StreamMessage.swift').read_bytes()
wire_base = subprocess.check_output(['git', 'show', base_commit + ':Sources/StreamProtocol/StreamMessage.swift'], cwd=ROOT)
check('StreamMessage kind·방향별 cap은 기준3beab 원본 불변', wire == wire_base)
host = subprocess.check_output(['git', 'show', host_commit + ':Sources/StreamProtocol/StreamMessage.swift'], cwd=ROOT, text=True)
check('포트 구문이 Host e17 exact source에 존재', all(line in host for line in ['    case activateSentry = 213', '    case sentryState = 214', '        case .activateSentry: return 512', '        case .sentryState: return -1', '        case .microphoneState, .microphoneReceipt, .sentryState: return 4096', '        case .activateSentry: return -1']))
check('명시 두 버튼 desired별 disabled', '.disabled(!client.sentryControl.canSet(desired: true))' in view and '.disabled(!client.sentryControl.canSet(desired: false))' in view)
control_source = (ROOT / 'iOSClient/IPadSentryControl.swift').read_text()
check('공유 DTO 파서 사용과 private DTO 제거', all('private struct ' + name not in control_source for name in ['Request', 'Reply', 'Control', 'Report']) and 'SentryControlResponse.decodePayload(data)' in control_source and 'SentryControlRequest(rawRequest: raw)' in control_source)

fixture = select_platform(extension, vision=False, ios=True).replace('import Network\n', '')
(OUT / 'Wiring.swift').write_text(fixture)
standins = (HERE / 'Standins.swift').read_text().replace('// ACCEPT_REPLY', block(ios, 'func acceptIPadSentryReply('))
(OUT / 'Standins.swift').write_text(standins)
(OUT / 'Reader.swift').write_text((ROOT / 'iOSClient/MessageReader.swift').read_text().replace('import Network\n', ''))


def run(args):
    result = subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    with (OUT / 'checks.log').open('a') as log:
        log.write(result.stdout)
    print(result.stdout, end='', flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)


(OUT / 'checks.log').write_text('')
flags = ['-swift-version', '5', '-module-cache-path', str(OUT / 'cache')]
protocol = sorted(map(str, (ROOT / 'Sources/StreamProtocol').glob('*.swift')))
run(['/usr/bin/swiftc', *flags, '-emit-library', '-emit-module', '-module-name', 'StreamProtocol', *protocol,
     '-emit-module-path', str(OUT / 'StreamProtocol.swiftmodule'), '-o', str(OUT / 'libStreamProtocol.dylib')])
run(['/usr/bin/swiftc', *flags, '-I', str(OUT), '-L', str(OUT), '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(OUT),
     str(ROOT / 'iOSClient/IPadSentryObservation.swift'), str(ROOT / 'iOSClient/IPadSentryControl.swift'),
     str(OUT / 'Standins.swift'), str(OUT / 'Wiring.swift'), str(OUT / 'Reader.swift'), str(HERE / 'main.swift'), '-o', str(OUT / 'check')])
run([str(OUT / 'check'), str(ROOT / 'Tests/checks/sentry-control-v2/fixtures.json')])
run(['git', 'diff', '--check'])
check('검사 전후 앱·Protocol 소스 동일', source_manifest() == before)
source_sha = hashlib.sha256(json.dumps(before, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
result = dict(status='passed', staticChecks=checks, sdkBuild='pending-parent', independentReview='pending-parent',
              fixtureOrigin='authoritative-Host-e17-exact-raw-and-memory-derived-cases', authoritativeHostCommit=host_commit, authoritativeHostTree=host_tree, commonFileSHA256={p: handoff['fileSHA256'][p] for p in sorted(common)}, externalEffects=0,
              sourceCodeSha256=source_sha, sourceFiles=before)
(OUT / 'checks.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print('실제 소비자·reader 회귀 및 정적 wiring 검사 통과. Host exact DTO·fixture 소스 수용까지 통과했습니다. SDK·설치·실기기·런타임 수용은 별도입니다.')
