import Foundation
import Darwin
import Security
import CryptoKit

struct ProviderPeerPolicy {
    let application: URL
    let identifier: String
    let team: String
    static let installed = ProviderPeerPolicy(application: URL(fileURLWithPath: "/Applications/CCR Sill.app"),
        identifier: "com.ambrion.sillcanvas.mac", team: "ZPTXHJ866D")
}

struct ProviderPeerAnchor {
    enum Failure: String, Error {
        case invalidSocket, peerUnavailable, signatureMismatch, pathMismatch, installedCodeMismatch, peerChanged
    }
    private static func token(_ fd: Int32) throws -> Data {
        var value = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &value, &size) == 0,
              size == MemoryLayout<audit_token_t>.size else { throw Failure.invalidSocket }
        return withUnsafeBytes(of: value) { Data($0) }
    }
    private static func requireLiveSocket(_ fd: Int32) throws {
        var byte: UInt8 = 0
        let received = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        guard received > 0 || received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else {
            throw Failure.peerUnavailable
        }
    }
    private static func information(_ code: SecStaticCode) throws -> [String: Any] {
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let value = raw as? [String: Any] else { throw Failure.signatureMismatch }
        return value
    }
    static func verify(_ fd: Int32, policy: ProviderPeerPolicy = .installed) throws -> [String: Any] {
        try requireLiveSocket(fd)
        let before = try token(fd)
        var dynamic: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: before] as CFDictionary, [], &dynamic) == errSecSuccess,
              let dynamic else { throw Failure.peerUnavailable }
        var requirement: SecRequirement?
        let text = "identifier \"\(policy.identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(policy.team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(dynamic, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw Failure.signatureMismatch
        }
        var running: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamic, [], &running) == errSecSuccess, let running else { throw Failure.peerUnavailable }
        var rawPath: CFURL?
        guard SecCodeCopyPath(running, [], &rawPath) == errSecSuccess, let rawPath else { throw Failure.pathMismatch }
        let canonical = policy.application.standardizedFileURL
        guard canonical.resolvingSymlinksInPath() == canonical,
              (rawPath as URL).standardizedFileURL == canonical else { throw Failure.pathMismatch }
        var installed: SecStaticCode?
        guard SecStaticCodeCreateWithPath(canonical as CFURL, [], &installed) == errSecSuccess,
              let installed,
              SecStaticCodeCheckValidity(installed, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw Failure.installedCodeMismatch
        }
        let liveInfo = try information(running), diskInfo = try information(installed)
        guard let liveHash = liveInfo[kSecCodeInfoUnique as String] as? Data, !liveHash.isEmpty,
              liveHash == diskInfo[kSecCodeInfoUnique as String] as? Data,
              liveInfo[kSecCodeInfoIdentifier as String] as? String == policy.identifier,
              liveInfo[kSecCodeInfoTeamIdentifier as String] as? String == policy.team else {
            throw Failure.installedCodeMismatch
        }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              size == MemoryLayout<pid_t>.size, pid > 0,
              try token(fd) == before,
              SecCodeCheckValidity(dynamic, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw Failure.peerChanged
        }
        try requireLiveSocket(fd)
        return ["schemaVersion": 1, "state": "verified", "pid": Int(pid),
                "application": canonical.path, "bundleIdentifier": policy.identifier, "teamIdentifier": policy.team,
                "codeDirectoryHash": liveHash.map { String(format: "%02x", $0) }.joined(),
                "peerTokenSHA256": SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined()]
    }
}
