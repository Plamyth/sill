
func message(_ json: String) -> StreamMessage {
    StreamMessage(kind: .selectSource, timestamp: 1, isKeyframe: false, payload: Data(json.utf8))
}
func automatic(_ revision: String) -> StreamMessage {
    message("{\"window\":{\"_0\":17},\"selectionOrigin\":\"automatic\",\"selectionRevision\":\"\(revision)\"}")
}
func human(_ source: StreamSource = .window(7)) -> StreamMessage {
    StreamMessage(kind: .selectSource, timestamp: 1, isKeyframe: false, payload: Wire.encode(source))
}
@MainActor func setup() -> (Host, NWConnection) {
    let host = Host(), peer = NWConnection(), id = ObjectIdentifier(peer)
    host.connections[id] = peer
    host.inputFence.members.insert(id)
    host.dockSelectionIngress.setPeer(id, dockAllowed: false)
    _ = host.listMessage()
    return (host, peer)
}
struct Failure: Error { let description: String }
func require(_ value: @autoclosure () -> Bool, _ text: String) throws {
    if !value() { throw Failure(description: text) }
}
@main struct Checks {
    @MainActor static func main() async {
        var failures = 0
        func check(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                print("CASE " + String(decoding: try! JSONSerialization.data(withJSONObject: ["name": name, "passed": true]), as: UTF8.self))
            } catch {
                failures += 1
                print("CASE " + String(decoding: try! JSONSerialization.data(withJSONObject: ["name": name, "passed": false, "error": String(describing: error)]), as: UTF8.self))
            }
        }
        for (name, payload) in [
            ("missing-revision", "{\"window\":{\"_0\":17},\"selectionOrigin\":\"automatic\"}"),
            ("bad-tag", "{\"window\":{\"_0\":17},\"selectionOrigin\":\"robot\",\"selectionRevision\":\"launch-A:0\"}"),
            ("bad-revision", "{\"window\":{\"_0\":17},\"selectionOrigin\":\"automatic\",\"selectionRevision\":42}"),
            ("stale-revision", "{\"window\":{\"_0\":17},\"selectionOrigin\":\"automatic\",\"selectionRevision\":\"launch-A:99\"}"),
            ("missing-origin", "{\"window\":{\"_0\":17},\"selectionRevision\":\"launch-A:0\"}"),
            ("null-origin", "{\"window\":{\"_0\":17},\"selectionOrigin\":null}"),
            ("null-revision", "{\"window\":{\"_0\":17},\"selectionOrigin\":\"automatic\",\"selectionRevision\":null}"),
            ("empty-revision", "{\"window\":{\"_0\":17},\"selectionOrigin\":\"automatic\",\"selectionRevision\":\"\"}"),
            ("overlong-revision", "{\"window\":{\"_0\":17},\"selectionOrigin\":\"automatic\",\"selectionRevision\":\"\(String(repeating: "a", count: 129))\"}"),
            ("wrong-launch", "{\"window\":{\"_0\":17},\"selectionOrigin\":\"automatic\",\"selectionRevision\":\"launch-B:0\"}")
        ] {
            await check(name) {
                let (host, peer) = setup()
                try require(host.dockSelectionIngress.reserve(for: message(payload), from: ObjectIdentifier(peer)) == nil,
                            "잘못된 자동 요청을 수신 시 거부해야 합니다")
            }
        }
        await check("capture-await-original-revision") {
            let (host, peer) = setup(), request = automatic(host.selectionRevision)
            let ticket = host.dockSelectionIngress.reserve(for: request, from: ObjectIdentifier(peer))
            try require(ticket != nil, "현재 자동 요청은 예약되어야 합니다")
            let task = Task { @MainActor in await host.handle(request, from: peer, selectionTicket: ticket) }
            await host.capture.waitUntilStarted()
            host.active = .window(7); host.active = .none
            host.capture.finish()
            await task.value
            try require(host.server.commits.isEmpty && host.active == .none,
                        "capture await 후 원래 revision이 달라진 자동 요청을 확정하면 안 됩니다")
        }
        await check("receive-to-main-actor-revision-change") {
            let (host, peer) = setup(), request = automatic(host.selectionRevision)
            let ticket = host.dockSelectionIngress.reserve(for: request, from: ObjectIdentifier(peer))!
            host.active = .window(7); host.active = .none
            await host.handle(request, from: peer, selectionTicket: ticket)
            try require(host.capture.starts == 0 && host.server.resets == 0,
                        "수신 예약 뒤 MainActor 처리 전에 세대가 바뀌면 파이프라인을 건드리면 안 됩니다")
        }
        await check("enum-root-and-legacy") {
            for source in [StreamSource.none, .desktop, .window(17)] {
                let payload = Wire.encode(SourceRequest(source: source, origin: .automatic, selectionRevision: "launch-A:0"))
                try require(Wire.decode(StreamSource.self, from: payload) == source, "기존 enum root를 유지해야 합니다")
                let request = Wire.decode(SourceRequest.self, from: Wire.encode(source))
                try require(request?.source == source && request?.origin == nil, "기존 요청은 사람 입력으로 읽어야 합니다")
            }
        }
        await check("actual-and-published-revision-ABA") {
            let (host, peer) = setup(), original = host.selectionRevision
            host.active = .window(7); host.active = .none
            try require(host.selectionRevision == "launch-A:2", "A → B → A는 실제 revision을 올려야 합니다")
            try require(host.dockSelectionIngress.reserve(for: automatic(original), from: ObjectIdentifier(peer)) == nil,
                        "목록을 다시 내보내기 전에도 거울은 ABA를 거부해야 합니다")
            try require(host.dockSelectionIngress.reserve(for: automatic(host.selectionRevision), from: ObjectIdentifier(peer)) == nil,
                        "발행하지 않은 revision을 허용하면 안 됩니다")
            _ = host.listMessage()
            try require(host.dockSelectionIngress.reserve(for: automatic(host.selectionRevision), from: ObjectIdentifier(peer)) != nil,
                        "실제 revision을 발행한 뒤에는 복원이 가능해야 합니다")
        }
        for pendingKind in ["human", "dock"] {
            await check("automatic-keeps-pending-\(pendingKind)") {
                let (host, peer) = setup(), id = ObjectIdentifier(peer)
                host.dockSelectionIngress.setPeer(id, dockAllowed: true)
                _ = host.listMessage(preloadedDock: host.nativeDock.value)
                let request = pendingKind == "human" ? human() : StreamMessage(kind: .dockRequest, timestamp: 1,
                    isKeyframe: false, payload: Wire.encode(RemoteDockRequest(version: host.nativeDock.value.version, itemID: 0, action: .press)))
                let first = host.dockSelectionIngress.reserve(for: request, from: id)!
                try require(host.dockSelectionIngress.reserve(for: automatic(host.selectionRevision), from: id) == nil,
                            "자동 요청이 미완료 명시적 예약을 취소하면 안 됩니다")
                try require(host.dockSelectionIngress.isCurrent(first), "명시적 예약이 최신이어야 합니다")
                let second = host.dockSelectionIngress.reserve(for: human(.window(17)), from: id)!
                host.dockSelectionIngress.complete(first)
                try require(host.dockSelectionIngress.reserve(for: automatic(host.selectionRevision), from: id) == nil,
                            "이전 complete가 새 예약을 해제하면 안 됩니다")
                host.dockSelectionIngress.complete(second)
                try require(host.dockSelectionIngress.reserve(for: automatic(host.selectionRevision), from: id) != nil,
                            "자기 예약을 완료하면 자동 요청을 다시 받을 수 있어야 합니다")
            }
        }
        for reason in ["human", "dock", "disconnect", "closed", "fence", "identity", "shutdown"] {
            await check("capture-await-\(reason)") {
                let (host, peer) = setup(), id = ObjectIdentifier(peer)
                host.dockSelectionIngress.setPeer(id, dockAllowed: true)
                _ = host.listMessage(preloadedDock: host.nativeDock.value)
                let request = automatic(host.selectionRevision), ticket = host.dockSelectionIngress.reserve(for: request, from: id)!
                let task = Task { @MainActor in await host.handle(request, from: peer, selectionTicket: ticket) }
                await host.capture.waitUntilStarted()
                switch reason {
                case "human": _ = host.dockSelectionIngress.reserve(for: human(), from: id)
                case "dock":
                    let dock = StreamMessage(kind: .dockRequest, timestamp: 1, isKeyframe: false,
                        payload: Wire.encode(RemoteDockRequest(version: host.nativeDock.value.version, itemID: 0, action: .press)))
                    _ = host.dockSelectionIngress.reserve(for: dock, from: id)
                case "disconnect": host.dockSelectionIngress.removePeer(id)
                case "closed": peer.state = .cancelled
                case "fence": host.inputFence.members.remove(id)
                case "identity": host.connections[id] = NWConnection()
                default: host.shuttingDown = true
                }
                host.capture.finish(); await task.value
                try require(host.server.commits.isEmpty && host.active == .none, "무효화된 원격 후보를 확정하면 안 됩니다")
                try require(!host.capture.running && host.capture.onFrame == nil, "거부된 캡처 후보를 정리해야 합니다")
            }
        }
        await check("final-commit-rechecks-original-revision") {
            let (host, peer) = setup(), request = automatic(host.selectionRevision)
            let ticket = host.dockSelectionIngress.reserve(for: request, from: ObjectIdentifier(peer))!
            host.nativeDock.onRead = { host.active = .window(7); host.active = .none }
            let task = Task { @MainActor in await host.handle(request, from: peer, selectionTicket: ticket) }
            await host.capture.waitUntilStarted(); host.capture.finish(); await task.value
            try require(host.server.commits.isEmpty, "최종 catalog 조회 후 revision을 다시 확인해야 합니다")
        }
        await check("same-source-restart-keeps-selection-revision") {
            let (host, peer) = setup()
            host.active = .window(17)
            let original = host.selectionRevision, request = human(.window(17))
            let ticket = host.dockSelectionIngress.reserve(for: request, from: ObjectIdentifier(peer))!
            let task = Task { @MainActor in await host.handle(request, from: peer, selectionTicket: ticket) }
            await host.capture.waitUntilStarted(); host.capture.finish(); await task.value
            try require(host.active == .window(17) && host.server.commits.count == 1, "기존 사람 선택이 완료되어야 합니다")
            try require(host.selectionRevision == original, "동일 소스 재시작은 revision을 올리면 안 됩니다")
        }
        for tagged in [false, true] {
            await check("human-without-encrypted-dock-\(tagged)") {
                let (host, peer) = setup()
                let request = tagged ? StreamMessage(kind: .selectSource, timestamp: 1, isKeyframe: false,
                    payload: Wire.encode(SourceRequest(source: .window(17), origin: .human, selectionRevision: "older-launch:9"))) : human(.window(17))
                let ticket = host.dockSelectionIngress.reserve(for: request, from: ObjectIdentifier(peer))!
                let task = Task { @MainActor in await host.handle(request, from: peer, selectionTicket: ticket) }
                await host.capture.waitUntilStarted(); host.capture.finish(); await task.value
                try require(host.active == .window(17) && host.server.commits.count == 1, "기존 사람 요청에 Dock 암호화 권한을 요구하면 안 됩니다")
            }
        }
        await check("automatic-fills-empty-only") {
            let (host, peer) = setup()
            host.active = .window(7); _ = host.listMessage()
            let request = automatic(host.selectionRevision), id = ObjectIdentifier(peer)
            let ticket = host.dockSelectionIngress.reserve(for: request, from: id)!
            await host.handle(request, from: peer, selectionTicket: ticket)
            try require(host.active == .window(7) && host.capture.starts == 0, "자동 복원은 비어 있는 선택만 채워야 합니다")
            host.active = .none; _ = host.listMessage()
            let next = automatic(host.selectionRevision), nextTicket = host.dockSelectionIngress.reserve(for: next, from: id)!
            let task = Task { @MainActor in await host.handle(next, from: peer, selectionTicket: nextTicket) }
            await host.capture.waitUntilStarted(); host.capture.finish(); await task.value
            try require(host.active == .window(17) && host.server.commits.count == 1, "현재 빈 선택은 복원되어야 합니다")
        }
        for changed in [false, true] {
            await check("queued-original-revision-\(changed)") {
                let (host, peer) = setup(), id = ObjectIdentifier(peer)
                let restart = Task { @MainActor in await host.select(.none) }
                await restart.value
                host.switching = true
                let request = automatic(host.selectionRevision), ticket = host.dockSelectionIngress.reserve(for: request, from: id)!
                await host.handle(request, from: peer, selectionTicket: ticket)
                try require(host.pendingDockSelection?.2 == ticket, "전환 중에는 기존 큐에 ticket을 유지해야 합니다")
                try require(host.dockSelectionIngress.reserve(for: automatic(host.selectionRevision), from: id) == nil,
                            "대기 중인 예약을 완료로 표시하면 안 됩니다")
                if changed { host.active = .window(7); host.active = .none }
                host.switching = false
                await host.select(.none)
                if changed {
                    for _ in 0..<50 { await Task.yield() }
                    try require(host.capture.starts == 0 && host.pendingDockSelection == nil, "재개 시 원래 revision을 검사해야 합니다")
                    _ = host.listMessage()
                    try require(host.dockSelectionIngress.reserve(for: automatic(host.selectionRevision), from: id) != nil,
                                "거부된 대기 예약을 완료해야 합니다")
                } else {
                    await host.capture.waitUntilStarted(); host.capture.finish()
                    for _ in 0..<100 where host.server.commits.isEmpty { await Task.yield() }
                    try require(host.active == .window(17) && host.server.commits.count == 1, "유효한 대기 요청은 다시 handle로 재개되어야 합니다")
                }
            }
        }
        await check("new-human-preempts-queued-automatic") {
            let (host, peer) = setup(), id = ObjectIdentifier(peer)
            host.switching = true
            let request = automatic(host.selectionRevision), ticket = host.dockSelectionIngress.reserve(for: request, from: id)!
            await host.handle(request, from: peer, selectionTicket: ticket)
            let next = human(), nextTicket = host.dockSelectionIngress.reserve(for: next, from: id)!
            await host.handle(next, from: peer, selectionTicket: nextTicket)
            try require(host.pendingDockSelection?.2 == nextTicket && !host.dockSelectionIngress.isCurrent(ticket),
                        "새 사람 선택이 기존 자동 대기를 선점해야 합니다")
            host.switching = false
            await host.select(.none)
            await host.capture.waitUntilStarted(); host.capture.finish()
            for _ in 0..<100 where host.server.commits.isEmpty { await Task.yield() }
            try require(host.active == .window(7) && host.server.commits.count == 1, "최신 사람 선택만 확정해야 합니다")
        }
        await check("remove-peer-clears-only-owned-pending") {
            let (host, peer) = setup(), id = ObjectIdentifier(peer), other = NWConnection()
            let otherID = ObjectIdentifier(other)
            host.dockSelectionIngress.setPeer(otherID, dockAllowed: false)
            let ticket = host.dockSelectionIngress.reserve(for: human(), from: id)!
            host.dockSelectionIngress.removePeer(otherID)
            try require(host.dockSelectionIngress.reserve(for: automatic(host.selectionRevision), from: id) == nil,
                        "다른 peer 종료로 예약이 해제되면 안 됩니다")
            host.dockSelectionIngress.removePeer(id)
            try require(!host.dockSelectionIngress.isCurrent(ticket), "종료된 peer의 ticket은 무효여야 합니다")
            host.dockSelectionIngress.setPeer(otherID, dockAllowed: false)
            try require(host.dockSelectionIngress.reserve(for: automatic(host.selectionRevision), from: otherID) != nil,
                        "종료한 소유자의 미완료 표시를 정리해야 합니다")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
