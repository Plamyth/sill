import Foundation

@main struct ExtendedDisplayChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ label: String) {
            checks += 1
            precondition(value, label)
        }
        func settle() async { for _ in 0..<100 { await Task.yield() } }
        let main = DisplayInfo(id: 1, name: "iPad 확장 화면", width: 1920, height: 1080, isMain: true)
        let owned = DisplayInfo(id: 42, name: "임의 이름", width: 1366, height: 1024,
                                isMain: false, role: "ipadExtendedDesktop")
        let second = DisplayInfo(id: 43, name: "두 번째", width: 1366, height: 1024,
                                 isMain: false, role: "ipadExtendedDesktop")
        let native = Viewport.ExtendedDesktopSize(width: 1366, height: 1024)!
        func viewport(_ intent: Viewport.ExtendedDesktopIntent? = nil) -> Viewport {
            Viewport(width: 900, height: 600, scale: 1, localCursor: true, fps: 60,
                     extendedDesktop: native, extendedDesktopIntent: intent)
        }
        func catalog(_ cap: Int? = 1, displays: [DisplayInfo]? = nil, launch: String = "host",
                     inventory: UUID = UUID()) -> WindowList {
            WindowList(macName: "fixture", windows: [], active: .none, launchID: launch,
                displaySelection: 1, displays: displays ?? [main], displayInventoryID: inventory,
                extendedDesktopControl: cap)
        }
        func client(_ cap: Int? = 1, displays: [DisplayInfo]? = nil) -> Client {
            let client = Client()
            client.prepareAutomaticTicketCatalog(catalog(cap, displays: displays))
            client.lastViewport = viewport()
            return client
        }
        func viewports(_ peer: NWConnection) -> [Viewport] {
            peer.packets.compactMap { data in
                guard data.first == StreamMessageKind.viewport.rawValue else { return nil }
                return Wire.decode(Viewport.self, from: Data(data.dropFirst(StreamMessage.headerLength)))
            }
        }
        func intents(_ peer: NWConnection) -> [Viewport.ExtendedDesktopIntent] {
            viewports(peer).compactMap(\.extendedDesktopIntent)
        }
        func selections(_ peer: NWConnection) -> [DisplaySelection] {
            peer.packets.compactMap { data in
                guard data.first == StreamMessageKind.selectDisplay.rawValue else { return nil }
                return Wire.decode(DisplaySelection.self, from: Data(data.dropFirst(StreamMessage.headerLength)))
            }
        }
        func choose(_ client: Client) { ButtonFixture(client: client).selectExtendedDisplay() }

        let fresh = client()
        let peer = fresh.connection!
        expect(intents(peer).isEmpty, "버튼 전에는 생성 요청이 없어야 합니다.")
        expect(fresh.canSelectIPadExtendedDesktop, "cap1이면 role이 없어도 요청할 수 있어야 합니다.")
        choose(fresh)
        for _ in 0..<10 { choose(fresh) }
        expect(intents(peer) == [.request] && selections(peer).isEmpty, "반복 클릭은 진행 중 요청 하나여야 합니다.")
        expect(fresh.lastViewport?.extendedDesktopIntent == nil, "자원 신호를 lastViewport에 저장하면 안 됩니다.")
        expect(fresh.remoteAudioControl.changes == 0 && fresh.microphoneChanges == 0,
               "생성 요청은 오디오·마이크 상태를 바꾸면 안 됩니다.")
        fresh.prepareAutomaticTicketCatalog(catalog())
        expect(selections(peer).isEmpty, "role 없는 목록은 선택을 만들면 안 됩니다.")
        let inventory = UUID()
        let replacement = DisplayInfo(id: 90, name: "새 목록", width: 1366, height: 1024,
                                      isMain: false, role: "ipadExtendedDesktop")
        let arrived = catalog(displays: [main, replacement], inventory: inventory)
        fresh.prepareAutomaticTicketCatalog(arrived)
        fresh.prepareAutomaticTicketCatalog(arrived)
        await settle()
        let selected = selections(peer)
        expect(selected.count == 1 && selected[0].displayID == 90 && selected[0].inventoryID == inventory,
               "새 inventory의 현재 ID로 한 번 선택해야 합니다.")
        expect(selected[0].origin != .automatic && fresh.expectedSourceIntent?.origin == .human,
               "지연된 버튼 선택도 human 경로여야 합니다.")
        expect(!fresh.extendedDesktopRequestPending && intents(peer) == [.request], "선택 뒤 요청을 재생성하면 안 됩니다.")

        let joined = client(displays: [main, owned])
        let jp = joined.connection!
        choose(joined)
        choose(joined)
        expect(intents(jp) == [.request] && selections(jp).count == 1,
               "다른 iPad의 role이 보여도 자기 peer로 가입한 뒤 바로 한 번 선택해야 합니다.")
        expect(jp.packets.map { $0.first! } == [StreamMessageKind.viewport.rawValue, StreamMessageKind.selectDisplay.rawValue],
               "가입 패킷이 선택보다 먼저 나가야 합니다.")
        await settle()

        for cap: Int? in [nil, 2] {
            let unsupported = client(cap)
            choose(unsupported)
            expect(intents(unsupported.connection!).isEmpty && selections(unsupported.connection!).isEmpty,
                   "nil과 미래 capability를 지원으로 추정하면 안 됩니다.")
            let existing = client(cap, displays: [owned])
            choose(existing)
            expect(intents(existing.connection!).isEmpty && selections(existing.connection!).count == 1,
                   "구형 Host의 기존 role 선택은 자원 요청 없이 유지해야 합니다.")
        }
        let unknown = DisplayInfo(id: 7, name: "iPad 확장 화면", width: 800, height: 600,
                                  isMain: false, role: "IPadExtendedDesktop")
        expect(IPadExtendedDisplaySelection.candidate(displays: [main, unknown], ready: true) == nil,
               "이름이나 비슷한 role로 추정하면 안 됩니다.")
        for displays in [[owned, second], [owned, owned], [owned, main, main]] {
            let bad = client(displays: displays)
            choose(bad)
            expect(intents(bad.connection!).isEmpty && selections(bad.connection!).isEmpty,
                   "중복 role과 전체 ID 중복은 요청·선택을 거부해야 합니다.")
            let waiting = client()
            choose(waiting)
            waiting.prepareAutomaticTicketCatalog(catalog(displays: displays))
            waiting.prepareAutomaticTicketCatalog(catalog(displays: [owned]))
            expect(!waiting.extendedDesktopRequestPending && selections(waiting.connection!).isEmpty,
                   "모호한 catalog 뒤 늦은 정상 목록으로 이전 요청을 살리면 안 됩니다.")
        }
        for badGeometry in [Viewport(width: .nan, height: 600, scale: 1, extendedDesktop: native),
                            Viewport(width: 900, height: 0, scale: 1, extendedDesktop: native),
                            Viewport(width: 900, height: 600, scale: 1)] {
            let invalid = client()
            invalid.lastViewport = badGeometry
            choose(invalid)
            expect(intents(invalid.connection!).isEmpty, "잘못된 geometry로 자원 요청을 보내면 안 됩니다.")
        }
        expect(Viewport.ExtendedDesktopSize(width: 0, height: 0) == nil &&
               Viewport.ExtendedDesktopSize(width: .infinity, height: 1024) == nil,
               "기존 native geometry 검증을 유지해야 합니다.")

        for action in ["window", "display", "launch", "none", "release"] {
            let held = client(displays: [main, owned])
            let hp = held.connection!
            _ = held.link.hold(hp)
            choose(held)
            expect(hp.packets.isEmpty && held.extendedDesktopRequestPending,
                   "실제 SessionLink hold가 생성과 후속 선택을 보류해야 합니다.")
            switch action {
            case "window": held.select(.window(1002))
            case "display": held.selectDisplay(main)
            case "launch": held.launch(bundleID: "test.new")
            case "none": held.select(.none)
            default: held.cancelExtendedDesktopRequest()
            }
            _ = held.link.unhold(hp)
            expect(!intents(hp).contains(.request) && selections(hp).allSatisfy { $0.displayID == main.id },
                   "다른 명시 의도 뒤 보류된 생성·확장 선택이 나가면 안 됩니다.")
            expect(intents(hp) == [.release], "취소는 자기 peer에만 해제해야 합니다.")
            held.prepareAutomaticTicketCatalog(catalog(displays: [owned]))
            await settle()
            expect(selections(hp).allSatisfy { $0.displayID == main.id }, "늦은 목록은 취소한 의도를 복원하면 안 됩니다.")
        }
        for hasRole in [false, true] {
            let moving = client(displays: hasRole ? [main, owned] : [main])
            let old = moving.connection!
            let next = NWConnection()
            _ = moving.link.hold(old)
            choose(moving)
            moving.link.handOver(from: old, to: next, fencePing: Data([255]), nonce: Data([9]))
            _ = moving.link.unhold(old)
            _ = moving.link.fenceReturned(Data([9]), on: old)
            moving.cancelExtendedDesktopRequest()
            expect(intents(old).isEmpty && intents(next).isEmpty && selections(next).isEmpty,
                   "hold→handover→unhold는 자원 신호·선택·해제를 새 peer로 보내면 안 됩니다.")
            moving.prepareAutomaticTicketCatalog(catalog(displays: [owned]))
            expect(intents(next).isEmpty && selections(next).isEmpty, "새 peer의 늦은 catalog가 의도를 재생성하면 안 됩니다.")
        }
        let stale = client()
        let stalePeer = stale.connection!
        choose(stale)
        stale.connection = NWConnection()
        stale.observeExtendedDesktopCatalog(catalog(displays: [owned]), peer: stalePeer)
        expect(selections(stalePeer).isEmpty && selections(stale.connection!).isEmpty,
               "오래된 peer의 catalog callback은 선택을 만들면 안 됩니다.")
        stale.beginAutomaticConnectionOpportunity(peer: stale.connection)
        stale.prepareAutomaticTicketCatalog(catalog(displays: [owned]))
        expect(intents(stale.connection!).isEmpty && selections(stale.connection!).isEmpty,
               "새 연결의 role이 이전 버튼 의도를 되살리면 안 됩니다.")
        let queued = client(displays: [owned])
        let qp = queued.connection!
        _ = queued.link.hold(qp)
        choose(queued)
        queued.displays = [owned, second]
        _ = queued.link.unhold(qp)
        await settle()
        expect(selections(qp).isEmpty, "실제 송신 직전에 role 유일성을 재검사해야 합니다.")

        for change in ["host", "mac", "trust", "cap", "deadline"] {
            let held = client()
            let hp = held.connection!
            _ = held.link.hold(hp)
            choose(held)
            switch change {
            case "host": held.sessionHost = "replacement-host"
            case "mac": held.session?.macID = "replacement-mac"
            case "trust": held.savedMacs = []
            case "cap": held.extendedDesktopControl = 2
            default: held.expireExtendedDesktopRequest(now: held.pendingExtendedDesktop!.deadline)
            }
            _ = held.link.unhold(hp)
            await settle()
            expect(!intents(hp).contains(.request), "실제 송신 시점에 신뢰·Host·cap·deadline을 재검사해야 합니다.")
        }
        let releaseHeld = client()
        let rp = releaseHeld.connection!
        choose(releaseHeld)
        _ = releaseHeld.link.hold(rp)
        releaseHeld.cancelExtendedDesktopRequest()
        let nextReleasePeer = NWConnection()
        releaseHeld.link.handOver(from: rp, to: nextReleasePeer, fencePing: Data([255]), nonce: Data([10]))
        _ = releaseHeld.link.unhold(rp)
        _ = releaseHeld.link.fenceReturned(Data([10]), on: rp)
        expect(intents(nextReleasePeer).isEmpty, "보류된 release도 다른 peer로 이월하면 안 됩니다.")
        let resourceOnly = client()
        choose(resourceOnly)
        resourceOnly.cancelExtendedDesktopRequest()
        expect(resourceOnly.remoteAudioControl.changes == 0 && resourceOnly.microphoneChanges == 0,
               "선택 전 request/release는 오디오·마이크 권한을 바꾸면 안 됩니다.")

        for change in ["host", "mac", "trust", "peer", "capnil", "cap2", "unready", "timeout"] {
            let waiting = client()
            let wp = waiting.connection!
            choose(waiting)
            switch change {
            case "host": waiting.prepareAutomaticTicketCatalog(catalog(displays: [owned], launch: "new-host"))
            case "mac": waiting.session?.macID = "other-mac"
            case "trust": waiting.savedMacs = []
            case "peer": waiting.connection = NWConnection()
            case "capnil": waiting.prepareAutomaticTicketCatalog(catalog(nil, displays: [owned]))
            case "cap2": waiting.prepareAutomaticTicketCatalog(catalog(2, displays: [owned]))
            case "unready": waiting.connected = false
            default: waiting.expireExtendedDesktopRequest(now: waiting.pendingExtendedDesktop!.deadline)
            }
            waiting.prepareAutomaticTicketCatalog(catalog(displays: [owned]))
            await settle()
            expect(selections(wp).isEmpty && selections(waiting.connection!).isEmpty,
                   "연결·신뢰·Host·지원·timeout 변경 뒤 이전 요청을 선택하면 안 됩니다.")
            if ["host", "mac", "trust", "peer"].contains(change) {
                expect(!intents(waiting.connection!).contains(.release), "다른 연결이나 신뢰 대상에 해제하면 안 됩니다.")
            }
        }
        let expired = client()
        choose(expired)
        expired.expireExtendedDesktopRequest(now: expired.pendingExtendedDesktop!.deadline)
        expect(expired.extendedDesktopProblem != nil && intents(expired.connection!) == [.request, .release],
               "응답 미확인은 해제와 한국어 오류를 남겨야 합니다.")

        let clean = client()
        clean.sendViewport(viewport(.request))
        clean.sendViewport(viewport(.release))
        clean.setLocalCursor(false)
        try? await Task.sleep(for: .milliseconds(250))
        expect(intents(clean.connection!).isEmpty && clean.lastViewport?.extendedDesktopIntent == nil,
               "일반 viewport·hover는 자원 신호를 nil로 정리해야 합니다.")
        choose(clean)
        let before = intents(clean.connection!)
        clean.sendViewport(Viewport(width: 700, height: 900, scale: 1))
        expect(intents(clean.connection!) == before && clean.lastViewport?.extendedDesktop == native,
               "resize는 기존 native 치수를 유지하고 request를 재발행하면 안 됩니다.")
        clean.beginAutomaticConnectionOpportunity(peer: clean.connection)
        clean.prepareAutomaticTicketCatalog(catalog())
        if let saved = clean.lastViewport { clean.sendViewport(saved) }
        expect(intents(clean.connection!) == before, "재접속 viewport가 request를 재생성하면 안 됩니다.")
        let newProcess = client()
        newProcess.sendViewport(viewport())
        expect(intents(newProcess.connection!).isEmpty && !newProcess.extendedDesktopRequestPending,
               "새 프로세스와 기본 main에서는 request가 없어야 합니다.")
        let oldJSON = Data(#"{"width":900,"height":600,"scale":1}"#.utf8)
        let decodedOld = try JSONDecoder().decode(Viewport.self, from: oldJSON)
        expect(decodedOld.extendedDesktopIntent == nil, "이전 wire의 optional 기본값은 nil이어야 합니다.")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(viewport())) as! [String: Any]
        expect(encoded["extendedDesktopIntent"] == nil, "일반 wire에 자원 intent 키를 추가하면 안 됩니다.")
        checkToolbarBounds()
        print("IPAD_EXTENDED_DISPLAY_CHECKS \(checks)개를 통과했습니다.")
    }
}
