import Foundation

extension Checks {
    @MainActor static func replacementChecks() async {
        for native in [true, false] {
            for scenario in ["cable rescue", "wifi rescue", "away rescue", "home", "cable", "wifi", "direct"] {
                let screen = ScreenFixture(), client = screen.client
                screen.textScale = 1.5
                client.localCursorState.wanted = true
                client.awayCapsFrameRate = scenario == "home" || scenario == "away rescue"
                let old = client.connection!
                var creates = 0, destroys = 0
                var expectedAllocationHeight = native ? 976 : 890
                let desktop = ExtendedDesktop(makeDisplay: { dimensions, _ in
                    creates += 1
                    check(dimensions.widthPt == 1350 && dimensions.heightPt == expectedAllocationHeight,
                          "\(scenario) native=\(native) allocates expected 1350x\(expectedAllocationHeight)")
                    return .init(id: 100, waitUntilOnline: { true }, configure: {}, isValid: { true },
                                 recoverWindows: {}, destroy: { destroys += 1 })
                }, publishID: { _ in }, reportFailure: { preconditionFailure($0) })
                let host = CoordinatorFixture(desktop)
                func admit(_ c: NWConnection) {
                    host.connections[ObjectIdentifier(c)] = c
                    desktop.request(ObjectIdentifier(c))
                    c.onViewport = { v in
                        client.sent.append(v)
                        host.updateExtendedDesktopViewport(v, from: c)
                    }
                }
                admit(old)
                if native {
                    await screen.sendAndWait()
                } else {
                    client.sendViewport(Viewport(width: 1350, height: 890, scale: 1.5,
                                                 fps: StreamClient.wantedFPS(remote: client.awayCapsFrameRate)))
                }
                for _ in 0..<60 { await Task.yield() }
                let remembered = client.lastViewport
                check(remembered?.height == 890 && remembered?.scale == 1.5,
                      "\(scenario) starts with an actual panel viewport")

                let kind: StreamClient.MoveKind
                let next: NWConnection
                switch scenario {
                case "cable rescue", "wifi rescue":
                    if scenario == "wifi rescue" { client.wired = nil }
                    check(client.rescue(from: old), "\(scenario) executes production rescue")
                    next = client.moving!.connection
                    kind = client.moving!.kind
                case "home", "away rescue":
                    kind = .fromRemote
                    next = client.makeConnection()
                    client.session?.route = .remote
                    client.moving = .init(connection: next, kind: kind)
                    client.snapshotHomeViewport()
                    if scenario == "away rescue" {
                        check(client.rescue(from: old), "away rescue executes production move-home rescue")
                    }
                default:
                    kind = scenario == "cable" ? .toCable : scenario == "wifi" ? .toWifi : .fromDirect
                    next = client.makeConnection()
                    client.connectedDirectly = kind == .fromDirect
                    client.moving = .init(connection: next, kind: kind)
                    if kind == .toWifi { _ = client.link.hold(old) }
                }
                check(client.lastViewport == remembered, "\(scenario) retains lastViewport without clearing it")

                host.connections.removeValue(forKey: ObjectIdentifier(old))
                host.extendedDesktopViewports.removeValue(forKey: ObjectIdentifier(old))
                desktop.release(ObjectIdentifier(old))
                check(destroys == 1 && desktop.displayID == nil, "\(scenario) host releases previous display")
                let home = kind == .fromRemote
                let replayHeight = home || scenario == "cable rescue" ? 890.0 : 540.0
                expectedAllocationHeight = native ? 976 : Int(replayHeight)
                admit(next)
                if kind == .fromRemote { client.sendHomePreflight(next) }
                if scenario == "cable rescue" {
                    check(client.lastViewport?.height == 890, "idle rescue retains the original 1350x890 panel")
                } else {
                    screen.panelSize.height = 540
                    await screen.sendAndWait()
                    check(client.lastViewport?.height == 540, "\(scenario) records keyboard viewport during move")
                }
                client.completeReplacement(next, kind: kind)
                _ = client.link.release(old)
                for _ in 0..<60 { await Task.yield() }
                let viewports = next.viewports
                check(next.messages.first?.first == StreamMessageKind.hello.rawValue,
                      "\(scenario) keeps hello ahead of every viewport")
                check(!viewports.isEmpty && viewports.allSatisfy {
                    $0.extendedDesktop?.height == (native ? 976 : nil) && $0.width == 1350
                    && [890.0, 540.0].contains($0.height) && $0.scale == 1.5
                }, "\(scenario) all ordinary snapshots and queued panels retain optional native intent")
                check(viewports.last?.height == replayHeight,
                      "\(scenario) retains original snapshot replay semantics")
                if home {
                    check(viewports.first?.height == 890 && client.homeMoveViewport == nil,
                          "baseline home preflight and final replay use the move-start actual panel")
                    print("BASELINE home snapshot=890 while measured panel=\(screen.panelSize.height), native=\(native), route=\(scenario)")
                }
                check(viewports.first?.localCursor == true, "\(scenario) native intent retains cursor preference")
                check(viewports.last == client.lastViewport && viewports.last?.scale == 1.5,
                      "\(scenario) replay becomes canonical with the original Aa")
                check(viewports.last?.fps == 120,
                      "\(scenario) preserves original route FPS replay behavior")
                check(creates == 2 && desktop.dimensions?.heightPt == expectedAllocationHeight,
                      "\(scenario) replacement allocation uses native intent or legacy first panel")
                desktop.shutdown()
            }
        }

        let initial = ScreenFixture()
        initial.client.awayCapsFrameRate = true
        initial.client.connected = false
        await initial.sendAndWait()
        check(initial.client.lastViewport?.extendedDesktop == nil && initial.client.sent.isEmpty,
              "initial viewport waits for admitted connected session")
        initial.client.connected = true
        initial.textScale = 0.8
        await initial.sendAndWait()
        check(initial.client.sent.count == 1 && initial.client.sent.first?.scale == 0.8
              && initial.client.lastViewport?.extendedDesktop?.height == 976,
              "first admitted send retains fractional scale alongside native intent")
        check(initial.client.sent.allSatisfy { $0.fps == 60 }, "away initial viewport keeps the 60 fps cap")
        initial.client.forgetViewport()
        check(initial.client.lastViewport?.extendedDesktop == nil && initial.client.lastViewport == nil,
              "full session teardown forgets canonical viewport and native intent")
    }
}
