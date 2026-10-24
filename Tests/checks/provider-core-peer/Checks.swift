import Foundation
import Darwin

@main enum Checks {
    static func main() throws {
        let core = ProviderPeerPolicy.core
        let renderer = core.renderer!
        let cases = ["renderer", "main", "custom", "installed-policy", "foreign-path", "other-helper",
            "wrong-team", "wrong-id", "parent-team", "parent-id", "parent-signature", "parent-path",
            "old-code", "disk-signature", "dynamic-signature", "final-dynamic", "empty-hash",
            "changed-token", "descriptor-replaced", "peer-closed"]
        for name in cases {
            var pair: [Int32] = [-1, -1]
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            defer { pair.forEach { close($0) } }
            Fixture.fd = pair[0]; Fixture.peer = pair[1]
            Fixture.checks = []; Fixture.tokenReads = 0
            Fixture.finalDynamicInvalid = name == "final-dynamic"
            Fixture.replaceDescriptor = name == "descriptor-replaced"
            Fixture.closePeer = name == "peer-closed"
            Fixture.changedToken = name == "changed-token"
            var policy = core
            var path = renderer.application
            var identifier = renderer.identifier
            if name == "main" { path = core.application; identifier = core.identifier }
            if name == "custom" {
                policy = ProviderPeerPolicy(application: URL(fileURLWithPath: "/Fixture.app"), identifier: "fixture", team: "FIXTURE")
                path = policy.application; identifier = policy.identifier
            }
            if name == "installed-policy" {
                policy = .installed; path = policy.application; identifier = policy.identifier
                precondition(policy.renderer == nil && policy.identifier == "com.ambrion.sillcanvas.mac" && policy.team == "ZPTXHJ866D")
            }
            if name == "foreign-path" { path = URL(fileURLWithPath: "/foreign/node") }
            if name == "other-helper" {
                path = core.application.appendingPathComponent("Contents/Frameworks/Obsidian Helper (GPU).app")
            }
            Fixture.live = SecCode(path, identifier, policy.team)
            let installed = SecCode(path, identifier, policy.team)
            let parent = SecCode(core.application, core.identifier, core.team)
            Fixture.disk = [path.path: installed]
            if path != core.application { Fixture.disk[core.application.path] = parent }
            switch name {
            case "wrong-team": Fixture.live.team = "WRONGTEAM"
            case "wrong-id": Fixture.live.identifier = "md.obsidian.helper.GPU"
            case "parent-team": parent.team = "WRONGTEAM"
            case "parent-id": parent.identifier = "wrong.parent"
            case "parent-signature": parent.valid = false
            case "parent-path": parent.path = URL(fileURLWithPath: "/Other.app")
            case "old-code": installed.hash = Data([4, 5, 6])
            case "disk-signature": installed.valid = false
            case "dynamic-signature": Fixture.live.valid = false
            case "empty-hash": Fixture.live.hash = Data(); installed.hash = Data()
            default: break
            }
            let expected: String?
            switch name {
            case "renderer", "main", "custom", "installed-policy": expected = nil
            case "foreign-path", "other-helper": expected = "pathMismatch"
            case "wrong-team", "wrong-id", "dynamic-signature": expected = "signatureMismatch"
            case "final-dynamic", "changed-token", "descriptor-replaced": expected = "peerChanged"
            case "peer-closed": expected = "peerUnavailable"
            default: expected = "installedCodeMismatch"
            }
            var failure: String?
            do {
                let result = try ProviderPeerAnchor.verify(pair[0], policy: policy)
                precondition(result["application"] as? String == path.path)
                precondition(result["bundleIdentifier"] as? String == identifier)
                precondition(Fixture.checks.filter { $0 == "dynamic" }.count == 2)
                precondition(Fixture.checks.filter { $0.hasPrefix("disk:") }.count == (name == "renderer" ? 2 : 1))
                precondition(Fixture.tokenReads == 2)
            } catch { failure = (error as? ProviderPeerAnchor.Failure)?.rawValue ?? "unexpected" }
            precondition(failure == expected, "\(name): \(String(describing: failure)) != \(String(describing: expected))")
            if name == "foreign-path" || name == "other-helper" { precondition(Fixture.checks.isEmpty) }
            print("PASS \(name) \(failure ?? "verified")")
        }
        print("FIXTURE_RESULT={\"checks\":\(cases.count),\"signatureBackend\":\"deterministic-test-double\",\"realSocketSyscalls\":true,\"actualInstalledAcceptance\":false,\"keyAccess\":0}")
    }
}
