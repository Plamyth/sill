import Foundation
import CryptoKit

struct Data32: Hashable, Sendable {
    let data: Data

    init?(_ data: Data) {
        guard data.count == 32 else { return nil }
        self.data = data
    }
}

/// 연결 경로의 주체다. 등록된 앱 키나 TLS 인증 성공을 뜻하지 않는다.
enum AutomaticDevicePrincipal: Hashable, Sendable {
    case tailnet(userId: UInt64, nodeStableId: String)
    /// 부모가 실제 CableLink 증거를 검사한 뒤에만 만든다.
    case cable(deviceId: String)
    /// 부모가 LAN 경로와 이번 소켓의 실제 TLS 인증서를 결합한 식별이다.
    /// 영구 앱 키 등록이나 Tailnet 원격 권한으로 승격하지 않는다.
    case localNetwork(transportFingerprint: Data32)

    /// 종류별 namespace를 입력에 포함한 64자리 소문자 hex다. 실제 TLS fingerprint와 혼용하지 않는다.
    var stableIdentifier: String {
        let namespace: String
        let fields: [Data]
        switch self {
        case .tailnet(let userId, let nodeStableId):
            namespace = "sill-principal-tailnet-v1"
            fields = [Data(String(userId).utf8), Data(nodeStableId.utf8)]
        case .cable(let deviceId):
            namespace = "sill-principal-cable-v1"
            fields = [Data(deviceId.utf8)]
        case .localNetwork(let fingerprint):
            namespace = "sill-principal-local-network-v1"
            fields = [fingerprint.data]
        }
        var input = Data(namespace.utf8)
        for field in fields {
            input.append(0)
            var count = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &count) { input.append(contentsOf: $0) }
            input.append(field)
        }
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}
