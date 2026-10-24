import Foundation
import Network
import StreamProtocol

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { print("FAIL \(name)"); exit(1) }
    checks += 1
    print("PASS \(name)")
}
func inputs(_ peer: NWConnection) -> [SourceInput] {
    peer.sent.filter { $0.first == StreamMessageKind.input.rawValue }.compactMap {
        Wire.decode(SourceInput.self, from: Data($0.dropFirst(StreamMessage.headerLength)))
    }
}
func makeEpoch(_ generation: String, source: StreamSource = .desktop) -> VideoEpoch {
    VideoEpoch(generation: generation, source: source,
               geometry: .init(x: 0, y: 0, width: 800, height: 600), width: 800, height: 600)
}
func catalog(_ epoch: VideoEpoch) -> WindowList {
    WindowList(macName: "검사 Mac", windows: [], active: epoch.source, inputGeneration: epoch.generation,
               presentationInput: 1, videoEpoch: epoch)
}
let layer = NSObject()
func present(_ client: StreamClient, _ peer: NWConnection, _ epoch: VideoEpoch) {
    client.catalog(catalog(epoch), peer: peer)
    client.ready(VisionPresentation.Ticket(epoch: epoch, peer: ObjectIdentifier(peer), layer: ObjectIdentifier(layer)))
}
func drainMain() {
    var done = false
    DispatchQueue.main.async { done = true }
    while !done { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001)) }
}
let client = StreamClient(), peer = NWConnection()
client.connection = peer
client.sendInput(.text("표시 전 입력"))
client.queue.sync {}
check(peer.sent.isEmpty, "현재 프레임 실제 표시 전 iOS 입력 거부")

let epoch = makeEpoch("A")
client.catalog(catalog(epoch), peer: peer)
client.sendInput(.pointer(.leftDown, x: 0.3, y: 0.4)); client.queue.sync {}
check(peer.sent.isEmpty, "catalog만 수신하고 아직 표시하지 않은 클릭 거부")
present(client, peer, epoch)
client.sendInput(.text("현재 표시된 화면"))
client.queue.sync {}
let payload = peer.sent.last.map { Data($0.dropFirst(StreamMessage.headerLength)) }
let received = payload.flatMap { Wire.decode(SourceInput.self, from: $0) }
check(received?.generation == "A" && received?.videoEpoch == epoch.id, "iOS 입력이 표시 epoch와 generation을 함께 전송")

for event in [InputEvent.pointer(.move, x: 0.1, y: 0.2), .pointer(.leftDown, x: 0.1, y: 0.2),
              .pointer(.leftUp, x: 0.1, y: 0.2), .key(hidUsage: 4, down: true, modifiers: 0),
              .key(hidUsage: 4, down: false, modifiers: 0), .text("한글👩‍💻") ] {
    let count = inputs(peer).count
    client.sendInput(event); client.flush()
    check(inputs(peer).count == count + 1 && inputs(peer).last?.event == event
          && inputs(peer).last?.videoEpoch == epoch.id && inputs(peer).last?.generation == "A",
          "이동·클릭·하드웨어 키·조합 문자가 같은 표시 snapshot 사용 \(event)")
}
let held = InputEvent.pointer(.leftDown, x: 0.3, y: 0.4)
client.sendInput(held); client.queue.sync {}
let beforeSwitch = inputs(peer).count
let second = makeEpoch("B", source: .window(42))
client.catalog(catalog(second), peer: peer); client.queue.sync {}
check(inputs(peer).count == beforeSwitch + 1 && inputs(peer).last?.event == .pointer(.leftUp, x: 0.3, y: 0.4)
      && inputs(peer).last?.videoEpoch == epoch.id && inputs(peer).last?.generation == "A", "실제 전송 down만 원래 epoch로 해제")
client.ready(VisionPresentation.Ticket(epoch: epoch, peer: ObjectIdentifier(peer), layer: ObjectIdentifier(layer)))
client.sendInput(.text("옛 표시 콜백")); client.queue.sync {}
check(inputs(peer).count == beforeSwitch + 1, "소스 교체 뒤 이전 표시 티켓이 입력을 다시 열지 못함")
present(client, peer, second)
let beforeLateUp = inputs(peer).count
client.sendInput(.pointer(.leftUp, x: 0.3, y: 0.4))
client.sendInput(.key(hidUsage: 4, down: false, modifiers: 0)); client.queue.sync {}
check(inputs(peer).count == beforeLateUp, "소스 교체 뒤 늦은 UIKit 종료가 새 binding의 up으로 유출되지 않음")

_ = client.link.hold(peer)
client.sendInput(.key(hidUsage: 5, down: true, modifiers: 0))
client.sendInput(.key(hidUsage: 5, down: false, modifiers: 0)); client.queue.sync {}
check(inputs(peer).count == beforeLateUp, "대기 down과 up은 전송 전 debt를 만들지 않음")
_ = client.link.unhold(peer)
check(Array(inputs(peer).suffix(2)).map(\.event) == [.key(hidUsage: 5, down: true, modifiers: 0), .key(hidUsage: 5, down: false, modifiers: 0)],
      "deferred flush는 down 뒤 debt를 만들고 대응 up을 허용")
let beforeUnsent = inputs(peer).count
_ = client.link.hold(peer)
client.sendInput(held); client.sendInput(.text("취소할 조합 문자")); client.queue.sync {}
client.cancel(); client.queue.sync {}; _ = client.link.unhold(peer)
check(inputs(peer).count == beforeUnsent, "전송되지 않은 queued down·문자는 취소되며 가짜 up을 생성하지 않음")

present(client, peer, second)
client.coalesceNextMove()
client.sendInput(.pointer(.move, x: 0.9, y: 0.8)); client.queue.sync {}
check(inputs(peer).count == beforeUnsent, "기존 이동 coalescer에 snapshot이 대기")
client.cancel(); client.flush()
check(inputs(peer).count == beforeUnsent, "표시 취소는 coalesced 이동도 폐기")

present(client, peer, second)
let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
client.queue.async { entered.signal(); resume.wait() }
entered.wait()
client.sendInput(.text("큐의 옛 문자"))
client.sendInput(held)
client.cancel()
resume.signal(); client.queue.sync {}
check(inputs(peer).count == beforeUnsent, "network queue 대기 문자와 클릭은 취소 뒤 재인코딩·전송되지 않음")

present(client, peer, second)
client.sendInput(.key(hidUsage: 6, down: true, modifiers: 0)); client.queue.sync {}
let replacement = NWConnection(), oldCount = inputs(peer).count
client.connection = replacement; client.queue.sync {}
check(inputs(peer).count == oldCount + 1 && inputs(peer).last?.event == .key(hidUsage: 6, down: false, modifiers: 0)
      && inputs(peer).last?.videoEpoch == second.id, "연결 교체는 old peer의 전송 down만 old binding으로 해제")
check(replacement.sent.isEmpty, "연결 교체가 새 peer로 up을 보내지 않음")
let third = makeEpoch("C")
present(client, replacement, third)
client.sendInput(.key(hidUsage: 6, down: false, modifiers: 0))
client.sendInput(.pointer(.leftUp, x: 0.1, y: 0.2)); client.queue.sync {}
check(replacement.sent.isEmpty, "이전 기기 제스처의 늦은 up은 새 peer에서도 거부")

_ = client.link.hold(replacement)
client.sendInput(.text("전경 이탈 전 문자")); client.queue.sync {}
client.cancel(); client.appInForeground = false
_ = client.link.unhold(replacement)
client.sendInput(.text("백그라운드 문자")); client.queue.sync {}
check(replacement.sent.isEmpty, "전경 이탈이 대기 문자와 후속 입력을 차단")
client.appInForeground = true
present(client, replacement, third)
client.sendInput(.text("새 전경 표시")); client.queue.sync {}
check(inputs(replacement).last?.videoEpoch == third.id, "새 전경의 표시 확인 뒤 정상 입력 복구")

var missing = catalog(third); missing.videoEpoch = nil
client.catalog(missing, peer: replacement)
client.sendInput(.text("epoch 유실")); client.queue.sync {}
check(inputs(replacement).count == 1 && client.visionInputBinding == .awaitingPresentation(nil), "modern epoch 유실은 fail closed")
let legacy = WindowList(macName: "구형", windows: [], active: .desktop, inputGeneration: "legacy")
client.catalog(legacy, peer: replacement)
client.sendInput(.text("downgrade")); client.queue.sync {}
check(inputs(replacement).count == 1 && client.visionInputBinding == .awaitingPresentation(nil), "modern 확인 뒤 legacy 메타데이터로 fail open하지 않음")
let oldPeer = NWConnection()
client.connection = oldPeer
client.catalog(legacy, peer: oldPeer)
client.sendInput(.text("구형 generation 계약")); client.queue.sync {}
check(inputs(oldPeer).last?.generation == "legacy" && inputs(oldPeer).last?.videoEpoch == nil, "새 구형 host는 기존 generation 계약 유지")
let rawPeer = NWConnection()
client.connection = rawPeer
client.catalog(WindowList(macName: "더 오래된 host", windows: [], active: .desktop), peer: rawPeer)
client.sendInput(.text("원시 입력")); client.queue.sync {}
check(Wire.decode(InputEvent.self, from: Data(rawPeer.sent.last!.dropFirst(StreamMessage.headerLength))) == .text("원시 입력"), "확인된 구형 host의 raw legacy 정책 유지")

let current = NWConnection()
let previousPermit = client.visionInputPermit!
let replaced = DispatchSemaphore(value: 0)
client.queue.async { client.connection = current; replaced.signal() }
replaced.wait()
check(!client.link.send(Data([8, 1]), onlyOn: current, permit: previousPermit), "network queue 연결 교체 즉시 이전 permit 차단")
drainMain()
check(client.visionInputBinding == .awaitingCatalog && client.displayView.mainOnly, "network queue 교체의 UIKit 무효화는 main에서만 실행")
let transient = NWConnection(), latest = NWConnection()
client.queue.async { client.connection = transient; client.connection = latest; replaced.signal() }
replaced.wait()
drainMain()
check(client.displayView.peer == nil && client.connection === latest, "지연된 이전 peer 무효화는 최신 연결 상태를 덮지 않음")
func overlay(_ client: StreamClient) -> InputOverlayView {
    let view = InputOverlayView()
    view.send = { client.sendInput($0) }
    view.captureInputSender = { client.captureInputSender() }
    return view
}
let producerClient = StreamClient(), firstPeer = NWConnection(), nextPeer = NWConnection()
producerClient.connection = firstPeer
present(producerClient, firstPeer, makeEpoch("producer-A"))
let pointerView = overlay(producerClient), oldTouch = UITouch(), newTouch = UITouch()
pointerView.touchesBegan([oldTouch], with: nil); producerClient.flush()
check(inputs(firstPeer).last?.event == .pointer(.leftDown, x: 0.2, y: 0.3), "실제 Pencil producer가 첫 scope의 down 생성")
producerClient.connection = nextPeer
present(producerClient, nextPeer, makeEpoch("producer-B"))
let beforeBlockedReplacement = inputs(nextPeer).count
pointerView.touchesBegan([newTouch], with: nil); producerClient.flush()
check(inputs(nextPeer).count == beforeBlockedReplacement, "같은 overlay는 epoch 교체 뒤에도 기존 물리 owner 종료 전 새 touch 거부")
// A replacement overlay may start a new producer while UIKit finishes the old view's touch.
let replacementPointerView = overlay(producerClient)
replacementPointerView.touchesBegan([newTouch], with: nil); producerClient.flush()
let beforeOldTouchEnd = inputs(nextPeer).count
pointerView.touchesEnded([oldTouch], with: nil); producerClient.flush()
check(inputs(nextPeer).count == beforeOldTouchEnd, "P2 실제 Pencil 옛 종료가 새 down 뒤 새 드래그를 해제하지 않음")
replacementPointerView.touchesEnded([newTouch], with: nil); producerClient.flush()
check(inputs(nextPeer).count == beforeOldTouchEnd + 1 && inputs(nextPeer).last?.event == .pointer(.leftUp, x: 0.2, y: 0.3), "새 Pencil producer의 종료만 새 드래그를 해제")
let afterReplacementEnd = inputs(nextPeer).count
pointerView.touchesEnded([newTouch], with: nil); producerClient.flush()
check(inputs(nextPeer).count == afterReplacementEnd, "같은 overlay가 거부했던 새 touch의 늦은 종료도 가짜 up 없음")

let keyView = overlay(producerClient), oldPress = UIPress(), newPress = UIPress()
_ = keyView.forward([oldPress], down: true); producerClient.queue.sync {}
present(producerClient, nextPeer, makeEpoch("producer-C"))
_ = keyView.forward([newPress], down: true); producerClient.queue.sync {}
let beforeOldKeyEnd = inputs(nextPeer).count
_ = keyView.forward([oldPress], down: false); producerClient.queue.sync {}
check(inputs(nextPeer).count == beforeOldKeyEnd, "P2 실제 hardware key 옛 종료가 같은 usage의 새 down을 해제하지 않음")
_ = keyView.forward([newPress], down: false); producerClient.queue.sync {}
check(inputs(nextPeer).count == beforeOldKeyEnd + 1 && inputs(nextPeer).last?.event == .key(hidUsage: 0x50, down: false, modifiers: 0), "옛 key 종료가 새 UIPress 소유권도 지우지 않음")

let oldFinger = overlay(producerClient), oldLong = UILongPressGestureRecognizer(), finger = UITouch()
_ = oldFinger.gestureRecognizer(oldLong, shouldReceive: finger)
oldLong.state = .began; oldFinger.handleLongPress(oldLong); producerClient.flush()
present(producerClient, nextPeer, makeEpoch("producer-D"))
let newFinger = overlay(producerClient), newLong = UILongPressGestureRecognizer()
_ = newFinger.gestureRecognizer(newLong, shouldReceive: finger)
newLong.state = .began; newFinger.handleLongPress(newLong); producerClient.flush()
let beforeOldLongEnd = inputs(nextPeer).count
oldLong.state = .ended; oldFinger.handleLongPress(oldLong); producerClient.flush()
check(inputs(nextPeer).count == beforeOldLongEnd, "P2 실제 손가락 인식기 옛 종료가 새 down을 해제하지 않음")
newLong.state = .ended; newFinger.handleLongPress(newLong); producerClient.flush()
check(inputs(nextPeer).count == beforeOldLongEnd + 1, "새 손가락 인식기는 자기 scope로 정상 종료")

let oldPad = TrackpadSurface(), oldPadLong = UILongPressGestureRecognizer()
oldPad.send = producerClient.captureInputSender()
oldPadLong.state = .began; oldPad.handleLongPress(oldPadLong); producerClient.flush()
present(producerClient, nextPeer, makeEpoch("producer-E"))
let newPad = TrackpadSurface(), newPadLong = UILongPressGestureRecognizer()
newPad.send = producerClient.captureInputSender()
newPadLong.state = .began; newPad.handleLongPress(newPadLong); producerClient.flush()
let beforeOldPadEnd = inputs(nextPeer).count
oldPadLong.state = .ended; oldPad.handleLongPress(oldPadLong); producerClient.flush()
check(inputs(nextPeer).count == beforeOldPadEnd, "P2 실제 trackpad 옛 producer 종료가 새 드래그를 해제하지 않음")
newPadLong.state = .ended; newPad.handleLongPress(newPadLong); producerClient.flush()
check(inputs(nextPeer).count == beforeOldPadEnd + 1, "새 trackpad producer의 종료는 정상 전송")
func padAdapter(_ client: StreamClient) -> TrackpadView {
    TrackpadView(send: { client.sendInput($0) }, setPointer: { _ in }, feed: { (nil, 0) },
                 onFingers: { _ in }, latched: [], onModifiersConsumed: {},
                 captureInputSender: { client.captureInputSender() })
}
let coastClient = StreamClient(), coastPeer = NWConnection(), afterCoastPeer = NWConnection()
coastClient.connection = coastPeer
present(coastClient, coastPeer, makeEpoch("coast-A"))
let firstPadAdapter = padAdapter(coastClient)
let reusedPad = firstPadAdapter.makeUIView(context: ())
firstPadAdapter.updateUIView(reusedPad, context: ())
reusedPad.beginScroll(); reusedPad.endScroll(momentumVelocity: CGPoint(x: 30, y: 40)); coastClient.flush()
coastClient.connection = afterCoastPeer
present(coastClient, afterCoastPeer, makeEpoch("coast-B"))
padAdapter(coastClient).updateUIView(reusedPad, context: ())
let beforeOldCoast = inputs(afterCoastPeer).count
reusedPad.momentum.step(); coastClient.flush()
check(inputs(afterCoastPeer).count == beforeOldCoast, "실제 updateUIView 이후 옛 trackpad coast step이 새 epoch로 유출되지 않음")
reusedPad.momentum.stop(); coastClient.flush()
check(inputs(afterCoastPeer).count == beforeOldCoast, "옛 trackpad momentum 종료도 시작 scope에 묶임")
reusedPad.beginScroll(); reusedPad.endScroll(momentumVelocity: CGPoint(x: 30, y: 40)); coastClient.flush()
let beforeNewCoast = inputs(afterCoastPeer).count
reusedPad.momentum.step(); coastClient.flush()
check(inputs(afterCoastPeer).count == beforeNewCoast + 1 && inputs(afterCoastPeer).last?.generation == "coast-B", "재사용 trackpad의 새 flick은 현재 scope로 정상 전송")
reusedPad.momentum.stop(); coastClient.flush()
let reusedOldLong = UILongPressGestureRecognizer(), reusedNewLong = UILongPressGestureRecognizer()
reusedOldLong.state = .began; reusedPad.handleLongPress(reusedOldLong); coastClient.flush()
present(coastClient, afterCoastPeer, makeEpoch("coast-C"))
padAdapter(coastClient).updateUIView(reusedPad, context: ())
reusedNewLong.state = .began; reusedPad.handleLongPress(reusedNewLong); coastClient.flush()
let beforeReusedOldUp = inputs(afterCoastPeer).count
reusedOldLong.state = .ended; reusedPad.handleLongPress(reusedOldLong); coastClient.flush()
check(inputs(afterCoastPeer).count == beforeReusedOldUp, "실제 updateUIView 이후 옛 drag 종료가 새 drag를 해제하지 않음")
reusedNewLong.state = .ended; reusedPad.handleLongPress(reusedNewLong); coastClient.flush()
check(inputs(afterCoastPeer).count == beforeReusedOldUp + 1, "재사용 trackpad의 새 drag 종료 소유권 보존")

let ownerClient = StreamClient(), ownerPeer = NWConnection()
ownerClient.connection = ownerPeer
present(ownerClient, ownerPeer, makeEpoch("pointer-owner"))
let ownerView = overlay(ownerClient), pencilOwner = UITouch(), ignoredPointer = UITouch()
ignoredPointer.type = .indirectPointer
ownerView.touchesBegan([pencilOwner], with: nil); ownerClient.flush()
let afterOwnerDown = inputs(ownerPeer).count
check(inputs(ownerPeer).last?.event == .pointer(.leftDown, x: 0.2, y: 0.3), "동일 epoch의 첫 물리 포인터가 버튼 소유")
ownerView.touchesBegan([ignoredPointer], with: nil); ownerClient.flush()
check(inputs(ownerPeer).count == afterOwnerDown, "동일 epoch의 두 번째 물리 포인터 down과 선행 move 모두 거부")
ignoredPointer.point = CGPoint(x: 70, y: 80)
ownerView.touchesMoved([ignoredPointer], with: nil)
ownerView.touchesEnded([ignoredPointer], with: nil); ownerClient.flush()
check(inputs(ownerPeer).count == afterOwnerDown, "거부한 물리 포인터의 move와 up은 전송·debt 없음")
pencilOwner.point = CGPoint(x: 40, y: 50)
ownerView.touchesMoved([ignoredPointer, pencilOwner], with: nil); ownerClient.flush()
check(inputs(ownerPeer).count == afterOwnerDown + 1 && inputs(ownerPeer).last?.event == .pointer(.move, x: 0.4, y: 0.5), "혼합 touch 집합에서도 현재 owner만 이동")
ownerView.touchesEnded([ignoredPointer, pencilOwner], with: nil); ownerClient.flush()
let afterOwnerEnd = inputs(ownerPeer).count
check(afterOwnerEnd == afterOwnerDown + 2 && inputs(ownerPeer).last?.event == .pointer(.leftUp, x: 0.4, y: 0.5), "물리 포인터 owner의 종료는 자기 down만 한 번 해제")
ownerView.touchesMoved([ignoredPointer], with: nil)
ownerView.touchesCancelled([ignoredPointer], with: nil); ownerClient.flush()
check(inputs(ownerPeer).count == afterOwnerEnd, "owner 종료 뒤 거부한 touch를 승격하거나 가짜 up을 보내지 않음")
let nextPointerOwner = UITouch(), ignoredPencil = UITouch()
nextPointerOwner.type = .indirectPointer
ownerView.touchesBegan([nextPointerOwner], with: nil); ownerClient.flush()
check(inputs(ownerPeer).count == afterOwnerEnd + 2, "owner 종료 뒤 새 touch만 다음 버튼 소유 허용")
let beforeIgnoredPencil = inputs(ownerPeer).count
let secondaryClick = UIEvent(); secondaryClick.buttonMask = .secondary
ownerView.touchesBegan([ignoredPencil], with: secondaryClick)
ownerView.touchesCancelled([ignoredPencil], with: nil); ownerClient.flush()
check(inputs(ownerPeer).count == beforeIgnoredPencil, "간접 포인터 소유 중 Pencil의 down과 cancel도 거부")
ownerView.touchesEnded([pencilOwner], with: nil); ownerClient.flush()
check(inputs(ownerPeer).count == beforeIgnoredPencil, "이전 owner의 중복 종료가 다음 owner를 해제하지 않음")
ownerView.touchesCancelled([nextPointerOwner], with: nil); ownerClient.flush()
check(inputs(ownerPeer).count == beforeIgnoredPencil + 1 && inputs(ownerPeer).last?.event == .pointer(.leftUp, x: 0.2, y: 0.3), "owner cancel은 자기 버튼만 한 번 해제")
let secondaryOwner = UITouch(); secondaryOwner.type = .indirectPointer
ownerView.touchesBegan([secondaryOwner], with: secondaryClick); ownerClient.flush()
check(inputs(ownerPeer).last?.event == .pointer(.rightDown, x: 0.2, y: 0.3), "cancel 뒤 새 포인터의 secondary 버튼도 허용")
ownerView.touchesCancelled([secondaryOwner], with: nil); ownerClient.flush()
check(inputs(ownerPeer).last?.event == .pointer(.rightUp, x: 0.2, y: 0.3), "secondary owner cancel은 대응 rightUp으로 종료")
print("iPad 입력 epoch \(checks)/\(checks)")
