import Foundation
import StreamProtocol

enum RuntimeFixtureFailure: Error { case unexpectedFactory }

@MainActor
enum LocalAudioRelayLaunch {
    static var directory: URL?
    static var child: URL?
    static var lastRelay: LocalAudioRelay?
    static var launches = 0

    static func validateInstalledRuntime() throws -> Int { 0 }
    static func requireLaunchSupport(_ inventory: Int) throws {}

    static func makeForwardingRelay(participants: LocalAudioParticipantRegistry) throws -> LocalAudioRelay {
        guard let directory, let child else { throw RuntimeFixtureFailure.unexpectedFactory }
        launches += 1
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [child.path, directory.path]
        process.environment = ["PYTHONDONTWRITEBYTECODE": "1", "PATH": "/usr/bin:/bin"]
        let relay = LocalAudioRelay(participants: participants, process: process,
            packagedRuntime: .init(python: "inert-python", router: "inert-router", port: 0),
            forwarding: true, validateLaunch: { true })
        lastRelay = relay
        return relay
    }
}

@MainActor
final class NativeGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class Connection {
    let id = UUID()
    let peer: AudioForwardingPairedDevice
    var alive = true
    var requestCurrent = true
    var role = AudioForwardingCatalog.Role.controlOnly
    init(device: String = "a", peer: AudioForwardingPairedDevice? = nil) {
        self.peer = peer ?? runtimeFixturePeer(id: AudioForwardingDeviceID(hex: String(repeating: device, count: 64))!, generation: UUID())
    }
    var context: AudioForwardingConnectionContext {
        .init(peer: peer, principal: .init(kind: .tailnet, id: peer.id, authorizationGeneration: peer.pairingGeneration),
            role: role, connectionID: id, connectionIsCurrent: { self.alive },
            isCurrent: { self.alive && self.requestCurrent })
    }
}

@MainActor
final class Fixture {
    let directory: URL
    let hal = FakeHAL()
    let startup = NativeAudioStartup()
    let admission = SentryAdmission()
    var privacy: HostAudioPrivacy!
    var sentry: HostSentry!
    var runtime: HostAudioForwardingRuntime!
    var gate: NativeGate?
    var surfaceGood = true
    var surfaceReads = 0
    var nativeStops = 0
    var protectionPreparations = 0

    init(root: URL) throws {
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        privacy = HostAudioPrivacy(hal: hal, saveLocal: { _ in true }, nativeStartup: startup)
        startup.construct { () }
        startup.revoke = { [weak self] in
            guard let self else { return false }
            self.nativeStops += 1
            if let gate = self.gate { await gate.wait() }
            return true
        }
        startup.readFacts = { [weak self] in
            .init(admissionFenced: self?.startup.participants.isFenced, startsSettled: true,
                mediaDetached: true, callbacksDrained: true, buffersEmpty: true, workersExited: true)
        }
        sentry = HostSentry(admission: admission, initiallyLatched: true, persistenceHealthy: true,
            persist: { _ in true }, surfaces: .init(engage: { true }, verify: { [weak self] in
                guard let self else { return false }
                self.surfaceReads += 1
                return self.surfaceGood
            }, release: { false }, reason: { nil }), audioReady: { [weak self] in
                self?.privacy.forwardingHealth() == true
            }, localReturnUnavailableReason: { nil })
        runtime = HostAudioForwardingRuntime(privacy: privacy, sentry: sentry, prepareProtection: { [weak self] in
            guard let self else { return false }
            self.protectionPreparations += 1
            self.admission.requireProtection()
            let audio = self.privacy.latched ? (self.privacy.forwardingHealth() || self.privacy.reconcile()) : self.privacy.armAndVerify()
            return audio && self.sentry.activate()
        })
        privacy.forwardingInvalidated = { [weak self] in self?.runtime.invalidateProtection() }
    }

    func start(arm: Bool = true) async throws {
        LocalAudioRelayLaunch.directory = directory
        await runtime.start()
        if arm {
            precondition(privacy.armAndVerify(), "합성 HAL의 실제 privacy 모델 보호 초기화")
            precondition(sentry.reconcile(), "합성 표면의 실제 sentry 모델 보호 초기화")
            await until { self.count("forwardingConfigure") >= 2 }
        }
        try await Task.sleep(for: .milliseconds(30))
    }

    func flag(_ name: String) { try! Data().write(to: directory.appendingPathComponent(name)) }

    func events() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("events.jsonl")),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    func count(_ method: String, operation: String? = nil, id: UUID? = nil) -> Int {
        events().filter {
            $0["method"] as? String == method &&
            (operation == nil || $0["operation"] as? String == operation) &&
            (id == nil || ($0["connectionID"] as? String)?.lowercased() == id?.uuidString.lowercased())
        }.count
    }

    func observe(_ connection: Connection) async -> AudioForwardingState? {
        await runtime.handle(try! .init(requestID: UUID(), operation: .observe, intent: nil), context: connection.context)
    }

    func submit(_ connection: Connection, off: Bool = false) async -> AudioForwardingState? {
        let request = try! AudioForwardingIntentRequest(pairedDeviceId: connection.peer.id, intentId: UUID(),
            intentRevision: .init(1), action: off ? .stop : .request, inputDesired: !off, outputDesired: !off,
            expectedRevision: .init(0), transportId: UUID(), transportKind: .native, bindingRevision: .init(1))
        return await runtime.handle(try! .init(requestID: UUID(), operation: .submit, intent: request), context: connection.context)
    }

    func close(_ connection: Connection) {
        connection.alive = false
        runtime.connectionClosed(connection.id)
    }

    func finish() {
        gate?.release()
        runtime.stop()
        privacy.stop()
    }

    func until(seconds: Double = 2, _ condition: @escaping () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        precondition(condition(), "격리 fixture 대기 조건을 충족하지 못했습니다.")
    }
}
