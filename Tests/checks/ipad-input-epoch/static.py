"""프로젝트 참조와 iOS/Vision의 실제 입력·미디어 연결을 검사한다."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'Tests/checks'))
from swift_platform import select_platform
spec = importlib.util.spec_from_file_location('extract', ROOT / 'Tests/checks/vision-input-controls/extract.py')
extract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extract)
block = extract.block
checks = {}


def check(name, passed):
    checks[name] = bool(passed)
    assert passed, name


stream = (ROOT / 'iOSClient/StreamClient.swift').read_text()
display = (ROOT / 'iOSClient/HEVCDisplayView.swift').read_text()
ipad = select_platform(stream, vision=False, ios=True)
vision = select_platform(stream, vision=True)
base = subprocess.check_output(['git', 'show', 'e564f03c6206f192c84a1a2703d17d43c4ec70a8:iOSClient/HEVCDisplayView.swift'], cwd=ROOT, text=True)
without_comments = lambda text: '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('//'))
check('Vision 표시 구현은 플랫폼 선택 후 기준과 동일', without_comments(select_platform(display, vision=True)) == without_comments(select_platform(base, vision=True)))
check('iOS는 검증된 Vision 표시 구현을 공유', select_platform(display, vision=False, ios=True) == select_platform(display, vision=True))
for source, label in [(ipad, 'iOS'), (vision, 'Vision')]:
    check(label + ' hello presentationInput 1', 'let presentationInput: Int? = 1' in block(source, 'private static let helloPayload:'))
    check(label + ' epoch 미디어 처리', 'case .epochParameterSets, .epochFrame:' in source and 'displayView.receiveFrame(payload.media' in source)
    check(label + ' 실제 표시 결과를 입력 permit에 연결', 'view.onPresentation =' in source and 'link.setInputPermit(ticket.id, epoch: ticket.epoch.id)' in source)
send = block(ipad, 'private func sendInput(_ event: InputEvent, binding:')
capture = block(ipad, 'func captureInputSender()')
check('iOS가 큐 진입 전 immutable binding·peer·permit 캡처', send.index('binding.capture(event)') < send.index('queue.async') and 'let expected = connection' in capture and 'let binding = visionInputBinding' in capture)
check('generation 단독 iOS 전송 제거', 'SourceInput.payload(event, generation: inputGeneration)' not in send)
check('기존 이동 타이밍 유지', 'private static let moveInterval = 0.008' in ipad and 'moveFlushScheduled' in send)
check('전경 이탈이 permit과 표시를 함께 폐쇄', 'UIApplication.willResignActiveNotification' in ipad and 'self?.displayView.setPresentationForeground(false)' in ipad)
connection = block(ipad, 'private func replacePresentationConnection(')
check('연결 fence는 즉시 처리하고 UIKit은 main으로 전달', connection.index('link.replaceConnection') < connection.index('let reset =') and 'if Thread.isMainThread' in connection and 'DispatchQueue.main.async(execute: reset)' in connection)
check('늦은 UIKit up을 실제 전송 시 debt로 검사', 'visionInputDebt.permits(input, on: peer)' in block(ipad, 'private func sendPresentedInput('))
overlay = (ROOT / 'iOSClient/InputOverlay.swift').read_text()
ios_overlay = select_platform(overlay, vision=False, ios=True)
vision_overlay = select_platform(overlay, vision=True)
check('iOS 물리 포인터는 첫 owner의 종료까지 단독 소유', 'guard pointerInputs.isEmpty else { return }' in block(ios_overlay, 'override func touchesBegan('))
check('iOS 혼합 touch 종료는 실제 owner만 선택', 'pointerInputs[ObjectIdentifier($0)] != nil' in block(ios_overlay, 'private func ownedPointerTouch(') and all('ownedPointerTouch(in: touches)' in block(ios_overlay, m) for m in ['override func touchesMoved(', 'override func touchesEnded(', 'override func touchesCancelled(']))
check('Vision 기존 물리 포인터 선택 정책 유지', 'return Self.pointerTouch(in: touches)' in block(vision_overlay, 'private func ownedPointerTouch(') and 'guard pointerInputs.isEmpty' not in block(vision_overlay, 'override func touchesBegan('))
check('Pencil 종료가 UITouch identity의 시작 sender 사용', 'pointerInputs.removeValue(forKey: ObjectIdentifier(touch))' in block(overlay, 'override func touchesEnded('))
check('hardware 종료가 UIPress identity와 현재 usage 소유권 분리', 'hardwareInputs.removeValue(forKey: id)' in block(overlay, 'private func forward(') and 'hardwareOwners[usage] == id' in overlay)
check('인식기 시작 sender가 종료까지 유지', 'recognizerInputs[id] = send' in block(overlay, 'private func sender(for gesture:'))
portrait = (ROOT / 'iOSClient/PortraitStreamScreen.swift').read_text()
trackpad = (ROOT / 'iOSClient/TrackpadView.swift').read_text()
check('trackpad가 재사용되는 UIView에도 capture factory 전달', 'captureInputSender: { client.captureInputSender() }' in portrait and 'uiView.captureInputSender = captureInputSender' in trackpad)
check('trackpad 관성이 시작 scroll sender 유지', 'let send = scrollSender' in block(trackpad, 'private func endScroll(') and 'self.send(' not in block(trackpad, 'private func endScroll('))
check('trackpad drag 종료가 인식기 소유권 대조', 'dragOwner == ObjectIdentifier(gesture)' in block(trackpad, '@objc private func handleLongPress('))
check('trackpad 이동은 자기 tracker·pan 시작 scope 사용', 'using: sender(for: tracker)' in block(trackpad, '@objc private func handleTrack()') and 'using: dragSender' not in block(trackpad, '@objc private func handlePan('))
check('가로·세로 overlay가 동일 capture API 연결', all('captureInputSender: { client.captureInputSender() }' in (ROOT / path).read_text() for path in ['iOSClient/StreamScreen.swift', 'iOSClient/PortraitStreamScreen.swift']))
check('Vision overlay의 새 capture 인자는 선택 사항', 'var captureInputSender: (() -> (InputEvent) -> Void)? = nil' in overlay)
project = (ROOT / 'iOSClient/Sill.xcodeproj/project.pbxproj').read_text()
for name in ['VisionInputDebt.swift', 'VisionPresentation.swift']:
    check(name + ' iPad·iPhone 파일 참조', project.count('/* ' + name + ' in Sources */ =') == 2 and '../visionOSClient/' + name in project)
changed = subprocess.check_output(['git', 'diff', '--name-only'], cwd=ROOT, text=True).splitlines()
check('Host와 공유 프로토콜 수정 없음', all(not p.startswith('Sources/') for p in changed))
print(json.dumps({'count': len(checks), 'checks': checks}, ensure_ascii=False, indent=2))
