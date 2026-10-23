import Foundation
import Darwin

let result: [String: Any]
let status: Int32
do {
    guard CommandLine.arguments.count == 1 else { throw ProviderPeerAnchor.Failure.invalidSocket }
    result = try ProviderPeerAnchor.verify(3)
    status = 0
} catch {
    result = ["schemaVersion": 1, "state": "refused", "reason":
        (error as? ProviderPeerAnchor.Failure)?.rawValue ?? "peerUnavailable"]
    status = 2
}
if let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), bytes.count <= 2048 {
    FileHandle.standardOutput.write(bytes + Data([10]))
    exit(status)
}
exit(2)
