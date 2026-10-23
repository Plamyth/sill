import Foundation
import Darwin
import Security

func probe(_ fd: Int32) throws -> [String: Any] {
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
          length == MemoryLayout<audit_token_t>.size else { throw NSError(domain: "PeerAnchor", code: 1) }
    let before = withUnsafeBytes(of: token) { Data($0) }
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: before] as CFDictionary, [], &code) == errSecSuccess,
          let code else { throw NSError(domain: "PeerAnchor", code: 2) }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
        throw NSError(domain: "PeerAnchor", code: 7)
    }
    var path: CFURL?
    guard SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path else {
        throw NSError(domain: "PeerAnchor", code: 3)
    }
    var pid: pid_t = 0
    var pidLength = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0,
          pidLength == MemoryLayout<pid_t>.size, pid > 0 else { throw NSError(domain: "PeerAnchor", code: 4) }
    var requirement: SecRequirement?
    let text = "identifier \"com.ambrion.sillcanvas.mac\" and anchor apple generic and certificate leaf[subject.OU] = \"ZPTXHJ866D\""
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
          let requirement else { throw NSError(domain: "PeerAnchor", code: 5) }
    let requirementMatches = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
          withUnsafeBytes(of: token, { Data($0) }) == before else { throw NSError(domain: "PeerAnchor", code: 6) }
    let observedPath = (path as URL).standardizedFileURL.resolvingSymlinksInPath().path
    return ["schemaVersion": 1, "osPeerIdentified": true, "peerPID": pid,
            "peerPath": observedPath, "requiredSignatureMatches": requirementMatches,
            "hostTrusted": false, "identityKeyRead": false]
}

do {
    let data = try JSONSerialization.data(withJSONObject: probe(3), options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
} catch {
    print("{\"hostTrusted\":false,\"osPeerIdentified\":false}")
    exit(2)
}
