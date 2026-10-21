import Foundation
import Darwin
import Security

struct LocalCursorProcessIdentity: Equatable {
    enum Application: Equatable { case obsidian, cursor }
    let application: Application
    let pid: pid_t
    let uid: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String
    let signingIdentifier: String
    let codeHash: Data

    static func capture(_ pid: pid_t, application: Application, validateRoot: Bool = true) -> Self? {
        guard pid > 0 else { return nil }
        var process = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, size) == size,
              process.pbi_uid == geteuid(), process.pbi_start_tvsec > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(cString: path)
        let root: URL, identifier: String, requirementText: String
        switch application {
        case .obsidian:
            root = URL(fileURLWithPath: "/Applications/Obsidian.app")
            identifier = "md.obsidian"
            requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"6JSW4SJWN9\""
        case .cursor:
            root = URL(fileURLWithPath: "/Applications/Cursor.app")
            identifier = "com.todesktop.230313mzl4w4u92"
            requirementText = "anchor apple generic and (certificate leaf[subject.OU] = \"VDXQ22DGB9\" or certificate leaf[subject.OU] = \"DCNK4UB866\")"
        }
        guard root.resolvingSymlinksInPath().path == root.path,
              executable.hasPrefix(root.path + "/Contents/"),
              URL(fileURLWithPath: executable).resolvingSymlinksInPath().path == executable else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        if validateRoot {
            var disk: SecStaticCode?
            var rootRequirement: SecRequirement?
            let text = "identifier \"\(identifier)\" and (\(requirementText))"
            guard SecStaticCodeCreateWithPath(root as CFURL, [], &disk) == errSecSuccess, let disk,
                  SecRequirementCreateWithString(text as CFString, [], &rootRequirement) == errSecSuccess,
                  let rootRequirement, SecStaticCodeCheckValidity(disk, [], rootRequirement) == errSecSuccess else { return nil }
        }
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, [], requirement) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let actual = values[kSecCodeInfoIdentifier as String] as? String,
              let hash = values[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { return nil }
        let allowed = actual == identifier ||
            (application == .obsidian && (actual == "md.obsidian.helper" || actual.hasPrefix("md.obsidian.helper.")))
        guard allowed else { return nil }
        var after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size) == size,
              after.pbi_uid == process.pbi_uid, after.pbi_start_tvsec == process.pbi_start_tvsec,
              after.pbi_start_tvusec == process.pbi_start_tvusec else { return nil }
        return Self(application: application, pid: pid, uid: process.pbi_uid,
            startSeconds: process.pbi_start_tvsec, startMicroseconds: process.pbi_start_tvusec,
            executable: executable, signingIdentifier: actual, codeHash: hash)
    }

    var isCurrent: Bool { Self.capture(pid, application: application, validateRoot: false) == self }
}

struct LocalCursorPeer: Equatable {
    let process: LocalCursorProcessIdentity

    static func capture(socketDescriptor: Int32) -> Self? {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(socketDescriptor, &uid, &gid) == 0, uid == geteuid(),
              getsockopt(socketDescriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              length == MemoryLayout<pid_t>.size,
              let process = LocalCursorProcessIdentity.capture(pid, application: .obsidian), process.uid == uid else { return nil }
        var after: pid_t = 0
        length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socketDescriptor, SOL_LOCAL, LOCAL_PEERPID, &after, &length) == 0,
              after == pid, process.isCurrent else { return nil }
        return Self(process: process)
    }

    func isCurrent(socketDescriptor: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return getpeereid(socketDescriptor, &uid, &gid) == 0 && uid == process.uid &&
            getsockopt(socketDescriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 &&
            size == MemoryLayout<pid_t>.size && pid == process.pid && process.isCurrent
    }
}
