import Foundation

private typealias Lease = LocalCursorInputLease

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}

@MainActor
private func refuses(_ expected: Lease.Refusal, _ action: () throws -> Void) throws {
    do {
        try action()
        throw Failure(description: "거절해야 할 요청을 허용했습니다")
    } catch let refusal as Lease.Refusal {
        try require(refusal == expected, "요청 거절 사유가 다릅니다")
    }
}

@MainActor
private final class Harness {
    struct Release {
        let owner: Lease.Connection
        let target: Lease.Target
        let reason: Lease.ReleaseReason
    }

    var time: UInt64 = 1_000_000_000
    var releases: [Release] = []
    var downs: [UUID: Set<Int>] = [:]
    var posts = 0
    var onRelease: (() -> Void)?
    lazy var model = Lease(now: { [unowned self] in self.time }, releaseDown: { [unowned self] owner, target, reason in
        self.releases.append(Release(owner: owner, target: target, reason: reason))
        self.onRelease?()
        self.downs[owner.id] = nil
    })

    func target(pid: Int32 = 41, windowID: UInt32 = 73, instanceID: String = "opaque-instance",
                workspace: String = "opaque-workspace", interaction: Lease.Interaction = .windowScoped,
                captureGeneration: String = "capture-A",
                videoEpoch: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!) -> Lease.Target {
        Lease.Target(pid: pid, windowID: windowID, instanceID: instanceID, workspace: workspace,
                     interaction: interaction, captureGeneration: captureGeneration, videoEpoch: videoEpoch)
    }

    @discardableResult
    func post(_ grant: Lease.Grant, window: (Lease.Target) -> Bool = { _ in true },
              authority: ((Lease.Target, () -> Void) -> Void)? = { _, operation in operation() }) -> Bool {
        model.withAuthorization(grant, windowCurrent: window, conversationAuthority: authority) {
            self.posts += 1
        }
    }
}

@main
private struct Checks {
    @MainActor
    static func main() {
        var failures = 0
        var checks = 0
        func check(_ name: String, _ action: () throws -> Void) {
            checks += 1
            do { try action() }
            catch {
                failures += 1
                print("실패 \(name): \(error)")
            }
        }

        check("연결 객체와 호스트 발급 권한") {
            let h = Harness(), model = h.model
            let a = model.openConnection(), b = model.openConnection()
            try require(a !== b && a.id != b.id, "연결 객체와 Host UUID는 고유해야 합니다")
            let grant = try model.claim(a, target: h.target())
            try require(grant.connection === a && grant.origin == .ccrLocal, "권한은 원본 연결 객체에 결합해야 합니다")
            try require(grant.deadlineNanoseconds == h.time + 500_000_000, "기본 기한은 500ms여야 합니다")
            try require(Lease.Origin(rawValue: "remote-delegated") == nil, "원격 위임 origin을 지원하면 안 됩니다")
            try require(h.post(grant) && h.posts == 1, "유효한 로컬 소유자는 격리 closure를 실행해야 합니다")
            try refuses(.localOwnerBusy) { _ = try model.claim(a, target: h.target()) }
            try refuses(.localOwnerBusy) { _ = try model.claim(b, target: h.target(windowID: 99)) }
            model.closeConnection(b)
            try require(h.post(grant) && h.releases.isEmpty, "다른 요청과 연결 종료가 유효한 소유를 바꾸면 안 됩니다")
        }

        for ttl in [100, 2000] {
            check("허용 TTL 경계 \(ttl)") {
                let h = Harness(), connection = h.model.openConnection()
                let grant = try h.model.claim(connection, target: h.target(), ttlMilliseconds: ttl)
                try require(grant.deadlineNanoseconds == h.time + UInt64(ttl) * 1_000_000, "TTL 경계를 정확히 적용해야 합니다")
            }
        }
        for ttl in [Int.min, -1, 0, 99, 2001, Int.max] {
            check("범위 밖 TTL 거절 \(ttl)") {
                let h = Harness(), connection = h.model.openConnection(), stranger = h.model.openConnection()
                let grant = try h.model.claim(connection, target: h.target())
                try refuses(.invalidTTL) { _ = try h.model.claim(stranger, target: h.target(windowID: 99), ttlMilliseconds: ttl) }
                try refuses(.invalidTTL) { _ = try h.model.renew(grant, ttlMilliseconds: ttl) }
                try require(h.post(grant) && h.releases.isEmpty, "잘못된 TTL이 현재 소유와 기한을 바꾸면 안 됩니다")
            }
        }
        check("기한 덧셈 초과") {
            let h = Harness(), connection = h.model.openConnection()
            h.time = UInt64.max - 50_000_000
            try refuses(.deadlineOverflow) { _ = try h.model.claim(connection, target: h.target(), ttlMilliseconds: 100) }
            try require(h.releases.isEmpty, "발급되지 않은 권한을 해제하면 안 됩니다")
        }
        check("기한 초과 거절이 유효한 소유를 보존") {
            let h = Harness(), connection = h.model.openConnection()
            h.time = UInt64.max - 300_000_000
            let grant = try h.model.claim(connection, target: h.target(), ttlMilliseconds: 100)
            try refuses(.deadlineOverflow) { _ = try h.model.renew(grant, ttlMilliseconds: 2000) }
            try refuses(.deadlineOverflow) {
                _ = try h.model.claim(connection, target: h.target(windowID: 74), ttlMilliseconds: 2000)
            }
            try require(h.post(grant) && h.releases.isEmpty, "발급 불가능한 기한이 기존 소유를 해제하면 안 됩니다")
        }

        for interaction in [Lease.Interaction.windowScoped, .conversationScoped(conversationID: "conversation-A")] {
            check("갱신과 이전 grant 재생 거부 \(interaction)") {
                let h = Harness(), connection = h.model.openConnection()
                let old = try h.model.claim(connection, target: h.target(interaction: interaction), ttlMilliseconds: 100)
                h.downs[connection.id] = [7]
                h.time += 90_000_000
                let renewed = try h.model.renew(old, ttlMilliseconds: 2000)
                try require(old !== renewed && old.id == renewed.id && old.generation == renewed.generation,
                            "갱신은 객체만 교체하고 wire 식별자와 세대를 유지해야 합니다")
                try require(renewed.connection === connection && renewed.target == old.target,
                            "갱신으로 소유 연결과 target을 바꾸면 안 됩니다")
                try require(renewed.deadlineNanoseconds == h.time + 2_000_000_000, "갱신 TTL 상한을 적용해야 합니다")
                try require(!h.post(old) && h.post(renewed), "갱신 전 grant는 즉시 무효여야 합니다")
                try refuses(.staleGrant) { _ = try h.model.renew(old) }
                h.time = old.deadlineNanoseconds
                try require(h.post(renewed) && h.downs[connection.id] == [7] && h.releases.isEmpty,
                            "이전 기한과 stale 요청이 갱신된 Down을 해제하면 안 됩니다")
                let postedUp = h.model.withAuthorization(renewed, windowCurrent: { $0 == old.target },
                    conversationAuthority: { _, execute in execute() }) {
                    h.downs[renewed.connection.id]?.remove(7)
                }
                try require(postedUp && h.downs[connection.id] == [] && h.releases.isEmpty,
                            "같은 wire scope의 갱신된 grant로 기존 소유자의 Up을 처리할 수 있어야 합니다")
            }
        }

        check("다른 모델의 연결과 grant 거절") {
            let a = Harness(), b = Harness(), connection = a.model.openConnection()
            let grant = try a.model.claim(connection, target: a.target())
            let bConnection = b.model.openConnection(), bGrant = try b.model.claim(bConnection, target: b.target())
            try refuses(.connectionNotOpen) { _ = try b.model.claim(connection, target: b.target()) }
            try refuses(.connectionNotOpen) { _ = try b.model.renew(grant) }
            b.model.closeConnection(connection)
            try require(!b.post(grant) && b.post(bGrant) && a.post(grant), "다른 모델의 객체로 소유를 대체하면 안 됩니다")
            try require(a.releases.isEmpty && b.releases.isEmpty, "다른 모델의 요청은 소유 해제를 일으키면 안 됩니다")
        }
        check("연결 종료와 재연결") {
            let h = Harness(), connection = h.model.openConnection()
            let grant = try h.model.claim(connection, target: h.target())
            h.downs[connection.id] = [4]
            h.model.closeConnection(connection)
            h.model.closeConnection(connection)
            let replacement = h.model.openConnection()
            try require(replacement !== connection && replacement.id != connection.id, "재연결에 원래 identity를 재사용하면 안 됩니다")
            try require(!h.post(grant) && h.downs[connection.id] == nil, "종료한 연결의 권한과 Down을 해제해야 합니다")
            try refuses(.connectionNotOpen) { _ = try h.model.claim(connection, target: h.target()) }
            try refuses(.connectionNotOpen) { _ = try h.model.renew(grant) }
            try require(h.releases.count == 1 && h.releases[0].reason == .connectionClosed, "종료 해제는 한 번이어야 합니다")
            let next = try h.model.claim(replacement, target: h.target())
            try require(h.post(next), "검증된 새 연결은 별도 권한을 발급받아야 합니다")
        }

        for interaction in [Lease.Interaction.windowScoped, .conversationScoped(conversationID: "conversation-A")] {
            check("명시 해제와 같은 IPC 연결의 재bind \(interaction)") {
                let h = Harness(), connection = h.model.openConnection(), other = h.model.openConnection()
                let grant = try h.model.claim(connection, target: h.target(interaction: interaction))
                h.downs[connection.id] = [1]
                h.downs[other.id] = [9]
                try require(h.model.release(grant), "현재 grant의 명시 해제는 성공해야 합니다")
                try require(!h.post(grant) && !h.model.release(grant), "해제한 grant의 게시와 중복 해제를 거절해야 합니다")
                try require(h.releases.count == 1 && h.releases[0].reason == .explicitRelease &&
                            h.releases[0].owner === connection && h.releases[0].target == grant.target,
                            "명시 해제는 정확한 소유자와 target을 한 번만 해제해야 합니다")
                try require(h.downs[connection.id] == nil && h.downs[other.id] == [9],
                            "명시 해제는 다른 소유자의 Down을 유지해야 합니다")
                let rebound = try h.model.claim(connection, target: grant.target)
                try require(rebound.connection === connection && rebound.id != grant.id &&
                            rebound.generation != grant.generation && h.post(rebound),
                            "검증된 같은 연결로 재bind하고 새 scope를 발급받을 수 있어야 합니다")
                h.downs[connection.id] = [2]
                try require(!h.model.release(grant) && h.downs[connection.id] == [2] && h.post(rebound),
                            "이전 해제 요청이 재bind한 소유를 해제하면 안 됩니다")
                h.model.closeConnection(connection)
                try require(h.releases.count == 2 && h.releases[1].reason == .connectionClosed && !h.post(rebound),
                            "실제 연결 종료는 재bind한 현재 grant를 별도로 해제해야 합니다")
                try refuses(.connectionNotOpen) { _ = try h.model.claim(connection, target: grant.target) }
            }
        }
        check("갱신 전 객체와 다른 owner의 해제 거절") {
            let h = Harness(), foreign = Harness()
            let a = h.model.openConnection(), b = h.model.openConnection()
            let foreignConnection = foreign.model.openConnection()
            let foreignGrant = try foreign.model.claim(foreignConnection, target: foreign.target())
            let old = try h.model.claim(a, target: h.target())
            let renewed = try h.model.renew(old)
            h.downs[a.id] = [1]
            try require(old.id == renewed.id && old.generation == renewed.generation && old !== renewed,
                        "이 검사는 wire scope가 같은 이전 객체를 사용해야 합니다")
            try require(!h.model.release(old) && !h.model.release(foreignGrant) && h.post(renewed),
                        "이전 객체나 다른 모델의 grant가 현재 소유를 해제하면 안 됩니다")
            try require(h.releases.isEmpty && h.downs[a.id] == [1] && foreign.post(foreignGrant),
                        "거절된 명시 해제는 양쪽 소유와 Down을 유지해야 합니다")
            try require(h.model.release(renewed), "갱신된 현재 객체는 해제할 수 있어야 합니다")
            let next = try h.model.claim(b, target: h.target())
            h.downs[b.id] = [2]
            try require(!h.model.release(old) && !h.model.release(renewed) && h.post(next),
                        "이전 owner의 grant가 다른 owner의 현재 소유를 해제하면 안 됩니다")
            try require(h.releases.count == 1 && h.downs[b.id] == [2], "다른 owner의 Down은 유지해야 합니다")
            h.time = next.deadlineNanoseconds
            try require(!h.model.release(old) && h.releases.count == 1 && h.downs[b.id] == [2],
                        "stale 해제 요청은 다른 owner의 만료 처리까지 실행하면 안 됩니다")
            try require(h.model.expireIfNeeded() && h.releases.count == 2 && h.releases[1].reason == .expired,
                        "만료 처리는 해당 진입점에서 별도로 수행해야 합니다")
        }
        check("현재 객체의 기한 후 명시 정리") {
            let h = Harness(), connection = h.model.openConnection()
            let grant = try h.model.claim(connection, target: h.target())
            h.downs[connection.id] = [1]
            h.time = grant.deadlineNanoseconds
            try require(h.model.release(grant) && h.releases.count == 1 &&
                        h.releases[0].reason == .explicitRelease && h.downs[connection.id] == nil,
                        "기한이 지났어도 정확한 현재 객체의 정리는 허용해야 합니다")
            try require(!h.model.expireIfNeeded() && !h.model.release(grant), "명시 정리 뒤 중복 해제하면 안 됩니다")
            let next = try h.model.claim(connection, target: h.target())
            try require(h.post(next), "기한 후 명시 정리도 IPC 연결을 유지해야 합니다")
        }
        check("명시 해제 callback이 끝나기 전 재bind 거절") {
            let h = Harness(), connection = h.model.openConnection()
            let grant = try h.model.claim(connection, target: h.target())
            h.downs[connection.id] = [1]
            var called = false
            var callbackError: Error?
            h.onRelease = {
                called = true
                do {
                    try require(!h.model.release(grant) && !h.post(grant), "명시 해제 callback 전에 현재 권한을 무효화해야 합니다")
                    try refuses(.releaseInProgress) { _ = try h.model.claim(connection, target: grant.target) }
                    try refuses(.releaseInProgress) { _ = try h.model.renew(grant) }
                } catch { callbackError = error }
            }
            try require(h.model.release(grant), "명시 해제는 callback을 완료해야 합니다")
            if let callbackError { throw callbackError }
            h.onRelease = nil
            let next = try h.model.claim(connection, target: grant.target)
            try require(called && h.releases.count == 1 && h.downs[connection.id] == nil && h.post(next),
                        "Down 해제 완료 뒤 같은 연결로 재bind할 수 있어야 합니다")
        }

        for variant in 0..<7 {
            check("target 필드 변경 \(variant)") {
                let h = Harness(), connection = h.model.openConnection(), other = h.model.openConnection()
                let target = h.target()
                let variants = [h.target(pid: 42), h.target(windowID: 74), h.target(instanceID: "instance-B"),
                                h.target(workspace: "workspace-B"), h.target(interaction: .conversationScoped(conversationID: "conversation-B")),
                                h.target(captureGeneration: "capture-B"),
                                h.target(videoEpoch: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)]
                let changed = variants[variant]
                try require(changed != target, "모든 target 필드를 비교해야 합니다")
                let old = try h.model.claim(connection, target: target)
                h.downs[connection.id] = [1]
                h.downs[other.id] = [9]
                let next = try h.model.claim(connection, target: changed)
                try require(next.id != old.id && next.generation != old.generation,
                            "target 변경 claim은 새 wire 식별자와 세대를 발급해야 합니다")
                try require(h.downs[connection.id] == nil && h.downs[other.id] == [9], "이전 소유자의 Down만 먼저 해제해야 합니다")
                try require(h.releases.count == 1 && h.releases[0].owner === connection &&
                            h.releases[0].target == target && h.releases[0].reason == .targetChanged,
                            "해제 대상은 정확한 이전 소유자와 target이어야 합니다")
                try require(!h.post(old) && h.post(next), "target 변경 전 grant는 게시할 수 없어야 합니다")
            }
        }

        check("기한 직전과 정확한 만료 시점") {
            let h = Harness(), connection = h.model.openConnection()
            let grant = try h.model.claim(connection, target: h.target(), ttlMilliseconds: 100)
            h.downs[connection.id] = [1]
            h.time = grant.deadlineNanoseconds - 1
            try require(!h.model.expireIfNeeded() && h.post(grant), "기한 직전에는 유효해야 합니다")
            h.time += 1
            try require(h.model.expireIfNeeded() && !h.post(grant), "정확한 기한에 만료해야 합니다")
            try require(!h.model.expireIfNeeded() && h.releases.count == 1 && h.releases[0].reason == .expired,
                        "중복 만료가 중복 해제를 일으키면 안 됩니다")
            try require(h.downs[connection.id] == nil, "만료한 Down을 해제해야 합니다")
        }
        for entry in ["게시", "갱신", "새 claim"] {
            check("누락된 타이머의 만료 검사 \(entry)") {
                let h = Harness(), connection = h.model.openConnection(), next = h.model.openConnection()
                let grant = try h.model.claim(connection, target: h.target(), ttlMilliseconds: 100)
                h.downs[connection.id] = [3]
                h.time = grant.deadlineNanoseconds
                switch entry {
                case "게시": try require(!h.post(grant), "게시가 만료를 우회하면 안 됩니다")
                case "갱신": try refuses(.staleGrant) { _ = try h.model.renew(grant) }
                default:
                    let replacement = try h.model.claim(next, target: h.target())
                    try require(h.post(replacement), "만료 정리 후 새 소유자가 claim할 수 있어야 합니다")
                }
                try require(h.releases.count == 1 && h.releases[0].reason == .expired && h.downs[connection.id] == nil,
                            "각 진입점에서 만료 소유자의 Down을 먼저 해제해야 합니다")
            }
        }

        for interaction in [Lease.Interaction.windowScoped, .conversationScoped(conversationID: "conversation-A")] {
            for remote in [false, true] {
                check("보호 상태 거절 \(interaction) \(remote)") {
                    let h = Harness(), connection = h.model.openConnection(), other = h.model.openConnection()
                    let grant = try h.model.claim(connection, target: h.target(interaction: interaction))
                    h.downs[connection.id] = [1]; h.downs[other.id] = [2]
                    h.model.remoteStateChanged(remoteViewerOwnsInput: remote, sentryProtected: !remote)
                    let reason: Lease.ReleaseReason = remote ? .remoteViewerOwnsInput : .sentryProtected
                    let refusal: Lease.Refusal = remote ? .remoteViewerOwnsInput : .sentryProtected
                    try require(h.releases.count == 1 && h.releases[0].reason == reason, "보호 활성 시 즉시 해제해야 합니다")
                    try require(h.downs[connection.id] == nil && h.downs[other.id] == [2], "원격 또는 다른 소유자의 Down을 해제하면 안 됩니다")
                    try require(!h.post(grant), "보호 중 게시를 거부해야 합니다")
                    try refuses(refusal) { _ = try h.model.claim(other, target: h.target()) }
                    try refuses(refusal) { _ = try h.model.renew(grant) }
                    h.model.remoteStateChanged(remoteViewerOwnsInput: remote, sentryProtected: !remote)
                    try require(h.releases.count == 1, "보호 상태 반복 통지로 중복 해제하면 안 됩니다")
                    h.model.remoteStateChanged(remoteViewerOwnsInput: false, sentryProtected: false)
                    try require(!h.post(grant), "보호 해제 후 이전 grant를 되살리면 안 됩니다")
                    let next = try h.model.claim(other, target: h.target())
                    h.model.remoteStateChanged(remoteViewerOwnsInput: false, sentryProtected: false)
                    try require(h.post(next) && h.releases.count == 1, "보호가 없는 통지로 현재 소유를 바꾸면 안 됩니다")
                }
            }
        }
        check("소유 전 보호와 두 보호의 결합") {
            let h = Harness(), connection = h.model.openConnection()
            h.model.remoteStateChanged(remoteViewerOwnsInput: true, sentryProtected: true)
            try refuses(.remoteViewerOwnsInput) { _ = try h.model.claim(connection, target: h.target()) }
            h.model.remoteStateChanged(remoteViewerOwnsInput: false, sentryProtected: true)
            try refuses(.sentryProtected) { _ = try h.model.claim(connection, target: h.target()) }
            try require(h.releases.isEmpty, "소유하지 않은 연결에 release를 호출하면 안 됩니다")
        }

        for interaction in [Lease.Interaction.windowScoped, .conversationScoped(conversationID: "conversation-A")] {
            check("창 검증 거부와 해제 \(interaction)") {
                let h = Harness(), connection = h.model.openConnection()
                let grant = try h.model.claim(connection, target: h.target(interaction: interaction))
                var observed: Lease.Target?
                try require(!h.post(grant, window: { observed = $0; return false }), "오래된 창에 게시하면 안 됩니다")
                try require(observed == grant.target && h.releases.count == 1 && h.releases[0].reason == .targetChanged,
                            "창 검증에 원래 target을 전달하고 해당 소유를 해제해야 합니다")
                try require(!h.post(grant) && h.posts == 0, "창 거절 후 grant가 무효여야 합니다")
            }
        }
        check("같은 target 재획득의 이전 grant 거절") {
            let h = Harness(), connection = h.model.openConnection()
            let original = try h.model.claim(connection, target: h.target())
            _ = try h.model.claim(connection, target: h.target(windowID: 74))
            let next = try h.model.claim(connection, target: h.target())
            var called = false
            try require(!h.post(original, window: { _ in called = true; return false }),
                        "같은 target으로 돌아와도 이전 grant는 유효해지면 안 됩니다")
            try require(!called && h.post(next) && h.releases.count == 2, "이전 grant가 새 소유의 창 검사나 해제를 일으키면 안 됩니다")
        }
        check("특정 대화 변경은 새 scope를 발급") {
            let h = Harness(), connection = h.model.openConnection()
            let a = h.target(interaction: .conversationScoped(conversationID: "conversation-A"))
            let b = h.target(interaction: .conversationScoped(conversationID: "conversation-B"))
            let old = try h.model.claim(connection, target: a)
            h.downs[connection.id] = [1]
            let next = try h.model.claim(connection, target: b)
            try require(a != b && next.id != old.id && next.generation != old.generation,
                        "같은 창의 특정 대화가 달라지면 target과 wire scope가 달라야 합니다")
            try require(h.releases.count == 1 && h.downs[connection.id] == nil && !h.post(old) && h.post(next),
                        "특정 대화 변경은 이전 Down을 해제하고 이전 callback을 거절해야 합니다")
        }
        check("원본 대화 권한 미지원") {
            let h = Harness(), connection = h.model.openConnection()
            let grant = try h.model.claim(connection, target: h.target(interaction: .conversationScoped(conversationID: "conversation-A")))
            var windowChecks = 0
            try require(!h.post(grant, authority: nil), "대화 입력은 authority를 생략하면 거부해야 합니다")
            try require(!h.post(grant, window: { _ in windowChecks += 1; return true }, authority: { _, _ in }),
                        "대화 권한이 없으면 target 일치만으로 게시하면 안 됩니다")
            try require(windowChecks == 0 && h.posts == 0 && h.releases.isEmpty,
                        "권한 미지원은 실제 입력과 유효한 소유 변경을 일으키면 안 됩니다")
            try require(h.post(grant), "격리된 권한 callback으로 같은 소유 상태를 검증할 수 있어야 합니다")
        }
        check("창 입력은 탭 변경과 대화 권한의 영향을 받지 않음") {
            let h = Harness(), connection = h.model.openConnection()
            let grant = try h.model.claim(connection, target: h.target())
            var selectedTab = "tab-A"
            var authorityCalled = false
            var windowChecks = 0
            try require(h.post(grant, window: { target in
                windowChecks += 1
                selectedTab = "tab-B"
                return target == grant.target
            }, authority: { _, _ in authorityCalled = true }),
                        "명시한 원본 창의 일반 입력에 대화 authority를 요구하면 안 됩니다")
            try require(selectedTab == "tab-B" && windowChecks == 1 && !authorityCalled && h.posts == 1,
                        "탭이 바뀌어도 같은 창의 입력은 창 검사 뒤 inputPosted만 반환해야 합니다")
            try require(h.post(grant, authority: nil), "창 입력은 authority 없이 허용해야 합니다")
        }
        check("동기 게시 closure 호환과 중복 실행 방지") {
            let h = Harness(), connection = h.model.openConnection()
            let grant = try h.model.claim(connection, target: h.target(interaction: .conversationScoped(conversationID: "conversation-A")))
            typealias PostAuthorization = (_ operation: () -> Void) -> Bool
            let authorization: PostAuthorization = { operation in
                h.model.withAuthorization(grant, windowCurrent: { $0 == grant.target },
                    conversationAuthority: { _, execute in execute(); execute() }, operation: operation)
            }
            try require(authorization { h.posts += 1 } && h.posts == 1, "동기 게시 계약은 한 번만 실행해야 합니다")
        }

        for interaction in [Lease.Interaction.windowScoped, .conversationScoped(conversationID: "conversation-A")] {
            for windowResult in [false, true] {
                for mutation in ["갱신", "target 변경", "명시 해제", "종료", "만료", "원격", "Sentry"] {
                    check("창 검증 재진입 \(interaction) \(mutation) \(windowResult)") {
                        let h = Harness(), connection = h.model.openConnection()
                        let grant = try h.model.claim(connection, target: h.target(interaction: interaction))
                        var replacement: Lease.Grant?
                        var callbackError: Error?
                        let posted = h.post(grant, window: { _ in
                            do {
                                switch mutation {
                                case "갱신": replacement = try h.model.renew(grant)
                                case "target 변경": replacement = try h.model.claim(connection, target: h.target(windowID: 74, interaction: interaction))
                                case "명시 해제": _ = h.model.release(grant)
                                case "종료": h.model.closeConnection(connection)
                                case "만료": h.time = grant.deadlineNanoseconds
                                case "원격": h.model.remoteStateChanged(remoteViewerOwnsInput: true, sentryProtected: false)
                                default: h.model.remoteStateChanged(remoteViewerOwnsInput: false, sentryProtected: true)
                                }
                            } catch { callbackError = error }
                            return windowResult
                        })
                        if let callbackError { throw callbackError }
                        try require(!posted && h.posts == 0, "창 callback 뒤 이전 세대로 게시하면 안 됩니다")
                        if let replacement {
                            let expectedReleases = mutation == "갱신" ? 0 : 1
                            try require(h.releases.count == expectedReleases && h.post(replacement),
                                        "이전 창 검사 결과가 새 소유를 취소하면 안 됩니다")
                        } else {
                            try require(h.releases.count == 1, "무효화 사유에 맞게 Down을 한 번 해제해야 합니다")
                        }
                    }
                }
            }
        }
        for mutation in ["갱신", "target 변경", "명시 해제", "종료", "만료", "원격", "Sentry"] {
            check("대화 권한 callback 재진입 \(mutation)") {
                let h = Harness(), connection = h.model.openConnection()
                let grant = try h.model.claim(connection, target: h.target(interaction: .conversationScoped(conversationID: "conversation-A")))
                var callbackError: Error?
                var windowChecks = 0
                let posted = h.post(grant, window: { _ in windowChecks += 1; return true }, authority: { _, execute in
                    do {
                        switch mutation {
                        case "갱신": _ = try h.model.renew(grant)
                        case "target 변경": _ = try h.model.claim(connection, target: h.target(windowID: 74,
                            interaction: .conversationScoped(conversationID: "conversation-A")))
                        case "명시 해제": _ = h.model.release(grant)
                        case "종료": h.model.closeConnection(connection)
                        case "만료": h.time = grant.deadlineNanoseconds
                        case "원격": h.model.remoteStateChanged(remoteViewerOwnsInput: true, sentryProtected: false)
                        default: h.model.remoteStateChanged(remoteViewerOwnsInput: false, sentryProtected: true)
                        }
                    } catch { callbackError = error }
                    execute()
                })
                if let callbackError { throw callbackError }
                try require(!posted && h.posts == 0 && windowChecks == 0, "마지막 대화 권한 callback도 세대 변경을 우회하면 안 됩니다")
            }
        }

        check("Down 해제 callback의 재진입과 순서") {
            let h = Harness(), connection = h.model.openConnection(), other = h.model.openConnection()
            let grant = try h.model.claim(connection, target: h.target())
            h.downs[connection.id] = [1]
            var callbackError: Error?
            var called = false
            h.onRelease = {
                called = true
                do {
                    try require(h.downs[connection.id] == [1], "이 검사는 실제 해제 완료 전의 재진입을 검사해야 합니다")
                    try require(!h.post(grant), "release callback 전에 권한부터 무효화해야 합니다")
                    try require(!h.model.release(grant), "해제 callback의 중복 해제는 거절해야 합니다")
                    try refuses(.releaseInProgress) { _ = try h.model.claim(other, target: h.target()) }
                    try refuses(.releaseInProgress) { _ = try h.model.renew(grant) }
                } catch { callbackError = error }
            }
            let next = try h.model.claim(connection, target: h.target(windowID: 74))
            if let callbackError { throw callbackError }
            try require(called && h.downs[connection.id] == nil && h.post(next), "Down 해제 완료 뒤에만 새 소유를 게시해야 합니다")
        }
        for mutation in ["종료", "원격", "Sentry"] {
            check("target 전환 해제 중 보호 변경 \(mutation)") {
                let h = Harness(), connection = h.model.openConnection()
                let grant = try h.model.claim(connection, target: h.target())
                h.onRelease = {
                    switch mutation {
                    case "종료": h.model.closeConnection(connection)
                    case "원격": h.model.remoteStateChanged(remoteViewerOwnsInput: true, sentryProtected: false)
                    default: h.model.remoteStateChanged(remoteViewerOwnsInput: false, sentryProtected: true)
                    }
                }
                let expected: Lease.Refusal = mutation == "종료" ? .connectionNotOpen :
                    (mutation == "원격" ? .remoteViewerOwnsInput : .sentryProtected)
                try refuses(expected) { _ = try h.model.claim(connection, target: h.target(windowID: 74)) }
                try require(h.releases.count == 1 && !h.post(grant), "해제 callback의 보호 변경을 새 발급이 덮으면 안 됩니다")
            }
        }
        check("해제 지연이 새 claim 기한을 넘긴 경우") {
            let h = Harness(), connection = h.model.openConnection()
            _ = try h.model.claim(connection, target: h.target())
            h.onRelease = { h.time += 100_000_000 }
            try refuses(.staleGrant) {
                _ = try h.model.claim(connection, target: h.target(windowID: 74), ttlMilliseconds: 100)
            }
            h.onRelease = nil
            let next = try h.model.claim(connection, target: h.target(windowID: 74))
            try require(h.post(next) && h.releases.count == 1, "발급 전 만료한 후보를 소유자로 남기면 안 됩니다")
        }

        print("격리 회귀 \(checks)개 중 실패 \(failures)개. 실제 입력 0회.")
        exit(failures == 0 ? 0 : 1)
    }
}
