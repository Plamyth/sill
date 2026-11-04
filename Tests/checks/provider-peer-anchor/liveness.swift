import Foundation
import Darwin

var pollCalls = 0

func poll(_ descriptors: UnsafeMutablePointer<pollfd>!, _ count: nfds_t, _ timeout: Int32) -> Int32 {
    pollCalls += 1
    let mode = CommandLine.arguments[2]
    if mode.hasPrefix("eintr-") && pollCalls == 1 {
        errno = EINTR
        return -1
    }
    if mode == "poll-error" {
        errno = EIO
        return -1
    }
    if mode == "pollerr" {
        descriptors.pointee.revents = Int16(POLLERR)
        return 1
    }
    return Darwin.poll(descriptors, count, timeout)
}

@main enum LivenessChecks {
    static func main() {
        let fd = Int32(CommandLine.arguments[1])!
        if CommandLine.arguments[2] == "closed-fd" { Darwin.close(fd) }
        var value: [String: Any] = ["helperPID": getpid()]
        do {
            try ProviderPeerAnchor.checkLiveness(fd)
            value["state"] = "live"
        } catch {
            value["state"] = "refused"
            value["reason"] = (error as? ProviderPeerAnchor.Failure)?.rawValue ?? "unexpected"
        }
        value["pollCalls"] = pollCalls
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
        _ = readLine()
    }
}
