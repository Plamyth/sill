import Foundation
import StreamProtocol

@MainActor final class Peer {
    let id: AudioForwardingDeviceID
    let generation = UUID(), connection = UUID()
    var live = true
    init(_ byte: String) { id = AudioForwardingDeviceID(hex: String(repeating: byte, count: 32))! }
    var context: AudioForwardingConnectionContext {
        .init(peer: .init(id: id, pairingGeneration: generation),
            principal: .init(kind: .tailnet, id: id, authorizationGeneration: generation), role: .controlOnly,
            connectionID: connection, connectionIsCurrent: { [weak self] in self?.live == true },
            isCurrent: { [weak self] in self?.live == true })
    }
}
@MainActor final class Fixture {
    let folder: URL
    let registry = LocalAudioParticipantRegistry()
    lazy var privacy = HostAudioPrivacy(registry)
    let sentry = HostSentry()
    var children: [Process] = []
    var count = 0, fences = 0
    var replacementFails = false
    var nativeReceipt: LocalAudioParticipantReceipt?
    lazy var relay = makeRelay()
    lazy var runtime: HostAudioForwardingRuntime = {
        #if LEGACY_SENTRY_RUNTIME
        return HostAudioForwardingRuntime(relay: relay, privacy: privacy, sentry: sentry,
            replacement: { [unowned self] in
                if replacementFails { throw CocoaError(.fileReadUnknown) }
                return makeRelay()
            }, fenceMedia: { [unowned self] in fences += 1 }, commitMedia: { _ in })
        #else
        return HostAudioForwardingRuntime(relay: relay, privacy: privacy,
        replacement: { [unowned self] in
            if replacementFails { throw CocoaError(.fileReadUnknown) }
            return makeRelay()
        }, fenceMedia: { [unowned self] in fences += 1 }, commitMedia: { _ in })
        #endif
    }()
    init(_ name: String) throws {
        folder = URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        registry.register(.native, bootId: UUID(), control: .init(fenceAndQuiesce: { [weak self] request in
            let receipt = Self.receipt(request); self?.nativeReceipt = receipt; return receipt
        }, inspect: { [weak self] id in
            guard self?.nativeReceipt?.operationId == id else { return nil }; return self?.nativeReceipt
        }, supportsForwarding: true, forwardingPrepare: { [weak self] preparation in
            let receipt = Self.receipt(preparation.request); self?.nativeReceipt = receipt; return receipt
        }))
    }
    static func receipt(_ request: LocalAudioParticipantRequest) -> LocalAudioParticipantReceipt {
        .init(request, state: .quiescent, facts: .init(admissionFenced: true, startsSettled: true,
            mediaDetached: true, callbacksDrained: true, buffersEmpty: true, workersExited: true))
    }
    func makeRelay() -> LocalAudioRelay {
        count += 1
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        process.arguments = [CommandLine.arguments[2], CommandLine.arguments[4], folder.path, String(count)]
        children.append(process)
        return LocalAudioRelay(participants: registry, process: process,
            packagedRuntime: .init(python: "inert-python", router: "inert-router", port: 0), forwarding: true,
            validateLaunch: { true })
    }
    func info(_ index: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("child-\(index).json")))) as? [String: Any] ?? [:]
    }
    func http(_ path: String, child: Int = 1) async -> (Int, Data) {
        guard let port = info(child)["port"] as? Int,
              let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return (0, Data()) }
        var request = URLRequest(url: url); request.timeoutInterval = 1
        do { let (data, response) = try await URLSession.shared.data(for: request); return ((response as? HTTPURLResponse)?.statusCode ?? 0, data) }
        catch { return (0, Data()) }
    }
    func events(_ index: Int) -> String { (try? String(contentsOf: folder.appendingPathComponent("child-\(index).jsonl"), encoding: .utf8)) ?? "" }
    func observe(_ peer: Peer) async -> AudioForwardingBootstrap? {
        let request = try! AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil)
        return await runtime.exchange(request, context: peer.context)?.catalog?.bootstrap
    }
    func finish() async {
        runtime.stop()
        for child in children {
            let until = ContinuousClock.now.advanced(by: .seconds(7))
            while child.isRunning, ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(10)) }
            precondition(!child.isRunning, "소유 테스트 자식 종료")
        }
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ value: Bool) { precondition(value); assertions += 1 }
        if CommandLine.arguments.contains("--http-first") {
            let f = try Fixture("http-first"), peer = Peer("cd")
            f.privacy.latched = false
            check(await f.runtime.start())
            let bootstrap = await f.observe(peer)!
            check(f.privacy.arms == 0)
            let request = try AudioForwardingIntentRequest(pairedDeviceId: peer.id, intentId: UUID(),
                intentRevision: .init(bootstrap.ownCursor.intentRevision.value + 1), action: .request,
                inputDesired: true, outputDesired: true, expectedRevision: bootstrap.snapshot.revision,
                transportId: UUID(), transportKind: .native,
                bindingRevision: .init(bootstrap.ownCursor.bindingRevision.value + 1))
            let body = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
            let encoded = body.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            check((await f.http("/request?id=" + peer.id.hex + "&intent=" + encoded)).0 == 200)
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while !f.runtime.allows(Data(repeating: 0xcd, count: 32), direction: .input), ContinuousClock.now < deadline {
                await f.runtime.checkRefresh()
                try? await Task.sleep(for: .milliseconds(500))
                check((await f.http("/request?id=" + peer.id.hex + "&intent=" + encoded)).0 == 200)
            }
            let allowed = f.runtime.allows(Data(repeating: 0xcd, count: 32), direction: .input)
            let arms = f.privacy.arms
            await f.finish()
            print("FIRST_HTTP active=\(allowed) arms=\(arms) (expected active=true arms=1)")
            precondition(allowed && arms == 1, "첫 HTTP 요청은 보호 세대 동기화 후 한 번에 활성화되어야 합니다")
            return
        }
        if CommandLine.arguments.contains("--observe-only") {
            let f = try Fixture("observe-only")
            var failures: [String] = []
            var observations: [[String: Any]] = []
            func verify(_ value: Bool, _ label: String) {
                assertions += 1
                if !value { failures.append(label) }
            }
            f.privacy.latched = false
            verify(await f.runtime.start(), "runtime_start")
            let startArms = f.privacy.arms
            verify(startArms == 0 && !f.privacy.latched, "start_audio_isolation_arms")
            for byte in ["ab", "cd", "ab"] {
                let peer = Peer(byte)
                let value = await f.observe(peer)
                verify(value != nil && value?.snapshot.intent == nil && value?.snapshot.binding == nil,
                       "observe_empty_intent_binding")
                verify(f.privacy.arms == 0 && !f.privacy.latched, "observe_audio_isolation_arms")
                observations.append(["bootstrapPresent": value != nil, "intentNil": value?.snapshot.intent == nil,
                    "bindingNil": value?.snapshot.binding == nil, "arms": f.privacy.arms, "latched": f.privacy.latched])
            }
            await f.finish()
            let report: [String: Any] = ["assertions": assertions, "startArms": startArms,
                "observations": observations, "failures": failures]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("OBSERVE_RESULT=" + String(decoding: data, as: UTF8.self))
            print("\(failures.isEmpty ? "PASS" : "FAIL") 화면 전용 관측의 오디오 격리 호출 0 검사: \(assertions)개")
            exit(failures.isEmpty ? 0 : 1)
        }
        func wait(_ label: String, _ condition: () -> Bool) async {
            let until = ContinuousClock.now.advanced(by: .seconds(6))
            while !condition(), ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(5)) }
            precondition(condition(), "검사 경계 시간 초과: \(label)")
        }
        for fail in [false, true] {
            let f = try Fixture(fail ? "failed-recovery" : "recover"), a = Peer("ab"), b = Peer("cd")
            check(await f.runtime.start())
            let initial = await f.observe(b)!
            let intentID = UUID()
            let request = try AudioForwardingIntentRequest(pairedDeviceId: b.id, intentId: intentID,
                intentRevision: .init(initial.ownCursor.intentRevision.value + 1), action: .request,
                inputDesired: true, outputDesired: true, expectedRevision: initial.snapshot.revision,
                transportId: UUID(), transportKind: .native, bindingRevision: .init(initial.ownCursor.bindingRevision.value + 1))
            check(await f.runtime.exchange(try .init(requestID: UUID(), operation: .submit, intent: request), context: b.context) != nil)
            await wait("initial B native binding") { f.runtime.allows(Data(repeating: 0xcd, count: 32), direction: .input) }
            let savedJournal = try JSONSerialization.jsonObject(with: Data(contentsOf: f.folder.appendingPathComponent("journal.json"))) as! [String: Any]
            let savedIntent = savedJournal["intent"] as! NSDictionary
            let key = try Data(contentsOf: f.folder.appendingPathComponent("fixture-key"))
            let boot = f.registry.snapshot.boots[.relay]
            check((await f.http("/probe?id=" + b.id.hex)).0 == 200)
            _ = await f.http("/arm?method=forwardingEvidence")
            let pending = Task { await f.observe(a) }
            await wait("delayed child response") { f.events(1).contains("\"held\":\"forwardingEvidence\"") }
            check((await f.http("/probe?id=" + a.id.hex)).0 == 200)
            f.replacementFails = fail
            a.live = false; f.runtime.disconnected(a.connection)
            check(await pending.value == nil)
            await wait("old controller exit") { !f.children[0].isRunning }
            check((await f.http("/probe?id=" + a.id.hex)).0 != 200)
            check(f.events(1).contains("workerExited"))
            if !fail {
                await wait("one replacement with B session") { f.count == 2 && f.runtime.checkSessionCount == 1 }
                check(f.registry.snapshot.boots[.relay] != boot)
                check((await f.http("/probe?id=" + b.id.hex, child: 2)).0 == 200)
                check((await f.http("/probe?id=" + a.id.hex, child: 2)).0 == 403)
                check(f.info(1)["pid"] as? Int != f.info(2)["pid"] as? Int)
                check(b.live && f.fences > 0)
                check(!f.runtime.allows(Data(repeating: 0xcd, count: 32), direction: .input))
                let renewed = await f.observe(b)!
                let resume = try AudioForwardingIntentRequest(pairedDeviceId: b.id, intentId: intentID,
                    intentRevision: renewed.ownCursor.intentRevision, action: .resume,
                    inputDesired: true, outputDesired: true, expectedRevision: renewed.snapshot.revision,
                    transportId: UUID(), transportKind: .native,
                    bindingRevision: .init(renewed.ownCursor.bindingRevision.value + 1))
                check(await f.runtime.exchange(try .init(requestID: UUID(), operation: .submit, intent: resume), context: b.context) != nil)
                await wait("B resumes after new quiesce and proof") {
                    f.runtime.allows(Data(repeating: 0xcd, count: 32), direction: .input)
                }
            } else {
                await wait("recovery fails closed") { f.runtime.checkRecoveryBlocked }
                for _ in 0..<3 { await f.runtime.checkRefresh() }
                check(f.count == 1 && f.runtime.checkSessionCount == 0)
            }
            check(try Data(contentsOf: f.folder.appendingPathComponent("fixture-key")) == key)
            let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: f.folder.appendingPathComponent("journal.json"))) as! [String: Any]
            check((journal["intent"] as! NSDictionary).isEqual(to: savedIntent as! [AnyHashable: Any]))
            check(!f.runtime.allows(Data(repeating: 0xab, count: 32), direction: .input))
            await f.finish()
        }
        for method in ["forwardingBootstrap", "forwardingSnapshot"] {
            let f = try Fixture("queued-" + method), a = Peer("ab"), b = Peer("cd")
            check(await f.runtime.start()); check(await f.observe(b) != nil)
            _ = await f.http("/arm?method=" + method)
            let pending = Task { method == "forwardingBootstrap" ? await f.observe(a) : nil }
            let held = method == "forwardingSnapshot" ? Task { await f.relay.forwardingSnapshot() } : nil
            await wait("delayed child response") { f.events(1).contains("\"held\":\"\(method)\"") }
            let renewing = Task { await f.runtime.checkRefresh() }
            await Task.yield()
            f.privacy.forwardingIntentAllowed = false; f.runtime.evidenceWillChange()
            let returning = Task { await f.runtime.returnToLocal(admission: { true }) }
            _ = await f.http("/release")
            _ = await pending.value; _ = await held?.value; await renewing.value
            check(await returning.value)
            check((await f.http("/probe?id=" + b.id.hex)).0 == 403)
            check((await f.http("/probe?id=" + a.id.hex)).0 == 403)
            check(!f.events(1).contains("\"operation\":\"renew\""))
            check(f.count == 1)
            await f.finish()
        }
        print("실제 Swift 연결 수명주기·Node 권한 원장·비공개 파이프·격리 HTTP 검사 \(assertions)개 통과. 실제 기기·HAL·오디오는 비활성 경계입니다.")
    }
}
