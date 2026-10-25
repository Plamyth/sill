"""생산 호출부·UI·이식 원형을 검사하며 실제 실행 수용과 구별한다."""
import hashlib
import json
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'Tests/checks/vision-autoconnect'))
from run import block
receipt = json.loads((Path(__file__).parent / 'upstream.json').read_text())
checks = 0
def check(value, label):
    global checks
    assert value, label
    checks += 1
for name, digest in receipt['coreSHA256'].items():
    check(hashlib.sha256((ROOT / 'iOSClient' / name).read_bytes()).hexdigest() == digest, name)
for name, digest in receipt['unchangedBootstrapSHA256'].items():
    check(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest, name)
for name in ['SillVisionApp.swift', 'ControlEventsPanel.swift', 'VisionControlEnrollment.swift']:
    source = (ROOT / 'visionOSClient' / name).read_text()
    for forbidden in ['pairTyped(', 'pairHome(', 'TextField(', 'SecureField(', '12자리', '24자리', '/v1/enroll', 'SecItem']:
        check(forbidden not in source, f'{name} 수동 경로 제거 {forbidden}')
store = (ROOT / 'iOSClient/IPadEnrollmentStore.swift').read_text()
transport = (ROOT / 'iOSClient/IPadEnrollmentTransport.swift').read_text()
check('#if os(iOS) || os(visionOS)' in store and '#if os(iOS) || os(visionOS)' in transport, '플랫폼 확장')
check('dev.ambrion.SillVision.owner-enrollment.v1' in store, 'Vision 전용 namespace')
check('control-events.enrollment.v1' not in store, 'legacy namespace 보존')
stream = (ROOT / 'iOSClient/StreamClient.swift').read_text()
remote = (ROOT / 'iOSClient/StreamClient+Remote.swift').read_text()
for text, markers, hook in [(stream, ['func markConnected(', 'private func cameForward(', 'var visionStartupForeground = false'], 'resumeOwnerEnrollment()'),
    (stream, ['func disconnect()', 'func retireVisionWindow()', 'private func wentToBackground(', 'var connection: NWConnection?'], 'cancelOwnerEnrollment()'),
    (remote, ['func remoteSessionReady()'], 'resumeOwnerEnrollment()')]:
    for marker in markers:
        check(hook in block(text, marker), '실제 lifecycle 호출부 ' + marker)
for text, marker in [(stream, 'func markConnected('), (remote, 'func remoteSessionReady()')]:
    method = block(text, marker)
    check(method.index('connected = true') < method.index('resumeOwnerEnrollment()'), 'TLS 연결 준비 이후 등록')
check('ownerEnrollmentTrustChanged()' in block(stream, '@Published var savedMacs:'), '실제 신뢰 변경 호출부')
selection = (ROOT / 'visionOSClient/StreamClient+VisionDisplaySelection.swift').read_text()
check('cancelOwnerEnrollment()' in block(selection, 'func admitVisionDisplays('), '창 lease 반납 호출부')
session = (ROOT / 'visionOSClient/VisionAppSession.swift').read_text()
check('controlEnrollment.restore()' not in session and 'client: client' in session, '수동 토큰 복원 대신 실제 client 바인딩')
print(f'PASS {checks} Vision 생산 배선·수동 UI 제거·원형 보존 정적 검사. 렌더·기기 수용 아님.')
