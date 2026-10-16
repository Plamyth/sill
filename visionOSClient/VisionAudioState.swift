import Foundation

struct VisionAudioScope: Equatable {
    let connection: UUID
    let source: UInt64
}

struct VisionAudioGrant: Equatable {
    let id: UUID
    let scope: VisionAudioScope
}

struct VisionAudioState {
    enum Availability: Equatable {
        case disconnected
        case unsupported
        case noSource
        case available(VisionAudioScope)
    }

    enum Phase: Equatable {
        case off
        case requesting(VisionAudioGrant, until: Double)
        case waiting(VisionAudioGrant, until: Double)
        case rendering(VisionAudioGrant)
        case failed(String)

        var grant: VisionAudioGrant? {
            switch self {
            case .requesting(let grant, _), .waiting(let grant, _), .rendering(let grant): return grant
            case .off, .failed: return nil
            }
        }
    }

    private(set) var availability = Availability.disconnected
    private(set) var foreground = false
    private(set) var phase = Phase.off
    static let responseTimeout = 8.0

    var canEnable: Bool {
        guard foreground, phase.grant == nil, case .available = availability else { return false }
        return true
    }

    mutating func update(_ next: Availability, foreground nextForeground: Bool) -> VisionAudioGrant? {
        let changed = availability != next || foreground != nextForeground
        availability = next
        foreground = nextForeground
        return changed ? stop() : nil
    }

    mutating func request(id: UUID, now: Double) -> VisionAudioGrant? {
        guard canEnable, now.isFinite, case .available(let scope) = availability else { return nil }
        let grant = VisionAudioGrant(id: id, scope: scope)
        phase = .requesting(grant, until: now + Self.responseTimeout)
        return grant
    }

    mutating func acknowledge(id: UUID, enabled: Bool, scope: VisionAudioScope, now: Double,
                              reason: String?) -> VisionAudioGrant? {
        guard case .requesting(let grant, let deadline) = phase,
              grant.id == id, grant.scope == scope, isCurrent(grant), now.isFinite, now < deadline else { return nil }
        guard enabled else {
            phase = .failed(reason ?? "Mac에서 소리 전송을 시작하지 못했습니다.")
            return nil
        }
        phase = .waiting(grant, until: now + Self.responseTimeout)
        return grant
    }

    func admits(_ grant: VisionAudioGrant, now: Double) -> Bool {
        guard now.isFinite, isCurrent(grant) else { return false }
        switch phase {
        case .waiting(let current, let deadline): return current == grant && now < deadline
        case .rendering(let current): return current == grant
        default: return false
        }
    }

    mutating func rendered(_ grant: VisionAudioGrant, now: Double) -> Bool {
        guard admits(grant, now: now) else { return false }
        phase = .rendering(grant)
        return true
    }

    mutating func underrun(_ grant: VisionAudioGrant, now: Double) {
        guard admits(grant, now: now), case .rendering = phase else { return }
        phase = .waiting(grant, until: now + Self.responseTimeout)
    }

    mutating func expire(now: Double) -> VisionAudioGrant? {
        guard now.isFinite else { return nil }
        switch phase {
        case .requesting(let grant, let deadline), .waiting(let grant, let deadline):
            guard now >= deadline else { return nil }
            phase = .failed("Mac 소리 응답이 없어 중지했습니다. 다시 켜려면 직접 선택하세요.")
            return grant
        default: return nil
        }
    }

    @discardableResult
    mutating func stop(problem: String? = nil) -> VisionAudioGrant? {
        let old = phase.grant
        phase = problem.map(Phase.failed) ?? .off
        return old
    }

    func isCurrent(_ grant: VisionAudioGrant) -> Bool {
        foreground && availability == .available(grant.scope) && phase.grant == grant
    }
}
