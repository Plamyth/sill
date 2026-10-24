import Foundation
import Darwin
import Security

@main enum ActualCore {
    static func main() throws {
        let path = NSHomeDirectory() + "/Library/Application Support/CodexControlRoom/command.sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProviderPeerAnchor.Failure.invalidSocket }
        var result: [String: Any] = [:]
        do {
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let name = Array(path.utf8) + [0]
            guard name.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw ProviderPeerAnchor.Failure.invalidSocket
            }
            withUnsafeMutableBytes(of: &address.sun_path) {
                $0.copyBytes(from: name + Array(repeating: 0, count: $0.count - name.count))
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw ProviderPeerAnchor.Failure.invalidSocket }
            var token = audit_token_t()
            var size = socklen_t(MemoryLayout<audit_token_t>.size)
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
                  size == MemoryLayout<audit_token_t>.size else { throw ProviderPeerAnchor.Failure.invalidSocket }
            let before = withUnsafeBytes(of: token) { Data($0) }
            var guest: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: before] as CFDictionary,
                [], &guest) == errSecSuccess, let guest else { throw ProviderPeerAnchor.Failure.peerUnavailable }
            var code: SecStaticCode?
            var rawPath: CFURL?
            var rawInfo: CFDictionary?
            guard SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
                  SecCodeCopyPath(code, [], &rawPath) == errSecSuccess, let rawPath,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                    &rawInfo) == errSecSuccess, let info = rawInfo as? [String: Any] else {
                throw ProviderPeerAnchor.Failure.peerUnavailable
            }
            result["observedPath"] = (rawPath as URL).path
            result["observedIdentifier"] = info[kSecCodeInfoIdentifier as String]
            result["observedTeam"] = info[kSecCodeInfoTeamIdentifier as String]
            result["observedCDHash"] = (info[kSecCodeInfoUnique as String] as? Data)?.map {
                String(format: "%02x", $0)
            }.joined()
            do {
                result["predicate"] = try ProviderPeerAnchor.verify(fd, policy: .core)
                result["state"] = "verified"
            } catch {
                result["state"] = "refused"
                result["reason"] = (error as? ProviderPeerAnchor.Failure)?.rawValue ?? "unexpected"
            }
            if result["state"] as? String == "verified" {
                let core = ProviderPeerPolicy.core
                let renderer = core.renderer!
                let policies: [(String, ProviderPeerPolicy, ProviderPeerAnchor.Failure)] = [
                    ("main-only", ProviderPeerPolicy(application: core.application, identifier: core.identifier,
                        team: core.team), .pathMismatch),
                    ("wrong-path", ProviderPeerPolicy(application: core.application, identifier: core.identifier,
                        team: core.team, renderer: .init(application: core.application.appendingPathComponent(
                            "Contents/Frameworks/Obsidian Helper (GPU).app"), identifier: renderer.identifier)), .pathMismatch),
                    ("wrong-team", ProviderPeerPolicy(application: core.application, identifier: core.identifier,
                        team: "AAAAAAAAAA", renderer: renderer), .installedCodeMismatch),
                    ("wrong-renderer-id", ProviderPeerPolicy(application: core.application, identifier: core.identifier,
                        team: core.team, renderer: .init(application: renderer.application,
                            identifier: "md.obsidian.helper.GPU")), .signatureMismatch),
                    ("wrong-parent-id", ProviderPeerPolicy(application: core.application, identifier: "wrong.parent",
                        team: core.team, renderer: renderer), .installedCodeMismatch)
                ]
                var refused: [String: String] = [:]
                for (name, policy, expected) in policies {
                    do {
                        _ = try ProviderPeerAnchor.verify(fd, policy: policy)
                        fatalError("잘못된 정책이 수용됐다: \(name)")
                    } catch {
                        guard error as? ProviderPeerAnchor.Failure == expected else { throw error }
                        refused[name] = expected.rawValue
                    }
                }
                result["counterexamples"] = refused
            }
            size = socklen_t(MemoryLayout<audit_token_t>.size)
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
                  withUnsafeBytes(of: token, { Data($0) }) == before else {
                throw ProviderPeerAnchor.Failure.peerChanged
            }
            result["auditTokenStable"] = true
        }
        result["commandBytesSent"] = 0
        result["socketClosed"] = true
        result["hostInstalledOrReloaded"] = false
        result["uiKeyVoiceHALCallEffects"] = 0
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) + Data([10]))
    }
}
