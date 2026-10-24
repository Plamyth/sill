import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0
        var failures = 0
        func expect(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("FAIL \(label)") }
        }
        let list = try JSONDecoder().decode(WindowList.self, from:Data("""
        {"selectionRevision":"revision-0","launchID":"host","macName":"fixture","windows":[{"id":1001,"title":"old","appName":"fixture","bundleID":"test","width":600,"height":400}],"active":{"none":{}}}
        """.utf8))
        for choice in ["window","display","launch","none"] {
            let client = Client()
            client.resumeSource = .window(1001)
            client.beginAutomaticConnectionOpportunity(peer: client.connection)
            switch choice {
            case "window": client.select(.window(1002))
            case "display": client.selectDisplay(client.displays[0])
            case "launch": client.launch(bundleID:"test.new")
            default: client.select(.none)
            }
            let audioBeforeCatalog = client.remoteAudioControl.changes
            client.deliverIdleCatalog(list)
            expect(client.remoteAudioControl.changes == audioBeforeCatalog, "refused stale restoration has no audio teardown")
            let picks = client.allSent.filter { $0.0 == .selectSource }.compactMap { Wire.decode(StreamSource.self,from:$0.1) }
            expect(!picks.contains(.window(1001)), "delayed handover catalog cannot restore old window after explicit \(choice)")
        }
        let reconnect = Client()
        reconnect.resumeSource = .window(1001)
        reconnect.beginAutomaticConnectionOpportunity(peer: reconnect.connection)
        reconnect.deliverIdleCatalog(list)
        expect(reconnect.allSent.contains { $0.0 == .selectSource && Wire.decode(StreamSource.self,from:$0.1) == .window(1001) },
               "idle handover with no newer explicit choice still restores its window")
        let missing = Client()
        missing.resumeSource = .window(999)
        missing.beginAutomaticConnectionOpportunity(peer: missing.connection)
        missing.deliverIdleCatalog(list)
        expect(missing.allSent.contains { $0.0 == .selectSource && Wire.decode(StreamSource.self,from:$0.1) == .desktop },
               "missing restored window retains Desktop fallback")
        let idle = Client()
        idle.active = .none
        idle.deliverIdleCatalog(list)
        expect(idle.allSent.count == 1, "genuine first idle catalog sends once")
        idle.deliverIdleCatalog(list)
        expect(idle.allSent.count == 1, "fresh catalog does not rebase a consumed automatic ticket")
        let cancelled = Client()
        cancelled.active = .none
        let ticket = cancelled.automaticTicket(peer: cancelled.connection!, list: list)!
        cancelled.select(.none)
        cancelled.deliverIdleCatalog(list)
        cancelled.requestAutomatic(.desktop, ticket: ticket)
        expect(cancelled.allSent.count == 1, "explicit None prevents first-idle and delayed ticket rebasing")
        let replaced = Client()
        let oldTicket = replaced.automaticTicket(peer: replaced.connection!, list: list)!
        replaced.connection = NWConnection()
        replaced.sessionHost = list.launchID
        replaced.requestAutomatic(.desktop, ticket: oldTicket)
        expect(replaced.allSent.isEmpty && replaced.remoteAudioControl.changes == 0, "old peer ticket cannot send or tear down audio")
        let succeeded = Client()
        succeeded.select(.window(1001))
        var streaming = list
        streaming.active = .window(1001)
        streaming.selectionRevision = "revision-1"
        streaming.videoEpoch = VideoEpoch(generation: "input-1", source: .window(1001), geometry: .init(x:0,y:0,width:640,height:480), width:640, height:480)
        succeeded.deliverIdleCatalog(streaming)
        expect(succeeded.automaticSourceIntent == succeeded.explicitSourceIntent, "successful explicit source enables a new closed-window recovery opportunity")
        let pendingSame = Client()
        pendingSame.sourceCatalogEpoch = streaming.videoEpoch?.id
        pendingSame.select(.window(1001))
        pendingSame.deliverIdleCatalog(streaming)
        expect(pendingSame.automaticSourceIntent == nil, "changed admission revision with an old epoch cannot acknowledge a pending same-source pick")
        let failed = Client()
        failed.select(.window(999))
        var laterIdle = list
        laterIdle.selectionRevision = "revision-1"
        failed.deliverIdleCatalog(laterIdle)
        expect(failed.allSent.count == 1 && failed.automaticSourceIntent == nil, "failed source remains ineligible on a fresh idle revision")
        let staleAck = Client()
        staleAck.select(.window(1001))
        var staleStreaming = list
        staleStreaming.active = .window(1001)
        staleAck.deliverIdleCatalog(staleStreaming)
        expect(staleAck.automaticSourceIntent == nil, "pre-intent streaming catalog cannot acknowledge a same-source human pick")
        let closing = Client()
        closing.active = .window(1001)
        var closed = list
        closed.windows = []
        closing.deliverIdleCatalog(closed)
        var newerClosed = closed
        newerClosed.selectionRevision = "revision-99"
        closing.deliverIdleCatalog(newerClosed)
        expect(closing.allSent.isEmpty, "a second idle catalog cannot bypass the closed-window delay")
        try await Task.sleep(for: .milliseconds(2200))
        let automatic = closing.allSent.compactMap { Wire.decode(SourceRequest.self, from: $0.1) }
        expect(automatic.isEmpty && closing.scheduledAutomaticTicket?.revision == list.selectionRevision,
               "real delayed fallback refuses a known stale revision without rebase")
        let refusedDisplay = Client()
        refusedDisplay.displaySelectionReady = false
        refusedDisplay.selectDisplay(refusedDisplay.displays[0])
        refusedDisplay.beginAutomaticConnectionOpportunity()
        refusedDisplay.deliverIdleCatalog(list)
        expect(refusedDisplay.allSent.isEmpty, "local monitor refusal cannot revive automatic intent at handover")
        cancelled.beginAutomaticConnectionOpportunity()
        cancelled.deliverIdleCatalog(laterIdle)
        expect(cancelled.allSent.count == 1, "handover cannot recreate automatic eligibility from a pending explicit None")
        failed.beginAutomaticConnectionOpportunity()
        failed.deliverIdleCatalog(laterIdle)
        expect(failed.allSent.count == 1, "handover cannot recreate a failed explicit choice from stale active state")
        await automaticDisplayChecks(expect)
        sourceSelectionAdmissionChecks(expect)
        print("SOURCE_REQUEST_CLIENT_CHECKS total=\(checks) failed=\(failures)")
        if failures > 0 { exit(1) }
    }
}
