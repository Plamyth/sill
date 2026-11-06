import Foundation
import StreamProtocol

struct HostConfiguredCraftExecution: Decodable {
    let operationId: UUID
    let deviceId: AudioForwardingDeviceID
    let deviceSessionId: UUID
    let bindingSha256: String
    let bundleIdentifier: String
    let keyCode: UInt16
    let modifiers: Int
    let expiresAt: Int64

    private enum CodingKeys: String, CodingKey {
        case operationId, deviceId, deviceSessionId, bindingSha256, bundleIdentifier, keyCode, modifiers, expiresAt
    }
    init(from decoder: Decoder) throws {
        try providerExactKeys(decoder, required: ["operationId", "deviceId", "deviceSessionId", "bindingSha256",
            "bundleIdentifier", "keyCode", "modifiers", "expiresAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try c.decode(String.self, forKey: .operationId)
        let session = try c.decode(String.self, forKey: .deviceSessionId)
        guard let operationId = UUID(uuidString: operation), operationId.uuidString.lowercased() == operation,
              let deviceSessionId = UUID(uuidString: session), deviceSessionId.uuidString.lowercased() == session else {
            throw ProviderCallFailure.invalidFields
        }
        self.operationId = operationId; self.deviceSessionId = deviceSessionId
        deviceId = try c.decode(AudioForwardingDeviceID.self, forKey: .deviceId)
        bindingSha256 = try c.decode(String.self, forKey: .bindingSha256)
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        modifiers = try c.decode(Int.self, forKey: .modifiers)
        expiresAt = try c.decode(Int64.self, forKey: .expiresAt)
        guard bundleIdentifier == "com.openai.codex", keyCode <= 127, (0...31).contains(modifiers),
              expiresAt > 0, expiresAt <= 9_007_199_254_740_991,
              bindingSha256.utf8.count == 64,
              bindingSha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ProviderCallFailure.invalidFields
        }
    }

    func matches(_ request: ConfiguredCraftActionRequest, session: UUID, result: ConfiguredCraftActionResult) -> Bool {
        operationId == request.operationId && deviceId == request.deviceId && deviceSessionId == session &&
        bindingSha256 == request.expectedAssignmentSha256 && result.operationId == operationId &&
        result.deviceId == deviceId && result.bindingSha256 == bindingSha256 && result.invoked && result.outcome == .invoked
    }

    func fresh(at now: Int64) -> Bool { now > 0 && expiresAt > now && expiresAt - now <= 1500 }

    var flags: UInt64 {
        // Craft ModifierSet is command, option, control, shift, function; these are CG flag bits.
        zip([1, 2, 4, 8, 16], [UInt64(1 << 20), 1 << 19, 1 << 18, 1 << 17, 1 << 23])
            .reduce(0) { $0 | (modifiers & $1.0 != 0 ? $1.1 : 0) }
    }
}

struct HostConfiguredCraftTarget: Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

@MainActor
final class HostConfiguredCraftEgress {
    typealias Admission = @MainActor (@MainActor () throws -> Void) throws -> Void
    typealias Sink = @MainActor (KeyStroke) -> Bool
    private struct Debt {
        let target: HostConfiguredCraftTarget
        let up: KeyStroke
        let sink: Sink
    }
    private let resolve: @MainActor () -> HostConfiguredCraftTarget?
    private let foreground: @MainActor (HostConfiguredCraftTarget) -> Bool
    private let focus: @MainActor (HostConfiguredCraftTarget) -> Bool
    private let prepare: @MainActor (HostConfiguredCraftTarget, [KeyStroke]) -> Sink?
    private let beforeFlags: @MainActor () -> UInt64
    private let now: @MainActor () -> Int64
    private let uptime: @MainActor () -> TimeInterval
    private let wait: @MainActor () async -> Void
    private var debts: [UUID: Debt] = [:]
    private var consumed: [UUID: Int64] = [:]
    var hasDebt: Bool { !debts.isEmpty }

    init(resolve: @escaping @MainActor () -> HostConfiguredCraftTarget?,
         foreground: @escaping @MainActor (HostConfiguredCraftTarget) -> Bool,
         focus: @escaping @MainActor (HostConfiguredCraftTarget) -> Bool,
         prepare: @escaping @MainActor (HostConfiguredCraftTarget, [KeyStroke]) -> Sink?,
         beforeFlags: @escaping @MainActor () -> UInt64,
         now: @escaping @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wait: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(10)) }) {
        self.resolve = resolve; self.foreground = foreground; self.focus = focus; self.prepare = prepare
        self.beforeFlags = beforeFlags; self.now = now; self.uptime = uptime; self.wait = wait
    }

    func execute(_ plan: HostConfiguredCraftExecution, current: @escaping @MainActor () -> Bool,
                 admission: Admission) async -> Bool {
        consumed = consumed.filter { $0.value > now() }
        guard plan.fresh(at: now()), consumed[plan.operationId] == nil, consumed.count < 128 else { return false }
        consumed[plan.operationId] = plan.expiresAt
        guard !Task.isCancelled, current(), debts.isEmpty, let target = resolve() else { return false }
        let deadline = uptime() + min(1.5, Double(plan.expiresAt - now()) / 1000)
        func valid() -> Bool {
            !Task.isCancelled && current() && plan.fresh(at: now()) && uptime() < deadline && resolve() == target
        }
        if !foreground(target) {
            guard valid(), focus(target) else { return false }
            while !foreground(target) {
                guard valid() else { return false }
                await wait()
            }
        }
        guard valid(), foreground(target) else { return false }
        let strokes = KeyStrokes.chord(virtualKey: plan.keyCode, flags: plan.flags, before: beforeFlags())
        guard strokes.count == 2, let sink = prepare(target, strokes), valid(), foreground(target) else { return false }
        var posted = false, admitted = true
        do {
            try admission {
                // Admission owns the Sentry lock. No recursive current/Sentry lookup inside it.
                guard !Task.isCancelled, plan.fresh(at: now()), uptime() < deadline else { return }
                posted = sink(strokes[0])
                if posted { debts[plan.operationId] = Debt(target: target, up: strokes[1], sink: sink) }
            }
        } catch { admitted = false }
        guard posted else { return false }
        let stillCurrent = valid() && foreground(target)
        return release(owner: plan.operationId) && admitted && stillCurrent
    }

    @discardableResult
    func release(owner: UUID) -> Bool {
        guard let debt = debts[owner] else { return true }
        guard resolve() == debt.target, debt.sink(debt.up) else { return false }
        debts[owner] = nil
        return true
    }

    func releaseOwnedDebts() {
        for owner in Array(debts.keys) { release(owner: owner) }
    }
}
