import Foundation
import Darwin

@main struct Checks {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: Bool) { precondition(condition); checks += 1 }
        check(LocalCursorPeer.capture(socketDescriptor: -1) == nil)
        var pair: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        check(LocalCursorPeer.capture(socketDescriptor: pair[0]) == nil)
        check(LocalCursorProcessIdentity.capture(getpid(), application: .obsidian) == nil)
        check(LocalCursorProcessIdentity.capture(getpid(), application: .cursor) == nil)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CCR Sill/LocalInput")
        let before = FileManager.default.fileExists(atPath: root.path)
        var callbacks = 0
        let server = LocalCursorUnixChannel(hostIsCanonical: { false }, onOpen: { _ in callbacks += 1 },
            onRequest: { _, _ in callbacks += 1 }, onClose: { _ in callbacks += 1 })
        check(!server.start())
        check(FileManager.default.fileExists(atPath: root.path) == before && callbacks == 0)
        server.stop()
        print("PASS \(checks) actual local peer rejection and canonical-start checks; no production listener or input")
    }
}
