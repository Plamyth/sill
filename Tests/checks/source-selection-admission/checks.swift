
func message(_ json: String) -> StreamMessage {
    StreamMessage(kind: .selectSource, timestamp: 1, isKeyframe: false, payload: Data(json.utf8))
}
func automatic(_ revision: String) -> StreamMessage {
    message("{\"window\":{\"_0\":17},\"selectionOrigin\":\"automatic\",\"selectionRevision\":\"\(revision)\"}")
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
            ("stale-revision", "{\"window\":{\"_0\":17},\"selectionOrigin\":\"automatic\",\"selectionRevision\":\"launch-A:99\"}")
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
        exit(failures == 0 ? 0 : 1)
    }
}
