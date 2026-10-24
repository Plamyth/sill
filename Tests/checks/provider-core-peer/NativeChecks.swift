import Foundation
import Darwin

@main enum NativeChecks {
    static func main() {
        var pair: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { close($0) } }
        for policy in [ProviderPeerPolicy.core, .installed] {
            do {
                _ = try ProviderPeerAnchor.verify(pair[0], policy: policy)
                fatalError("익명 프로세스가 설치 앱으로 수용됐다")
            } catch { precondition(error as? ProviderPeerAnchor.Failure == .pathMismatch) }
        }
        shutdown(pair[1], SHUT_RDWR)
        do {
            _ = try ProviderPeerAnchor.verify(pair[0], policy: .core)
            fatalError("닫힌 peer가 수용됐다")
        } catch { precondition(error as? ProviderPeerAnchor.Failure == .peerUnavailable) }
        do {
            _ = try ProviderPeerAnchor.verify(-1, policy: .core)
            fatalError("유효하지 않은 fd가 수용됐다")
        } catch { precondition(error as? ProviderPeerAnchor.Failure == .peerUnavailable) }
        print("NATIVE_RESULT={\"checks\":4,\"signatureBackend\":\"Security.framework\",\"foreignPathRejectedBeforeSignatureValidation\":true,\"actualInstalledAcceptance\":false}")
    }
}
