import Foundation
import Darwin

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0, CommandLine.arguments.count == 2 else { exit(2) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let name = Array(CommandLine.arguments[1].utf8) + [0]
guard name.count <= MemoryLayout.size(ofValue: address.sun_path) else { exit(2) }
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: name + Array(repeating: 0, count: $0.count - name.count)) }
let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard result == 0 else { exit(2) }
var wait = timeval(tv_sec: 10, tv_usec: 0)
_ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
var byte: UInt8 = 0
_ = read(fd, &byte, 1)
close(fd)
