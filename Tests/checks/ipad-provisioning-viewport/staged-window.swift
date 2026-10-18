import Foundation

typealias CGWindowID = UInt32

struct SCWindow {
    let windowID: UInt32 = 42
    let frame = CGRect(x: 0, y: 0, width: 900, height: 593)
}

@MainActor final class WindowCatalog {
    var thumbnailsWanted = false
    let item = SCWindow()
    func window(id: UInt32) -> SCWindow? { id == item.windowID ? item : nil }
    func resolveWindow(id: UInt32) async -> SCWindow? { window(id: id) }
    func refreshWindows() async {}
}

@MainActor final class VirtualStage {
    struct Placement { let windowID: UInt32 = 42 }
    struct Display { let isAlive = true }
    let placement: Placement? = Placement()
    let display: Display? = Display()
    var askedSize: CGSize? = CGSize(width: 900, height: 593)
    var isStaged = true
    var windowStillFullScreen = false
    func leaveFullScreenIfNeeded() async {}
    func release() { isStaged = false }
    static let minSide: CGFloat = 320
    static let maxSide: CGFloat = 4096
    // STAGE_GEOMETRY
}

extension Checks {
    @MainActor static func stagedWindowChecks() async {
        for kind: StreamClient.MoveKind in [.toCable, .fromRemote] {
            let screen = ScreenFixture(), client = screen.client
            screen.textScale = 1.5
            await screen.sendAndWait()
            let desktop = ExtendedDesktop(makeDisplay: { _, _ in
                .init(id: 100, waitUntilOnline: { true }, configure: {}, isValid: { true },
                      recoverWindows: {}, destroy: {})
            }, publishID: { _ in }, reportFailure: { preconditionFailure($0) })
            let host = CoordinatorFixture(desktop)
            host.viewport = client.lastViewport
            let old = client.connection!, next = client.makeConnection()
            host.connections[ObjectIdentifier(next)] = next
            desktop.request(ObjectIdentifier(next))
            next.onViewport = { host.received.append(($0, next)) }
            client.snapshotHomeViewport()
            client.session?.route = kind == .fromRemote ? .remote : .network
            client.moving = .init(connection: next, kind: kind)
            let expected = CGSize(width: 900, height: 593)
            check(VirtualStage.windowSize(for: client.lastViewport, own: .zero) == expected,
                  "actual Aa 1.5 panel stages at 900x593 before replacement")

            if kind == .fromRemote { client.sendHomePreflight(next) }
            client.completeReplacement(next, kind: kind)
            await host.drain()
            let earlyCount = kind == .fromRemote ? 1 : 0
            check(next.viewports.count == earlyCount && host.selections.isEmpty && host.audioRevocations == 0,
                  "original \(kind) sends only its ordinary home preflight before the fence")
            check(next.viewports.allSatisfy { $0.width == 1350 && $0.height == 890 && $0.scale == 1.5 },
                  "early home frame uses actual panel and Aa, never native dimensions")
            check(host.stage.askedSize == expected,
                  "early actual frame and delayed fence preserve staged geometry")
            client.send(.input, payload: Data([1]))
            check(!next.messages.contains { $0.first == StreamMessageKind.input.rawValue },
                  "input stays behind the same delayed fence")
            let released = client.link.release(old)
            await host.drain()
            for _ in 0..<60 { await Task.yield() }
            check(released?.clear == true && next.viewports.count == earlyCount + 1,
                  "fence release sends the original actual viewport replay")
            check(host.selections.isEmpty && host.audioRevocations == 0 && host.active == .window(42),
                  "full viewport handler retains selected staged window and audio after release")
            check(host.stage.askedSize == expected && host.viewport?.scale == 1.5,
                  "native allocation cannot change staged window or Aa scale")
            check(desktop.dimensions?.widthPt == 1350 && desktop.dimensions?.heightPt == 976,
                  "ordinary viewport with optional field allocates native 1350x976")
            check(next.messages.map { $0.first! } == (kind == .fromRemote ? [23, 9, 9, 8] : [23, 9, 8]),
                  "original hello, optional early home frame, fenced replay and input order")

            if let replay = client.lastViewport { client.sendViewport(replay) }
            await host.drain()
            check(host.selections.isEmpty && host.audioRevocations == 0,
                  "identical replay does not restart the selected stream")

            var changed = client.lastViewport!
            changed.height = 540
            client.sendViewport(changed)
            await host.drain()
            check(host.selections == [.window(42)] && host.audioRevocations == 1,
                  "real panel changes still use the existing restart and audio policy")
            check(host.stage.askedSize == CGSize(width: 900, height: 360)
                  && desktop.dimensions?.heightPt == 976,
                  "keyboard resizes the window while native allocation stays fixed")
            desktop.shutdown()
        }

        let screen = ScreenFixture(), client = screen.client
        screen.textScale = 1.5
        await screen.sendAndWait()
        let old = client.connection!, middle = client.makeConnection(), next = client.makeConnection()
        client.link.handOver(from: old, to: middle, fencePing: Data([10]), nonce: Data([1]))
        client.link.handOver(from: middle, to: next, fencePing: Data([10]), nonce: Data([2]))
        client.sendViewport(client.lastViewport!)
        client.send(.input, payload: Data([2]))
        check(client.link.release(middle)?.clear == false && next.viewports.isEmpty,
              "second fence release cannot bypass an earlier fence")
        check(client.link.release(old)?.clear == true && next.viewports.count == 1,
              "all fences must clear before native intent and retained input replay")
        check(next.viewports[0].height == 890 && next.viewports[0].scale == 1.5
              && next.viewports[0].extendedDesktop?.height == 976,
              "two-fence replay preserves regular geometry and native intent")

        var creates = 0
        let desktop = ExtendedDesktop(makeDisplay: { _, _ in
            creates += 1
            return .init(id: 100, waitUntilOnline: { true }, configure: {}, isValid: { true },
                         recoverWindows: {}, destroy: {})
        }, publishID: { _ in }, reportFailure: { preconditionFailure($0) })
        let host = CoordinatorFixture(desktop), connection = NWConnection()
        host.active = .desktop
        host.connections[ObjectIdentifier(connection)] = connection
        desktop.request(ObjectIdentifier(connection))
        for panel in [CGSize(width: 1350, height: 890), CGSize(width: 1350, height: 976),
                      CGSize(width: 1350, height: 540), CGSize(width: 976, height: 600)] {
            let viewport = Viewport(width: panel.width, height: panel.height, scale: 1.5, fps: 120,
                                    extendedDesktop: .init(width: 1350, height: 976))
            host.received.append((viewport, connection))
            await host.drain()
            check(host.selections.isEmpty && host.audioRevocations == 0 && host.active == .desktop,
                  "desktop full handler retains selection and audio at panel \(panel)")
            check(host.viewport?.width == panel.width && host.viewport?.height == panel.height,
                  "desktop full handler keeps actual viewport for input geometry")
        }
        check(creates == 1 && desktop.dimensions?.heightPt == 976,
              "desktop hide, keyboard and rotation keep one native allocation")
        desktop.shutdown()
    }
}
