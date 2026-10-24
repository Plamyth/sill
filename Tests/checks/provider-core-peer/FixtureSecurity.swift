import Foundation
import Darwin
import CoreFoundation

struct SecCSFlags: OptionSet {
    let rawValue: UInt32
}
let kSecCSStrictValidate: UInt32 = 1
let kSecCSSigningInformation: UInt32 = 2
let errSecSuccess: Int32 = 0
let kSecGuestAttributeAudit = "audit" as CFString
let kSecCodeInfoUnique = "hash" as CFString
let kSecCodeInfoIdentifier = "identifier" as CFString
let kSecCodeInfoTeamIdentifier = "team" as CFString

final class SecCode {
    var path: URL
    var identifier: String
    var team: String
    var hash = Data([1, 2, 3])
    var valid = true
    init(_ path: URL, _ identifier: String, _ team: String) {
        self.path = path
        self.identifier = identifier
        self.team = team
    }
}
typealias SecStaticCode = SecCode
typealias SecRequirement = String

enum Fixture {
    static var live = SecCode(.init(fileURLWithPath: "/unused"), "unused", "unused")
    static var disk: [String: SecCode] = [:]
    static var checks: [String] = []
    static var finalDynamicInvalid = false
    static var replaceDescriptor = false
    static var closePeer = false
    static var changedToken = false
    static var tokenReads = 0
    static var fd: Int32 = -1
    static var peer: Int32 = -1
}

func SecCodeCopyGuestWithAttributes(_ host: SecCode?, _ attributes: CFDictionary,
    _ flags: SecCSFlags, _ output: inout SecCode?) -> Int32 {
    precondition((attributes as NSDictionary)[kSecGuestAttributeAudit] is Data)
    output = Fixture.live
    return 0
}
func SecCodeCopyStaticCode(_ code: SecCode, _ flags: SecCSFlags, _ output: inout SecStaticCode?) -> Int32 {
    output = code
    return 0
}
func SecCodeCopyPath(_ code: SecStaticCode, _ flags: SecCSFlags, _ output: inout CFURL?) -> Int32 {
    output = code.path as CFURL
    return 0
}
func SecRequirementCreateWithString(_ text: CFString, _ flags: SecCSFlags,
    _ output: inout SecRequirement?) -> Int32 {
    output = text as String
    return 0
}
func matches(_ code: SecCode, _ requirement: SecRequirement?) -> Bool {
    guard let requirement else { return false }
    return code.valid && requirement == "identifier \"\(code.identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(code.team)\""
}
func SecCodeCheckValidity(_ code: SecCode, _ flags: SecCSFlags, _ requirement: SecRequirement?) -> Int32 {
    precondition(flags.rawValue == kSecCSStrictValidate)
    Fixture.checks.append("dynamic")
    if Fixture.checks.filter({ $0 == "dynamic" }).count == 2 {
        if Fixture.finalDynamicInvalid { return -1 }
        if Fixture.closePeer { shutdown(Fixture.peer, SHUT_RDWR) }
    }
    return matches(code, requirement) ? 0 : -1
}
func SecStaticCodeCreateWithPath(_ path: CFURL, _ flags: SecCSFlags,
    _ output: inout SecStaticCode?) -> Int32 {
    output = Fixture.disk[(path as URL).path]
    return output == nil ? -1 : 0
}
func SecStaticCodeCheckValidity(_ code: SecStaticCode, _ flags: SecCSFlags,
    _ requirement: SecRequirement?) -> Int32 {
    precondition(flags.rawValue == kSecCSStrictValidate)
    Fixture.checks.append("disk:" + code.path.path)
    return matches(code, requirement) ? 0 : -1
}
func SecCodeCopySigningInformation(_ code: SecStaticCode, _ flags: SecCSFlags,
    _ output: inout CFDictionary?) -> Int32 {
    precondition(flags.rawValue == kSecCSSigningInformation)
    if Fixture.replaceDescriptor {
        let other = open("/dev/null", O_RDONLY)
        precondition(other >= 0 && dup2(other, Fixture.fd) == Fixture.fd)
        close(other)
        Fixture.replaceDescriptor = false
    }
    output = ["hash": code.hash, "identifier": code.identifier, "team": code.team] as CFDictionary
    return 0
}
func fixtureGetSockOpt(_ fd: Int32, _ level: Int32, _ option: Int32,
    _ value: UnsafeMutableRawPointer, _ length: UnsafeMutablePointer<socklen_t>) -> Int32 {
    let result = Darwin.getsockopt(fd, level, option, value, length)
    if level == SOL_LOCAL && option == LOCAL_PEERTOKEN {
        Fixture.tokenReads += 1
        if result == 0 && Fixture.changedToken && Fixture.tokenReads == 2 {
            value.assumingMemoryBound(to: UInt8.self).pointee ^= 1
        }
    }
    return result
}
