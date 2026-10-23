import Foundation
import Darwin

@main enum FixtureVerifier {
    static func main() {
        do {
            guard CommandLine.arguments.count == 4 else { exit(2) }
            let policy = ProviderPeerPolicy(application: URL(fileURLWithPath: CommandLine.arguments[1]),
                identifier: CommandLine.arguments[2], team: CommandLine.arguments[3])
            let result = try ProviderPeerAnchor.verify(3, policy: policy)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        } catch {
            print("{\"state\":\"refused\"}")
            exit(2)
        }
    }
}
