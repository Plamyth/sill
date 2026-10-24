import Foundation
import StreamProtocol

/// A received host report, never a grant of input, audio or Sentry control authority.
struct IPadSentryObservation: Equatable {
    enum Status: Equatable {
        case unknown
        case reported(SentryState)
    }

    private struct Scope: Equatable {
        let hostBootID: UUID
        let sessionID: UUID
    }

    static func decodeCatalog(_ data: Data) -> SentryState? {
        guard let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sentry = catalog["sentry"] as? [String: Any],
              let raw = try? JSONSerialization.data(withJSONObject: sentry) else { return nil }
        if let state = try? JSONDecoder().decode(SentryState.self, from: raw) { return state }
        // 미래 capability나 손상된 control이 기존 v1 관찰을 가리지 않도록 분리한다.
        sentry.removeValue(forKey: "control")
        guard let core = try? JSONSerialization.data(withJSONObject: sentry) else { return nil }
        return try? JSONDecoder().decode(SentryState.self, from: core)
    }

    private(set) var status: Status = .unknown
    private var peer: ObjectIdentifier?
    private var scope: Scope?
    private var scopeConflicted = false

    mutating func bind(_ peer: ObjectIdentifier?) {
        guard self.peer != peer else { return }
        self = Self()
        self.peer = peer
    }

    mutating func observe(catalog: Data, from peer: ObjectIdentifier) {
        guard self.peer == peer else { return }
        guard !scopeConflicted,
              let state = Self.decodeCatalog(catalog) else {
            status = .unknown
            return
        }
        observe(state: state, from: peer)
    }

    mutating func observe(state: SentryState, from peer: ObjectIdentifier) {
        guard self.peer == peer else { return }
        guard !scopeConflicted, Self.isConsistent(state) else { status = .unknown; return }
        let receivedScope = Scope(hostBootID: state.hostBootID, sessionID: state.sessionID)
        if let scope, scope != receivedScope {
            scopeConflicted = true
            status = .unknown
            return
        }
        scope = receivedScope
        // v1 has no monotonic sequence. A revision UUID cannot establish freshness.
        status = .reported(state)
    }

    static func isConsistent(_ state: SentryState) -> Bool {
        guard state.version == 1 else { return false }
        switch (state.phase, state.requested) {
        case (.inactive, false), (.pending, _), (.userSessionProtected, true), (.blocked, true):
            return true
        default:
            return false
        }
    }

    var statusText: String {
        switch status {
        case .unknown: return "호스트 보고: 미확인"
        case .reported(let state):
            switch state.phase {
            case .userSessionProtected: return "호스트 보고: 켜짐·보호 확인"
            case .pending: return "호스트 보고: 보호 전환 중"
            case .blocked: return "호스트 보고: 보호 확인 실패"
            case .inactive: return "호스트 보고: 꺼짐"
            }
        }
    }
}
