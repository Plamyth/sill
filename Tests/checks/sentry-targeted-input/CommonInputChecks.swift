import Foundation
import CoreGraphics
import StreamProtocol

@MainActor private extension CoordinatorFixture {
    func commonInputChecks() async {
        let a = Connection(), b = Connection()
        let idA = ObjectIdentifier(a), idB = ObjectIdentifier(b)
        let lane = PeerStreamSession()
        let epoch = VideoEpoch(generation: UUID().uuidString, source: .desktop,
            geometry: .init(x: 0, y: 0, width: 400, height: 300), width: 400, height: 300)
        lane.epoch = epoch
        connections = [idA: a, idB: b]; peerStreams = [idA: lane, idB: lane]
        server.sentryAdmission.allowed = true
        synthetic = true
        var posted: [CGEvent] = []
        injector.protectedPointerEgress = { event, scope in
            guard scope?.isCurrent() == true else { return false }
            posted.append(event.copy()!)
            return true
        }
        func send(_ event: InputEvent, from connection: Connection = a, generation: String? = nil) async {
            let payload = Wire.encode(SourceInput(event: event, generation: generation ?? epoch.generation, videoEpoch: epoch.id))
            _ = await receiveInput(StreamMessage(kind: .input, timestamp: 0, isKeyframe: false, payload: payload), from: connection, lane: lane)
            await peerInputQueue.drain()
        }
        let keyDown = InputEvent.key(hidUsage: 4, down: true, modifiers: 0)
        let keyUp = InputEvent.key(hidUsage: 4, down: false, modifiers: 0)
        await send(keyDown)
        let beforeForeign = injector.globalPosts.count
        Checks.check(injector.isUpOfSomethingDown(keyUp, from: idA) && !injector.isUpOfSomethingDown(keyUp, from: idB),
            "생산 decode/queue에서 key-up 부채는 키를 누른 peer만 소유")
        server.sentryAdmission.allowed = false
        await send(keyUp, from: b)
        Checks.check(injector.globalPosts.count == beforeForeign && injector.isUpOfSomethingDown(keyUp, from: idA),
            "admission 거절 peer의 key-up은 다른 peer 키를 정리 경로로 해제하지 않음")
        server.sentryAdmission.allowed = true
        await send(keyUp, from: b)
        Checks.check(injector.globalPosts.count == beforeForeign && injector.isUpOfSomethingDown(keyUp, from: idA),
            "admission 통과 peer도 다른 peer key-up 소유권을 가져오지 않음")
        await send(keyUp, generation: "expired-generation")
        Checks.check(injector.globalPosts.count == beforeForeign + 1 && !injector.isUpOfSomethingDown(keyUp, from: idA),
            "원 peer의 지연 key-up만 이전 generation 정리 경로에서 한 번 해제")

        func phase(_ value: ScrollPhase) async { await send(.scrollGesture(value, x: 0.25, y: 0.75)) }
        let delta = InputEvent.scroll(x: 0.25, y: 0.75, dx: 0.0125, dy: -0.01)
        await phase(.began); await send(delta); await send(delta); await phase(.ended)
        await phase(.momentumBegan); await send(delta); await phase(.momentumEnded)
        Checks.check(posted.count == 5 && posted.allSatisfy { $0.location == CGPoint(x: 100, y: 225) },
            "생산 decode/queue/inject scroll 좌표는 프레임 비율을 소스 point로 변환")
        Checks.check(posted.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) } == [1, 2, 4, 0, 0] &&
            posted.map { $0.getIntegerValueField(.scrollWheelEventMomentumPhase) } == [0, 0, 0, 1, 3],
            "기존 wire 경계는 began/changed/ended와 별도 momentum begin/end로 주입")
        Checks.check(posted[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -3 &&
            posted[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 5 &&
            posted[0].getIntegerValueField(.scrollWheelEventIsContinuous) == 1,
            "scroll 자연 방향과 가로·세로 point scale 및 연속 플래그 보존")
        posted.removeAll()
        await phase(.began)
        for _ in 0..<3 { await send(.scroll(x: 0.25, y: 0.75, dx: 0.001, dy: 0)) }
        await phase(.ended)
        Checks.check(posted.reduce(Int64(0)) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) } == 1,
            "느린 scroll의 sub-point remainder는 생산 주입까지 누적")
        posted.removeAll()
        await phase(.began); await send(delta); await phase(.ended)
        let beforeBare = posted.count
        await send(delta)
        print("TRACE handoff A bare wheel expected=\(beforeBare + 1) actual=\(posted.count)")
        Checks.check(posted.count == beforeBare + 1 && posted.last?.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
            "ended 뒤 momentum 없는 원 peer bare wheel은 handoff에 갇히지 않음")
        await send(delta, from: b)
        print("TRACE handoff B bare wheel expected=\(beforeBare + 2) actual=\(posted.count)")
        Checks.check(posted.count == beforeBare + 2,
            "종료된 handoff는 다른 peer의 다음 bare wheel을 가로막지 않음")
        await send(.scrollGesture(.began, x: 0.25, y: 0.75), from: b)
        await send(delta, from: b)
        Checks.check(posted.last?.getIntegerValueField(.scrollWheelEventScrollPhase) == 1,
            "다른 peer의 새 began은 기존에도 다음 gesture를 시작할 수 있음")
        await send(.scrollGesture(.ended, x: 0.25, y: 0.75), from: b)
        await send(.scrollGesture(.momentumEnded, x: 0.25, y: 0.75), from: b)
        let orphanPhases: [[ScrollPhase]] = [[], [.ended], [.momentumBegan], [.ended, .momentumBegan]]
        for (index, phases) in orphanPhases.enumerated() {
            for otherPeer in [false, true] {
                posted.removeAll()
                await send(keyDown)
                await phase(.momentumBegan)
                await send(delta)
                print("TRACE orphan phases=\(index) otherPeer=\(otherPeer) delta=1 expected=0 actual=\(posted.count)")
                for phase in phases { await send(.scrollGesture(phase, x: 0.25, y: 0.75)) }
                let peer = otherPeer ? b : a
                for number in 2...3 {
                    await send(delta, from: peer)
                    print("TRACE orphan phases=\(index) otherPeer=\(otherPeer) delta=\(number) expected=0 actual=\(posted.count)")
                }
                Checks.check(posted.isEmpty && !injector.protectedScrollPending,
                    "생산 decode/queue의 orphan 반복 delta·phase는 wheel이나 scroll 부채를 만들지 않음 \(index)/\(otherPeer)")
                let beforeForeignUp = injector.globalPosts.count
                await send(keyUp, from: b)
                Checks.check(injector.globalPosts.count == beforeForeignUp &&
                    injector.isUpOfSomethingDown(keyUp, from: idA) && !injector.isUpOfSomethingDown(keyUp, from: idB),
                    "orphan 거절 뒤 다른 peer는 원 key 부채를 가져오거나 해제하지 않음 \(index)/\(otherPeer)")
                await send(keyUp)
                await phase(.momentumEnded)
                _ = injector.prepareRelease()
            }
        }
        posted.removeAll()
        await phase(.momentumBegan); await send(delta)
        await send(.scrollGesture(.began, x: 0.25, y: 0.75), from: b)
        await send(delta, from: b)
        await send(.scrollGesture(.ended, x: 0.25, y: 0.75), from: b)
        await send(.scrollGesture(.momentumBegan, x: 0.25, y: 0.75), from: b)
        await send(delta, from: b)
        await send(.scrollGesture(.momentumEnded, x: 0.25, y: 0.75), from: b)
        Checks.check(posted.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) } == [1, 4, 0, 0] &&
            posted.map { $0.getIntegerValueField(.scrollWheelEventMomentumPhase) } == [0, 0, 1, 3] &&
            !injector.protectedScrollPending,
            "orphan 뒤 다른 peer의 명시적 began은 새 gesture와 유효 momentum을 정상 재개")
        posted.removeAll()
        await send(.pointer(.leftDown, x: 0.2, y: 0.3))
        await send(.pointer(.move, x: 0.7, y: 0.8))
        await send(.pointer(.leftUp, x: 0.7, y: 0.8))
        Checks.check(posted.map(\.type) == [.leftMouseDown, .leftMouseDragged, .leftMouseUp] &&
            posted.last?.location == CGPoint(x: 280, y: 240), "생산 입력 queue는 down/drag/up 순서와 좌표 보존")
        posted.removeAll()
        server.sentryAdmission.allowed = false
        await phase(.began); await send(delta)
        Checks.check(posted.isEmpty, "Sentry admission 거절은 scroll 주입 전에 차단")
        server.sentryAdmission.allowed = true
        await send(delta, generation: "expired-generation")
        Checks.check(posted.isEmpty, "지연 scroll은 오래된 generation으로 새 소스에 도달하지 않음")
        var gate: CheckedContinuation<Void, Never>?
        peerInputQueue.enqueue(peer: idB) { _ in await withCheckedContinuation { gate = $0 } }
        while gate == nil { await Task.yield() }
        let queued = StreamMessage(kind: .input, timestamp: 0, isKeyframe: false,
            payload: Wire.encode(SourceInput(event: delta, generation: epoch.generation, videoEpoch: epoch.id)))
        _ = await receiveInput(queued, from: a, lane: lane)
        peerInputQueue.cancel(peer: idA)
        gate?.resume()
        await peerInputQueue.drain()
        Checks.check(posted.isEmpty, "생산 queue에서 취소된 대기 scroll은 주입하지 않음")
        _ = await receiveInput(StreamMessage(kind: .input, timestamp: 0, isKeyframe: false, payload: Data("invalid".utf8)), from: a, lane: lane)
        await peerInputQueue.drain()
        Checks.check(posted.isEmpty, "생산 decode가 실패한 입력은 queue와 주입에 도달하지 않음")
        _ = injector.prepareRelease()
    }

    func commonGestureChecks() async {
        let peer = Connection(), lane = PeerStreamSession()
        let id = ObjectIdentifier(peer)
        let epoch = VideoEpoch(generation: UUID().uuidString, source: .desktop,
            geometry: .init(x: 0, y: 0, width: 400, height: 300), width: 400, height: 300)
        lane.epoch = epoch
        connections = [id: peer]; peerStreams = [id: lane]
        server.sentryAdmission.allowed = true; synthetic = true
        injector.isolatesPhysicalInput = true
        injector.protectedPointerEgress = { _, scope in scope?.isCurrent() == true }
        let dismissals: [InputEvent] = [.key(hidUsage: 41, down: true, modifiers: 0),
            .pointer(.leftDown, x: 0.5, y: 0.5), .text("검사")]
        for event in dismissals {
            peerGestureChords[id] = nil; gestureArrivals[id] = []
            let gesture = StreamMessage(kind: .gesture, timestamp: 0, isKeyframe: false,
                payload: Wire.encode(TrackpadGesture(gesture: TrackpadGesture.swipeUp, fingers: 3,
                    generation: epoch.generation, videoEpoch: epoch.id)))
            _ = await receiveInput(gesture, from: peer, lane: lane)
            await peerInputQueue.drain()
            let input = StreamMessage(kind: .input, timestamp: 0, isKeyframe: false,
                payload: Wire.encode(SourceInput(event: event, generation: epoch.generation, videoEpoch: epoch.id)))
            _ = await receiveInput(input, from: peer, lane: lane)
            await peerInputQueue.drain()
            let before = injector.globalPosts.count
            _ = await receiveInput(gesture, from: peer, lane: lane)
            await peerInputQueue.drain()
            print("TRACE kind8 \(Self.gestureInput(event)) next swipeUp posts expected=2 actual=\(injector.globalPosts.count - before)")
            Checks.check(injector.globalPosts.count == before + 2,
                "kind28 swipeUp 뒤 kind8 \(Self.gestureInput(event))는 overview 기억을 해제하여 다음 swipeUp을 허용")
            injector.releaseInput(of: id)
        }
    }
}
