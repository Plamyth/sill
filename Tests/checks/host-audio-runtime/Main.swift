import Foundation
import StreamProtocol

@main
struct Main {
    @MainActor private static func startWithPrepareGate(_ fixture: Fixture) async throws {
        let original = LocalAudioRelayLaunch.child!
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let script = String(data: try encoder.encode(original.path), encoding: .utf8)!
        let wrapper = fixture.directory.appendingPathComponent("prepare-queue-gate.py")
        let source = """
        import json, pathlib, runpy, sys, time
        directory = pathlib.Path(sys.argv[1])
        original_loads = json.loads
        count = 0
        def gated_loads(value, *args, **kwargs):
            global count
            request = original_loads(value, *args, **kwargs)
            if isinstance(request, dict) and request.get('method') == 'forwardingPrepare':
                count += 1
                (directory / ('prepare-entered-' + str(count))).touch()
                release = directory / ('prepare-release-' + str(count))
                deadline = time.monotonic() + 4.6
                while not release.exists() and time.monotonic() < deadline:
                    time.sleep(.005)
            return request
        json.loads = gated_loads
        sys.argv[0] = \(script)
        runpy.run_path(\(script), run_name='__main__')
        """
        try source.write(to: wrapper, atomically: true, encoding: .utf8)
        LocalAudioRelayLaunch.child = wrapper
        defer { LocalAudioRelayLaunch.child = original }
        try await fixture.start()
    }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        LocalAudioRelayLaunch.child = URL(fileURLWithPath: CommandLine.arguments[2])
        var checks = 0

        do {
            let f = try Fixture(root: root), connection = Connection()
            defer { f.finish() }
            try await f.start()
            let launches = LocalAudioRelayLaunch.launches
            await f.runtime.start()
            precondition(LocalAudioRelayLaunch.launches == launches, "start의 canonical factory 중복 호출 금지")
            let unobserved = await f.submit(connection)
            precondition(unobserved == nil && f.count("forwardingRequest") == 0 && f.count("forwardingBootstrap") == 0,
                         "submit이 관측 없이 credential을 발급하면 안 됩니다.")
            let observed = await f.observe(connection)
            precondition(observed?.catalog?.schemaVersion == 2 && observed?.catalog?.role == .controlOnly)
            let other = Connection(peer: connection.peer)
            let borrowed = await f.submit(other)
            precondition(borrowed == nil, "같은 주체라도 다른 UUID는 observe credential을 빌릴 수 없습니다.")
            precondition(f.count("forwardingEvidence", operation: "attach", id: connection.id) == 1)
            connection.role = .viewer
            let promoted = await f.observe(connection)
            precondition(promoted?.catalog?.role == .viewer && f.count("forwardingEvidence", operation: "detach") == 0,
                         "Hello 역할 승격은 기존 UUID의 lease를 유지합니다.")
            let pending = await f.submit(connection)
            guard case .accepted(let pendingSnapshot) = pending?.result else { preconditionFailure("native intent 접수 실패") }
            precondition(pendingSnapshot.binding?.phase == .quiescing)
            await f.until { f.count("forwardingCommit") == 1 }
            try await Task.sleep(for: .milliseconds(50))
            let active = await f.observe(connection)
            precondition(active?.catalog?.bootstrap.snapshot.binding?.phase == .active)
            precondition(f.protectionPreparations == 0, "정상 보호와 active 관측은 보호 준비를 반복하지 않습니다.")
            f.flag("refuse-request")
            let refusedRequest = await f.submit(connection)
            guard case .refused(_, let retainedActive) = refusedRequest?.result else { preconditionFailure("거절된 요청 상태 누락") }
            precondition(retainedActive.binding?.phase == .active,
                         "거절된 새 native 요청이 기존 transport 소유를 바꾸면 안 됩니다.")
            let afterRefusal = await f.observe(connection)
            precondition(afterRefusal?.catalog?.bootstrap.snapshot.binding?.phase == .active)
            try FileManager.default.removeItem(at: f.directory.appendingPathComponent("refuse-request"))

            precondition(f.nativeStops == 1 && f.count("forwardingPrepare") == 1 && f.count("inspect") >= 1)
            precondition(f.hal.reads > 1 && f.surfaceReads > 1, "실제 privacy/sentry proof readback 실행")
            precondition(f.events().filter { $0["method"] as? String == "forwardingRequest" }
                .allSatisfy { $0["credentialMatches"] as? Bool == true })
            f.close(connection)
            await f.until { f.count("forwardingEvidence", operation: "detach", id: connection.id) == 1 }
            precondition(f.count("forwardingRevoke") == 0)
            guard case .accepted(let retained) = await LocalAudioRelayLaunch.lastRelay?.forwardingSnapshot() else {
                preconditionFailure("일반 소켓 종료가 공유 pipe를 종료했습니다.")
            }
            precondition(retained.intent?.inputDesired == true)
            f.runtime.stop()
            let stopped = await LocalAudioRelayLaunch.lastRelay?.forwardingSnapshot()
            precondition(stopped == nil, "전체 앱 stop만 소유 relay를 종료합니다.")
            checks += 16
        }

        for cancel in [false, true] {
            let f = try Fixture(root: root), connection = Connection()
            defer { f.finish() }
            try await f.start()
            let initial = await f.observe(connection)
            precondition(initial != nil)
            let prior = f.count("forwardingBootstrap")
            f.flag("hold-bootstrap")
            let request = Task { @MainActor in await f.observe(connection) }
            await f.until { f.count("forwardingBootstrap") == prior + 1 }
            if cancel { request.cancel() } else { connection.requestCurrent = false }
            f.flag("release-bootstrap")
            let stale = await request.value
            precondition(stale == nil && f.count("forwardingEvidence", operation: "detach") == 0,
                         "요청 만료·취소는 살아 있는 연결과 이전 성공 관측을 지우지 않습니다.")
            connection.requestCurrent = true
            let submitted = await f.submit(connection)
            precondition(submitted != nil && f.count("forwardingRequest") == 1)
            guard case .accepted = await LocalAudioRelayLaunch.lastRelay?.forwardingSnapshot() else {
                preconditionFailure("요청 취소가 실제 relay call 취소로 전파됐습니다.")
            }
            checks += 4
        }

        for failure in ["expired", "refused", "cursor"] {
            let f = try Fixture(root: root), connection = Connection()
            defer { f.finish() }
            try await f.start()
            if failure == "expired" { f.flag("hold-attach") }
            if failure == "refused" { f.flag("refuse-attach") }
            if failure == "cursor" { f.flag("mismatched-cursor") }
            let request = Task { @MainActor in await f.observe(connection) }
            await f.until { f.count("forwardingEvidence", operation: "attach", id: connection.id) == 1 }
            if failure == "expired" {
                connection.requestCurrent = false
                f.flag("release-attach")
            }
            let failed = await request.value
            precondition(failed == nil)
            await f.until { f.count("forwardingEvidence", operation: "detach", id: connection.id) == 1 }
            connection.requestCurrent = true
            let unobserved = await f.submit(connection)
            precondition(unobserved == nil && f.count("forwardingRequest") == 0)
            try await Task.sleep(for: .milliseconds(5200))
            precondition(f.count("forwardingEvidence", operation: "renew", id: connection.id) == 0,
                         "실패한 최초 관측의 임시 attach를 계속 갱신하면 안 됩니다.")
            checks += 4
        }

        do {
            let f = try Fixture(root: root), connection = Connection()
            defer { f.finish() }
            try await f.start()
            let observed = await f.observe(connection)
            precondition(observed != nil)
            f.flag("refuse-attach")
            let failed = await f.observe(connection)
            precondition(failed == nil && f.count("forwardingEvidence", operation: "detach") == 0,
                         "재observe attach 실패는 이전 성공 lease를 보존합니다.")
            await f.until(seconds: 7) { f.count("forwardingEvidence", operation: "renew", id: connection.id) >= 1 }
            let submitted = await f.submit(connection)
            precondition(submitted != nil && f.count("forwardingRequest") == 1)
            checks += 3
        }

        do {
            let f = try Fixture(root: root), first = Connection()
            let second = Connection(peer: first.peer)
            defer { f.finish() }
            try await f.start()
            let a = await f.observe(first), b = await f.observe(second)
            precondition(a != nil && b != nil)
            let submitted = await f.submit(second, off: true)
            precondition(submitted != nil)
            await f.until { f.count("forwardingCommit") == 1 }
            try await Task.sleep(for: .milliseconds(50))
            f.close(first); f.close(first)
            await f.until { f.count("forwardingEvidence", operation: "detach", id: first.id) == 1 }
            let remaining = await f.observe(second)
            precondition(remaining?.catalog?.bootstrap.snapshot.binding?.phase == .off &&
                         remaining?.catalog?.bootstrap.snapshot.intent?.outputDesired == false)
            precondition(f.count("forwardingEvidence", operation: "detach", id: second.id) == 0)
            f.close(second)
            await f.until { f.count("forwardingEvidence", operation: "detach", id: second.id) == 1 }
            guard case .accepted(let retained) = await LocalAudioRelayLaunch.lastRelay?.forwardingSnapshot() else {
                preconditionFailure("마지막 연결 종료 후 공유 pipe가 사라졌습니다.")
            }
            precondition(retained.binding == nil && retained.intent?.inputDesired == false && retained.intent?.outputDesired == false)
            precondition(f.count("forwardingDisconnect") == 0 && f.count("forwardingRevoke") == 0)
            checks += 7
        }

        do {
            let f = try Fixture(root: root), connection = Connection()
            defer { f.finish() }
            try await f.start()
            let observed = await f.observe(connection)
            precondition(observed != nil)
            let gate = NativeGate(); f.gate = gate
            f.flag("http-pending")
            await f.until { gate.entered }
            let polls = f.count("forwardingSnapshot")
            await f.until(seconds: 7) { f.count("forwardingEvidence", operation: "renew", id: connection.id) >= 1 }
            precondition(f.count("forwardingSnapshot") >= polls + 3,
                         "긴 participant 준비 중에도 HTTP snapshot 관측과 연결별 renew가 진행됩니다.")
            precondition(f.count("forwardingCommit") == 0 && f.nativeStops == 1,
                         "늦은 native 준비 완료는 만료된 epoch를 commit할 수 없습니다.")
            gate.release()
            try await Task.sleep(for: .milliseconds(100))
            precondition(f.count("forwardingCommit") == 0)
            checks += 4
        }

        for invalidation in ["protection", "configuration", "boot", "close"] {
            let f = try Fixture(root: root), connection = Connection()
            defer { f.finish() }
            try await f.start()
            let observed = await f.observe(connection)
            precondition(observed != nil)
            let gate = NativeGate(); f.gate = gate
            let pending = await f.submit(connection)
            precondition(pending != nil)
            await f.until { gate.entered }
            switch invalidation {
            case "protection": f.runtime.invalidateProtection()
            case "configuration":
                f.startup.participants.register(.native, bootId: UUID(), control: .init(
                    fenceAndQuiesce: { request in .init(request, state: .unknown, facts: .unknown) }, inspect: { _ in nil }))
            case "boot":
                f.flag("wrong-boot")
                await f.until { f.privacy.participants.snapshot.boots[.relay] == nil }
            default: f.close(connection)
            }
            gate.release()
            try await Task.sleep(for: .milliseconds(200))
            precondition(f.count("forwardingCommit") == 0, "무효화된 work는 늦은 commit을 제출하지 않습니다.")
            checks += 2
        }

        for unavailable in ["HAL", "Sentry"] {
            let f = try Fixture(root: root), connection = Connection()
            defer { f.finish() }
            try await f.start()
            if unavailable == "HAL" { f.hal.readFails = true } else { f.surfaceGood = false }
            let observed = await f.observe(connection)
            precondition(observed?.catalog?.schemaVersion == 2, "보호 불가 상태에서도 catalog는 조회할 수 있습니다.")
            let pending = await f.submit(connection)
            precondition(pending != nil)
            await f.until { f.protectionPreparations > 0 }
            try await Task.sleep(for: .milliseconds(100))
            precondition(f.count("forwardingCommit") == 0)
            let visible = await f.observe(connection)
            precondition(visible?.catalog?.bootstrap.snapshot.binding?.phase != .active,
                         "모의 readback으로 실제 보호 불가 상태를 active로 위장하면 안 됩니다.")
            checks += 3
        }

        do {
            let f = try Fixture(root: root), connection = Connection()
            defer { f.finish() }
            try await f.start(arm: false)
            let observed = await f.observe(connection)
            precondition(observed?.catalog?.schemaVersion == 2 && !f.privacy.latched,
                         "관측 자체가 최초 보호 arm을 가장하면 안 됩니다.")
            let generation = f.privacy.forwardingPrivacyGeneration
            _ = await f.submit(connection)
            await f.until { f.protectionPreparations == 1 }
            precondition(f.privacy.forwardingPrivacyGeneration != generation)
            await f.until { f.count("forwardingConfigure") >= 2 }
            try await Task.sleep(for: .milliseconds(100))
            precondition(f.count("forwardingCommit") == 0,
                         "arm으로 privacyGeneration이 바뀌면 이전 binding의 commit은 거절됩니다.")
            let staleCredential = await f.submit(connection)
            precondition(staleCredential == nil, "새 보호 세대에서는 성공한 observe를 다시 요구합니다.")
            let refreshed = await f.observe(connection)
            precondition(refreshed?.catalog?.schemaVersion == 2)
            let fresh = await f.submit(connection)
            precondition(fresh != nil)
            await f.until { f.count("forwardingCommit") == 1 }
            precondition(f.protectionPreparations == 1, "새 구성에서 실제 보호를 유지하며 binding이 수렴합니다.")
            checks += 8
        }

        do {
            let f = try Fixture(root: root), connection = Connection()
            defer { f.finish() }
            try await f.start()
            guard let relay = LocalAudioRelayLaunch.lastRelay else { preconditionFailure() }
            _ = await f.observe(connection)
            let configured = f.count("forwardingConfigure")
            f.flag("hold-snapshot")
            let snapshots = f.count("forwardingSnapshot")
            let blocker = Task { @MainActor in await relay.forwardingSnapshot() }
            await f.until { f.count("forwardingSnapshot") > snapshots }
            var admitted = true
            let queued = Task { @MainActor in
                await relay.forwardingConfigure(privacyGeneration: f.privacy.forwardingPrivacyGeneration,
                    admission: { admitted })
            }
            try await Task.sleep(for: .milliseconds(30))
            admitted = false
            f.flag("release-snapshot")
            _ = await blocker.value
            let refused = await queued.value
            precondition(refused == nil && f.count("forwardingConfigure") == configured,
                "대기 중 무효화된 configure는 공유 pipe에 송신하지 않습니다.")
            let after = await f.observe(connection)
            precondition(after != nil, "거절된 configure가 다른 연결의 공유 pipe를 닫으면 안 됩니다.")
            checks += 2
        }

        for exhaustRetries in [false, true] {
            let f = try Fixture(root: root), connection = Connection()
            defer { f.finish() }
            try await startWithPrepareGate(f)
            guard let relay = LocalAudioRelayLaunch.lastRelay else { preconditionFailure() }
            let observed = await f.observe(connection)
            precondition(observed != nil)
            let gate = NativeGate()
            f.gate = gate
            let pending = await f.submit(connection)
            guard case .accepted(let value) = pending?.result, let binding = value.binding else { preconditionFailure() }
            await f.until { gate.entered }
            let configured = f.count("forwardingConfigure")
            let blockers = exhaustRetries ? 4 : 1
            for index in 1...blockers {
                let blocker = Task { @MainActor in
                    await relay.forwardingPrepare(binding, until: ContinuousClock.now.advanced(by: .seconds(5)))
                }
                await f.until { FileManager.default.fileExists(atPath:
                    f.directory.appendingPathComponent("prepare-entered-\(index)").path) }
                if index == 1 { f.runtime.invalidateProtection() }
                try await Task.sleep(for: .milliseconds(3900))
                precondition(f.count("forwardingConfigure") == configured,
                             "FIFO 대기 중 만료된 configure가 송신되면 안 됩니다.")
                precondition(relay.forwardingConfiguration(privacyGeneration: f.privacy.forwardingPrivacyGeneration) != nil,
                             "송신 전 만료는 살아 있는 공유 pipe를 닫으면 안 됩니다.")
                f.flag("prepare-release-\(index)")
                guard case .accepted = await blocker.value else { preconditionFailure("FIFO 점유 RPC 종료 실패") }
            }
            if exhaustRetries {
                try await Task.sleep(for: .seconds(3))
                let blocked = await f.observe(connection)
                precondition(blocked == nil && f.count("forwardingConfigure") == configured,
                             "재시도 상한 이후에는 FIFO가 풀려도 다시 송신하지 않습니다.")
            } else {
                await f.until(seconds: 5) { f.count("forwardingConfigure") == configured + 1 }
                let recovered = await f.observe(connection)
                precondition(recovered?.catalog?.schemaVersion == 2,
                             "같은 살아 있는 relay는 FIFO가 풀린 뒤 다시 구성됩니다.")
            }
            checks += 4
        }

        let allDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for directory in allDirectories {
            let log = (try? String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
            precondition(!log.contains(String(repeating: "R", count: 43)) && !log.contains("\"credential\":"),
                         "credential 원문은 로그에 남지 않습니다.")
        }
        print("PASS \(checks)개 격리 runtime 회귀 조건. 실제 HAL·서비스·설치·기기 수용을 의미하지 않습니다.")
    }
}
