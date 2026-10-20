import Foundation

@main
struct Checks {
    static func main() {
        let own = IPBytes.parse("192.168.8.2")!
        let interfaces = OriginPolicy.Interfaces(kind: ["en0": .lan, "utun8": .tunnel, "awdl0": .peerToPeer],
            owner: [own: "en0"], prefixes: [("en0", IPBytes.parse("192.168.8.0")!, 24)])
        func resolve(_ remote: String, _ scope: String? = nil, direct: Bool = false) -> AutomaticLocalAccess? {
            .resolve(remote: remote, localAddress: "192.168.8.2", scope: scope,
                     interfaces: interfaces, cables: [:], directWireless: direct)
        }
        precondition(resolve("192.168.8.3") == .localNetwork(interface: "en0"))
        precondition(resolve("192.168.9.3") == nil)
        precondition(resolve("10.0.0.3") == nil)
        precondition(resolve("100.110.1.2", "utun8") == nil)
        precondition(resolve("192.168.8.3", "utun8") == nil)
        precondition(resolve("192.168.8.3", "unknown") == nil)
        precondition(resolve("fe80::2", "awdl0") == nil)
        precondition(resolve("fe80::2", "awdl0", direct: true) == .directWireless(interface: "awdl0"))
        precondition(resolve("8.8.8.8", "awdl0", direct: true) == nil)
        precondition(resolve("127.0.0.1") == .loopback && resolve("::1") == .loopback)
        precondition(resolve("not-an-address") == nil && resolve("8.8.8.8") == nil)
        let cable = CableLink.Ancestry(ncm: true, vendor: CableLink.appleVendor, productName: "iPad", serial: "fixture", session: 1)
        let source = "fe80::2"
        var wired = OriginPolicy.Interfaces(kind: ["en14": .lan], owner: [IPBytes.parse("fe80::1")!: "en14"])
        func overCable(_ source: String, _ cable: CableLink.Ancestry) -> AutomaticLocalAccess? {
            .resolve(remote: source, localAddress: "fe80::1", scope: "en14", interfaces: wired,
                     cables: ["en14": cable], directWireless: false)
        }
        precondition(overCable(source, cable) == .cable(deviceID: CableLink.deviceID(serial: "fixture")))
        precondition(overCable("fe80::1", cable) == nil)
        precondition(overCable("169.254.1.2", cable) == nil)
        var wrong = cable; wrong.vendor = 0
        precondition(overCable(source, wrong) == nil)
        wrong = cable; wrong.ncm = false
        precondition(overCable(source, wrong) == nil)
        wrong = cable; wrong.serial = nil
        precondition(overCable(source, wrong) == nil)
        wrong = cable; wrong.productName = "USB Ethernet Adapter"
        precondition(overCable(source, wrong) == nil)
        wired.kind["en14"] = .tunnel
        precondition(overCable(source, cable) == nil)
        print("자동 로컬 연결의 실제 경로 정책 검사 통과 · 소켓·TLS·실기기 수용 아님")
    }
}
