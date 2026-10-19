import Foundation
import StreamProtocol

@MainActor
private final class CatalogQueue {
    var pending: [CheckedContinuation<TestDestinationCatalog, Error>] = []
    func next() async throws -> TestDestinationCatalog {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
}

@MainActor
private final class ProbeQueue {
    var pending: [CheckedContinuation<String?, Error>] = []
    func next() async throws -> String? {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
}

@main
struct TestDestinationsChecks {
    static func entry(project: String = "project-a", url: String = "https://example.test/app",
                      checkedAt: String, embed: TestDestinationCatalog.Embed = .blocked) -> TestDestinationCatalog.Entry {
        .init(id: "target", projectId: project, projectLabel: "프로젝트 \(project)", label: "시험 화면",
              url: url, owner: "owner-thread", reachability: .reachable, embed: embed, checkedAt: checkedAt)
    }

    static func refuses(_ expected: TestDestinationsError, context: String = "", _ work: () throws -> Void) {
        do { try work(); preconditionFailure("Expected refusal: \(expected) \(context)") }
        catch let error as TestDestinationsError {
            precondition(error == expected, "Unexpected refusal: \(error)")
        } catch { preconditionFailure("Unexpected error: \(error)") }
    }

    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Async operation did not reach expected state")
    }

    @MainActor static func main() async throws {
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let first = entry(checkedAt: timestamp)
        let catalog = TestDestinationCatalog(observedAt: timestamp, entries: [first])
        let envelope: (String) throws -> TestDestinationsEnvelope = {
            try JSONDecoder().decode(TestDestinationsEnvelope.self, from: Data($0.utf8))
        }
        refuses(.missing) { _ = try envelope("{}").validated(now: now) }
        for malformed in ["null", "[]", "{}", "false", "{\"schema\":\"ccr-test-destinations/v1\",\"entries\":[]}"] {
            refuses(.malformed) { _ = try envelope("{\"testDestinations\":\(malformed)}").validated(now: now) }
        }
        let empty = TestDestinationCatalog(observedAt: timestamp, entries: [])
        let emptyJSON = String(data: try JSONEncoder().encode(empty), encoding: .utf8)!
        let decodedEmpty = try envelope("{\"otherExistingField\":false,\"testDestinations\":\(emptyJSON)}").validated(now: now)
        precondition(decodedEmpty.entries.isEmpty)
        var stale = catalog
        stale.observedAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-46))
        refuses(.stale) { try TestDestinationsPolicy.validate(stale, now: now) }
        var invalidSchema = catalog
        invalidSchema.schema = "unknown"
        refuses(.malformed) { try TestDestinationsPolicy.validate(invalidSchema, now: now) }
        var duplicate = catalog
        duplicate.entries.append(first)
        refuses(.malformed) { try TestDestinationsPolicy.validate(duplicate, now: now) }
        var oldEntry = first
        oldEntry.checkedAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-46))
        refuses(.stale) { _ = try TestDestinationTarget(oldEntry, now: now) }
        oldEntry.checkedAt = nil
        refuses(.stale) { _ = try TestDestinationTarget(oldEntry, now: now) }
        var unreachable = first
        unreachable.reachability = .unreachable
        refuses(.unavailable) { _ = try TestDestinationTarget(unreachable, now: now) }
        let identity = TestDestinationIdentity(first)
        for mutate in [
            { (entry: inout TestDestinationCatalog.Entry) in entry.projectId = "project-b" },
            { (entry: inout TestDestinationCatalog.Entry) in entry.projectLabel = "다른 프로젝트" },
            { (entry: inout TestDestinationCatalog.Entry) in entry.owner = "other-owner" },
            { (entry: inout TestDestinationCatalog.Entry) in entry.url = "https://other.test/app" },
            { (entry: inout TestDestinationCatalog.Entry) in entry.id = "other-target" },
            { (entry: inout TestDestinationCatalog.Entry) in entry.redirectOrigins = ["https://login.example.test"] }
        ] {
            var changed = first
            mutate(&changed)
            refuses(.changed) {
                _ = try TestDestinationsPolicy.revalidate(identity,
                    in: TestDestinationCatalog(observedAt: timestamp, entries: [changed]), now: now)
            }
        }
        let target = try TestDestinationsPolicy.revalidate(identity, in: catalog, now: now)
        precondition(target.entry.embed == .blocked, "Iframe restrictions must not block top-level navigation")
        for value in ["https://example.test/other", "https://EXAMPLE.test:443/login?next=app"] {
            precondition(target.allows(URL(string: value)!))
        }
        for value in ["http://example.test/app", "https://example.test:444/app", "https://other.test/app",
                      "https://user:password@example.test/app", "https://example.test.evil.test/app",
                      "file:///tmp/test", "javascript:alert(1)"] {
            precondition(!target.allows(URL(string: value)!))
        }
        var registered = first
        registered.redirectOrigins = ["https://login.example.test", "https://accounts.example.test:8443"]
        let redirectTarget = try TestDestinationTarget(registered, now: now)
        for value in ["https://example.test/app", "https://login.example.test/sign-in",
                      "https://accounts.example.test:8443/authorize"] {
            precondition(redirectTarget.allows(URL(string: value)!))
        }
        for value in ["http://login.example.test/sign-in", "https://login.example.test:8443/sign-in",
                      "https://accounts.example.test/authorize", "https://login.example.test.evil.test/app"] {
            precondition(!redirectTarget.allows(URL(string: value)!))
        }
        for origins in [["http://login.example.test"], ["https://login.example.test/"],
                        ["https://login.example.test/path"], ["https://login.example.test?next=app"],
                        ["https://login.example.test#app"], ["https://user@login.example.test"],
                        ["https://127.0.0.1"], Array(repeating: "https://login.example.test", count: 9)] {
            var invalid = first
            invalid.redirectOrigins = origins
            refuses(.unsafeURL, context: origins.joined(separator: ",")) { _ = try TestDestinationTarget(invalid, now: now) }
            refuses(.malformed) {
                try TestDestinationsPolicy.validate(TestDestinationCatalog(observedAt: timestamp, entries: [invalid]), now: now)
            }
        }
        var unsafeRedirect = first
        unsafeRedirect.redirectOrigins = ["https://0177.0.0.1"]
        refuses(.unsafeURL) { _ = try TestDestinationTarget(unsafeRedirect, now: now) }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        legacy.removeValue(forKey: "redirectOrigins")
        let legacyEntry = try JSONDecoder().decode(TestDestinationCatalog.Entry.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        precondition(legacyEntry.redirectOrigins.isEmpty)
        for value in ["http://localhost/app", "http://LOCALHOST./app", "http://test.localhost/app",
                      "http://127.1/app", "http://127.0.0.1/app", "http://2130706433/app",
                      "http://0x7f000001/app", "http://0177.0.0.1/app", "http://0.0.0.0/app",
                      "http://[::1]/app", "http://[0:0:0:0:0:0:0:1]/app", "http://[::ffff:127.0.0.1]/app",
                      "http://[::ffff:7f00:1]/app", "http://user@example.test/app", "https://example.test\\@evil.test"] {
            refuses(.unsafeURL, context: value) { _ = try TestDestinationTarget(entry(url: value, checkedAt: timestamp), now: now) }
        }
        _ = try TestDestinationTarget(entry(url: "http://192.168.45.4:8080/app", checkedAt: timestamp), now: now)
        _ = try TestDestinationTarget(entry(url: "https://confirmed-mac.local/app", checkedAt: timestamp), now: now)
        let suite = "ipad-test-destinations-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessionA = TestDestinationSessions.identifier(projectID: "project-a", defaults: defaults)
        precondition(sessionA == TestDestinationSessions.identifier(projectID: "project-a", defaults: defaults))
        precondition(sessionA != TestDestinationSessions.identifier(projectID: "project-b", defaults: defaults))
        precondition(sessionA.uuidString != "00000000-0000-0000-0000-000000000000")
        defaults.set(["project-a": "00000000-0000-0000-0000-000000000000"], forKey: "testDestinations.projectSessions.v1")
        precondition(TestDestinationSessions.identifier(projectID: "project-a", defaults: defaults).uuidString != "00000000-0000-0000-0000-000000000000")

        let queue = CatalogQueue()
        let model = TestDestinationsModel(fetch: { try await queue.next() }, probe: { _ in nil })
        model.refresh()
        await wait { queue.pending.count == 1 }
        model.refresh()
        await wait { queue.pending.count == 2 }
        queue.pending[1].resume(returning: empty)
        await wait { if case .loaded = model.catalog { return true }; return false }
        queue.pending[0].resume(returning: catalog)
        for _ in 0..<10 { await Task.yield() }
        if case .loaded(let latest) = model.catalog { precondition(latest.entries.isEmpty) }
        else { preconditionFailure("Latest catalog lost") }
        model.select(first)
        await wait { queue.pending.count == 3 }
        let other = entry(project: "project-b", checkedAt: timestamp)
        model.select(other)
        await wait { queue.pending.count == 4 }
        queue.pending[3].resume(returning: TestDestinationCatalog(observedAt: timestamp, entries: [other]))
        await wait { if case .ready = model.selection { return true }; return false }
        queue.pending[2].resume(returning: catalog)
        for _ in 0..<10 { await Task.yield() }
        if case .ready(let selected, _) = model.selection { precondition(selected.entry.projectId == "project-b") }
        else { preconditionFailure("Late selection replaced current project") }
        model.select(first)
        await wait { queue.pending.count == 5 }
        model.cancel()
        queue.pending[4].resume(returning: catalog)
        for _ in 0..<10 { await Task.yield() }
        precondition(model.selection == nil, "Dismissal must discard pending results")
        let probes = ProbeQueue()
        let probeModel = TestDestinationsModel(fetch: { catalog }, probe: { _ in try await probes.next() })
        probeModel.select(first)
        await wait { probes.pending.count == 1 }
        probeModel.select(first)
        await wait { probes.pending.count == 2 }
        probes.pending[1].resume(returning: "현재 로그인 안내")
        await wait { if case .ready = probeModel.selection { return true }; return false }
        probes.pending[0].resume(returning: "늦은 로그인 안내")
        for _ in 0..<10 { await Task.yield() }
        if case .ready(_, let notice) = probeModel.selection { precondition(notice == "현재 로그인 안내") }
        else { preconditionFailure("Late HEAD result replaced current selection") }
        probeModel.select(first)
        await wait { probes.pending.count == 3 }
        probeModel.cancel()
        probes.pending[2].resume(returning: nil)
        for _ in 0..<10 { await Task.yield() }
        precondition(probeModel.selection == nil, "Dismissal must discard pending HEAD results")
        print("iPad test destination policy and cancellation checks passed")
    }
}
