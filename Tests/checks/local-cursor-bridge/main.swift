import Foundation
import StreamProtocol
@main struct Checks {
    @MainActor static func main() async {
        var checks = 0
        func check(_ value: Bool) { precondition(value); checks += 1 }
        do {
            let f = Fixture(), session = f.channel.open()
            defer { f.broker.stop() }
            let hello = await f.command(session, operation: "hello")
            check(hello["status"] as? String == "observed" && hello["connectionID"] as? String != session.id.uuidString)
            let wrong = await f.command(session, operation: "bindWindow", fields: ["connectionID": UUID().uuidString, "capture": f.capture, "controlEnabled": true])
            check(wrong["code"] as? String == "connection_mismatch" && f.lookups == 0)
            let bound = await f.bind(session)
            check(bound["status"] as? String == "bound")
            let scope = f.scope(session)
            let down = await f.input(session, event: .pointer(.leftDown, x: 0.3, y: 0.4))
            check(down["status"] as? String == "inputPosted" && f.injector.held.count == 1)
            let renewed = await f.command(session, operation: "renew", fields: scope.merging(["ttlMilliseconds": 2000]) { _, new in new })
            check(renewed["leaseID"] as? String == scope["leaseID"] as? String && renewed["leaseGeneration"] as? String == scope["leaseGeneration"] as? String)
            let up = await f.input(session, event: .pointer(.leftUp, x: 0.3, y: 0.4))
            check(up["status"] as? String == "inputPosted" && f.injector.held.isEmpty)
            let packet = f.packet(session, operation: "input", fields: scope.merging(["event": try! JSONSerialization.jsonObject(with: Wire.encode(InputEvent.text("x")))]) { _, new in new })
            _ = await f.transmit(packet, to: session)
            let posted = f.injector.posts, previous = session.replies.last!
            _ = await f.transmit(packet, to: session)
            check(f.injector.posts == posted && session.replies.last! == previous)
            _ = await f.command(session, operation: "release", fields: f.scope(session))
            let rebound = await f.bind(session)
            check(rebound["status"] as? String == "bound" && rebound["leaseID"] as? String != scope["leaseID"] as? String)
        }
        do {
            let f = Fixture(), session = f.channel.open()
            defer { f.broker.stop() }
            _ = await f.command(session, operation: "hello"); _ = await f.bind(session)
            _ = await f.input(session, event: .pointer(.leftDown, x: 0.5, y: 0.5))
            let count = f.injector.posts
            f.window.checking = { f.remote = true }
            let denied = await f.input(session, event: .text("wrong target"))
            check(denied["status"] as? String == "refused" && f.injector.posts == count && f.injector.cleanup.count == 1)
            check(f.injector.held.isEmpty && denied["postedEvents"] == nil)
            f.window.checking = nil; f.remote = false; f.broker.ownershipChanged()
            _ = await f.bind(session)
            _ = await f.input(session, event: .pointer(.leftDown, x: 0.5, y: 0.5))
            f.window.focused = false
            let unfocused = await f.input(session, event: .text("no"))
            check(unfocused["status"] as? String == "refused" && f.injector.held.isEmpty)
        }
        do {
            let f = Fixture(), first = f.channel.open(), second = f.channel.open()
            defer { f.broker.stop() }
            _ = await f.command(first, operation: "hello"); _ = await f.command(second, operation: "hello")
            _ = await f.bind(first); _ = await f.input(first, event: .pointer(.leftDown, x: 0.4, y: 0.5))
            let rejected = await f.bind(second)
            check(rejected["code"] as? String == "lease_unavailable" && f.injector.held.count == 1 && f.injector.cleanup.isEmpty)
            second.close()
            check(f.injector.held.count == 1)
            f.sentry = true; f.broker.ownershipChanged()
            check(f.injector.held.isEmpty && f.injector.cleanup.count == 1)
        }
        for kind in ["conversation-scoped", "sill-delegated"] {
            let f = Fixture(), session = f.channel.open()
            defer { f.broker.stop() }
            _ = await f.command(session, operation: "hello")
            var fields: [String: Any] = ["capture": f.capture, "controlEnabled": true]
            if kind == "sill-delegated" { fields["origin"] = kind }
            else { fields["interaction"] = ["kind": kind, "conversationID": "a-real-looking-thread"] }
            let refused = await f.command(session, operation: "bindWindow", fields: fields)
            check(refused["status"] as? String == "refused" && f.lookups == 0 && f.injector.posts == 0)
        }
        do {
            let f = Fixture(), session = f.channel.open()
            defer { f.broker.stop() }
            _ = await f.command(session, operation: "hello")
            f.holdLookup = true
            let packet = f.packet(session, operation: "bindWindow", fields: ["capture": f.capture, "controlEnabled": true, "ttlMilliseconds": 2000])
            f.channel.onRequest(packet, session)
            await f.until { f.gate != nil }
            f.channel.onRequest(packet, session)
            for _ in 0..<10 { await Task.yield() }
            check(f.lookups == 1 && session.isCurrent)
            f.gate!.resume(); f.gate = nil
            await f.until { object(session.replies.last)?["status"] as? String == "bound" }
            check(f.lookups == 1)
        }
        do {
            let f = Fixture(), session = f.channel.open()
            defer { f.broker.stop() }
            _ = await f.command(session, operation: "hello")
            f.holdLookup = true
            f.channel.onRequest(f.packet(session, operation: "bindWindow", fields: ["capture": f.capture, "controlEnabled": true, "activate": true]), session)
            await f.until { f.gate != nil }
            session.close(); f.gate!.resume(); f.gate = nil
            for _ in 0..<20 { await Task.yield() }
            check(f.window.focusCalls == 0 && f.injector.posts == 0)
        }
        do {
            let f = Fixture(), session = f.channel.open()
            defer { f.broker.stop() }
            _ = await f.command(session, operation: "hello"); _ = await f.bind(session)
            var fields = f.scope(session); fields["videoEpoch"] = UUID().uuidString
            fields["event"] = try! JSONSerialization.jsonObject(with: Wire.encode(InputEvent.text("no")))
            let stale = await f.command(session, operation: "input", fields: fields)
            check(stale["code"] as? String == "stale_lease" && f.injector.posts == 0)
            _ = await f.input(session, event: .pointer(.leftDown, x: 0.5, y: 0.5))
            session.close()
            check(f.injector.held.isEmpty && f.injector.cleanup.count == 1)
        }
        print("PASS \(checks) actual Cursor broker checks; peer, window and CGEvent boundaries are inert")
    }
}
