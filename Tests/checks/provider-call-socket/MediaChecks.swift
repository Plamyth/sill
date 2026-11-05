import Foundation
import Darwin

enum ProviderCallFailure: Error { case unavailable, expired, invalidFields, superseded }
enum ProviderPeerAnchor {
    enum Policy { case core }
    static func verify(_ fd: Int32, policy: Policy) throws -> Bool {
        guard fcntl(fd, F_GETFD) >= 0 else { throw ProviderCallFailure.unavailable }
        return true
    }
}

@main struct MediaChecks {
    static func frame(_ header: String, pcm: Data = Data()) -> Data {
        let bytes = Data(header.utf8), n = bytes.count + pcm.count + 2
        return Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255),
                     UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]) + bytes + pcm
    }
    static func pair() throws -> (ProviderCallSocket, Int32) {
        var fds: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        for fd in fds {
            precondition(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0)
            var yes: Int32 = 1
            precondition(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(4)) == 0)
        }
        return (ProviderCallSocket(testDescriptor: fds[0]), fds[1])
    }
    static func peerSend(_ bytes: Data, _ fd: Int32) throws {
        try ProviderCallSocket.write(bytes, to: fd, until: ProcessInfo.processInfo.systemUptime + 2)
    }
    static func peerRead(_ count: Int, _ fd: Int32) throws -> Data {
        try ProviderCallSocket.readExactly(count, from: fd, until: ProcessInfo.processInfo.systemUptime + 2)
    }
    static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ name: String) { precondition(value, name); checks += 1; print("PASS \(name)") }
        let ready = frame("{\"kind\":\"ready\"}"), input = frame("{\"kind\":\"input\"}", pcm: Data([1, 0, 2, 0]))
        let output = frame("{\"kind\":\"output\"}", pcm: Data([3, 0, 4, 0]))
        let (socket, peer) = try pair()
        defer { socket.invalidate(); Darwin.close(peer) }
        do { _ = try await socket.receiveMedia(until: ProcessInfo.processInfo.systemUptime + 1); fatalError("media before ready") }
        catch { expect(true, "media cannot start in command mode") }
        try await socket.beginMedia(ready: ready, until: ProcessInfo.processInfo.systemUptime + 1)
        expect(try peerRead(ready.count, peer) == ready, "ready is sent before media")
        let receiver = Task { try await socket.receiveMedia(until: ProcessInfo.processInfo.systemUptime + 3) }
        try await Task.sleep(for: .milliseconds(25))
        do { _ = try await socket.receiveMedia(until: ProcessInfo.processInfo.systemUptime + 1); fatalError("second read") }
        catch { expect(true, "only one pending read is admitted") }
        try await socket.sendMedia(input, until: ProcessInfo.processInfo.systemUptime + 1)
        expect(try peerRead(input.count, peer) == input, "write progresses while read waits")
        try peerSend(output + output, peer)
        expect(try await receiver.value == output, "first frame preserves exact PCM")
        expect(try await socket.receiveMedia(until: ProcessInfo.processInfo.systemUptime + 1) == output, "coalesced frames remain separate")
        do { try await socket.beginMedia(ready: ready, until: ProcessInfo.processInfo.systemUptime + 1); fatalError("second ready") }
        catch { expect(true, "stream cannot transition twice") }
        for bytes in [Data(), Data([0, 0, 18, 0, 0, 1, 123]), frame("{\"x\":1,\"x\":2}"),
                      frame("{\"kind\":\"input\"}", pcm: Data(repeating: 1, count: 481))] {
            do { try await socket.sendMedia(bytes, until: ProcessInfo.processInfo.systemUptime + 1); fatalError("invalid frame") }
            catch { expect(true, "malformed bounded frame refused") }
        }
        for kind in ["oversize", "eof", "timeout"] {
            let (s, p) = try pair()
            defer { s.invalidate(); Darwin.close(p) }
            try await s.beginMedia(ready: ready, until: ProcessInfo.processInfo.systemUptime + 1)
            _ = try peerRead(ready.count, p)
            if kind == "oversize" { try peerSend(Data([255, 255, 255, 255]), p) }
            if kind == "eof" { try peerSend(Data([0, 0, 0, 20, 0, 18, 123]), p); _ = shutdown(p, SHUT_WR) }
            do { _ = try await s.receiveMedia(until: ProcessInfo.processInfo.systemUptime + 0.1); fatalError("failure accepted") }
            catch { expect(true, "\(kind) closes media without fabricated response") }
            do { try await s.sendMedia(input, until: ProcessInfo.processInfo.systemUptime + 1); fatalError("closed socket") }
            catch { expect(true, "failed media cannot resume implicitly") }
        }
        print("MEDIA_RESULT=\(checks); peer authentication stubbed; no Core, Host, device or audio effects")
    }
}
