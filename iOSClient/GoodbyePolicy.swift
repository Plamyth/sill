import Foundation
import StreamProtocol

/// What the connect screen says, and whether this device reconnects, when a session ends: with the
/// Mac's goodbye (kind 22), or without one (the connection just ended). One rule for every route,
/// whether or not a window list came (docs/update-notice-plan.md §7.3). Pure: Foundation and
/// StreamProtocol, checked on its own with swiftc.
///
/// The five reasons hosts have sent since remote access keep their words and their reconnects, and
/// so does "pairingRequired" (pairing at home: Require pairing turned on while this unpaired device
/// was connected; StreamClient+Home ends such a session at home with these words). "update" (a Mac
/// whose device floor is above this device's version, DeviceGate) and any other
/// reason are notices: the host's own words (its `message`, cleaned), shown as the status line, and
/// a reconnect only when the Mac asks for one (`"reconnect":true`); "update" also offers the App
/// Store. Before this rule a reason the device did not know showed "‹Mac› disconnected…" and
/// reconnected at once, so a Mac that refused the device was dialled again and again.
enum GoodbyePolicy {
    struct Outcome: Equatable {
        /// The connect screen's status line.
        var text: String
        /// This device reconnects by itself (StreamClient.Reconnect).
        var reconnect: Bool
        /// That reconnect may dial the saved Mac through the remote door (only a saved Mac).
        var remoteAllowed: Bool
        /// "Update Sill in the App Store" under the status line ("update" only).
        var storeLink = false
        /// The Mac's own words: a goodbye this build shows as the host wrote it. Looked at before a
        /// remote dial's failure rules (RemoteDialPolicy), which know only the older reasons.
        var isNotice: Bool
    }

    /// The longest message shown, in characters (SafeText.label).
    static let messageLimit = 300

    /// The reasons whose words and reconnects are this build's own; "update" and any other reason
    /// are notices.
    static let knownReasons: Set<String> = [Goodbye.quit, Goodbye.removed, Goodbye.remoteOff, Goodbye.internetOff, Goodbye.busy,
                                            Goodbye.pairingRequired]

    /// A goodbye this build shows by the Mac's words: "update", or a reason it does not know (a
    /// kind 22 that did not decode reads as reason "").
    static func isNotice(_ goodbye: Goodbye) -> Bool {
        !knownReasons.contains(goodbye.reason)
    }

    /// The session ended with `goodbye` (nil: no goodbye came). `mac` is what the status line calls
    /// the Mac (its saved name, else its Bonjour name or the address dialled), `device` "iPad" or
    /// "iPhone", `saved` whether the Mac is a saved one (its remote door may be dialled).
    static func outcome(_ goodbye: Goodbye?, mac: String, device: String, saved: Bool) -> Outcome {
        guard let goodbye else {
            return Outcome(text: saved ? "\(mac) 연결이 끊어졌습니다. 연결이 가능해지면 자동으로 다시 연결합니다."
                                       : "\(mac) 연결이 끊어졌습니다. Mac이 다시 나타나면 자동으로 연결합니다.",
                           reconnect: true, remoteAllowed: saved, isNotice: false)
        }
        switch goodbye.reason {
        case Goodbye.quit:
            return Outcome(text: "\(mac)에서 Sill이 종료되었습니다. 다시 실행되면 이 \(device)에서 자동으로 연결합니다.",
                           reconnect: true, remoteAllowed: saved, isNotice: false)
        case Goodbye.removed:
            return Outcome(text: "\(mac)에서 이 \(device)의 등록을 해제했습니다. 다시 사용하려면 페어링하세요.",
                           reconnect: false, remoteAllowed: false, isNotice: false)
        case Goodbye.remoteOff:
            return Outcome(text: "\(mac)에서 원격 접근을 껐습니다.", reconnect: true, remoteAllowed: false, isNotice: false)
        case Goodbye.internetOff:
            return Outcome(text: "\(mac)에서 인터넷 연결 허용을 껐습니다. VPN으로 연결하세요.",
                           reconnect: true, remoteAllowed: false, isNotice: false)
        case Goodbye.busy:
            return Outcome(text: "\(mac)에 이미 기기 8대가 연결되어 있습니다.", reconnect: true, remoteAllowed: saved, isNotice: false)
        case Goodbye.pairingRequired:
            // Only at a home door over TLS, to an unpaired device: a tap on its row asks to pair.
            return Outcome(text: "\(mac)에 연결하려면 이제 페어링이 필요합니다. Mac을 탭해 이 \(device)와 페어링하세요.",
                           reconnect: false, remoteAllowed: false, isNotice: false)
        case Goodbye.update:
            // The host always sends its message; these words are for one that does not.
            var own = "\(mac)을 계속 사용하려면 이 \(device)의 Sill을 업데이트하세요."
            if let floor = goodbye.minimumVersion.flatMap({ SillVersion($0) }) { own += " 버전 \(floor) 이상이 필요합니다." }
            return Outcome(text: message(goodbye) ?? own, reconnect: goodbye.reconnect == true, remoteAllowed: saved,
                           storeLink: true, isNotice: true)
        default:
            let reconnect = goodbye.reconnect == true
            let own = reconnect ? "\(mac)에서 연결을 종료했습니다. 연결이 가능해지면 자동으로 다시 연결합니다."
                                : "\(mac)에서 연결을 종료했습니다. Mac을 탭해 다시 시도하세요."
            return Outcome(text: message(goodbye) ?? own, reconnect: reconnect, remoteAllowed: saved, isNotice: true)
        }
    }

    /// The host's message as the status line shows it: one line of at most `messageLimit`
    /// characters, without control or bidirectional characters; nil when nothing printable is left.
    /// Shown as plain text (SwiftUI's Text of a String): no Markdown, no link from the host.
    static func message(_ goodbye: Goodbye) -> String? {
        let text = SafeText.label(goodbye.message ?? "", limit: messageLimit)
        return text.isEmpty ? nil : text
    }
}
