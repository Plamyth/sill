import Foundation
import StreamProtocol

enum IPadAudioRoutePolicy {
    enum Input: String, CaseIterable, Identifiable {
        case off, iPadMicrophone
        var id: Self { self }
        var title: String { self == .off ? "전송 안 함" : "이 iPad의 현재 마이크" }
    }

    enum Output: String, CaseIterable, Identifiable {
        case off, iPadPlayback
        var id: Self { self }
        var title: String { self == .off ? "재생 안 함" : "iPad 스피커·연결된 출력" }
    }

    struct Selection: Equatable {
        var input: Input = .off
        var output: Output = .off
    }

    struct Capabilities: Equatable {
        var microphone: Bool
        var playback: Bool
        var inputs: [Input] { microphone ? [.off, .iPadMicrophone] : [.off] }
        var outputs: [Output] { playback ? [.off, .iPadPlayback] : [.off] }
    }

    struct Context: Equatable {
        let peer: ObjectIdentifier
        let source: StreamSource
        let microphone: MicrophoneScope?
    }

    struct Actions: Equatable {
        var microphone: Bool?
        var playback: Bool?
    }

    struct Authorization: Equatable {
        let id = UUID()
        let context: Context
    }

    struct Presentation {
        let identity: IPadAudioRouteAcknowledgments.Identity?
        let context: Context
    }

    enum Problem: LocalizedError {
        case changedConnection, inputUnavailable, outputUnavailable, microphoneBusy, cleanupRequired, permissionDenied

        var errorDescription: String? {
            switch self {
            case .changedConnection: "연결이나 화면이 바뀌었습니다. 현재 연결에서 다시 선택하세요."
            case .inputUnavailable: "현재 연결에서는 iPad 마이크를 전송할 수 없습니다."
            case .outputUnavailable: "현재 연결에서는 Mac 오디오를 재생할 수 없습니다."
            case .microphoneBusy: "마이크 중지가 확인된 뒤 다시 켜세요."
            case .cleanupRequired: "마이크 정리를 마친 뒤 다시 선택하세요."
            case .permissionDenied: "iPad 설정에서 마이크 권한을 허용한 뒤 다시 선택하세요."
            }
        }
    }

    static func actions(for selection: Selection, capabilities: Capabilities, current: Selection,
                        canStartMicrophone: Bool, cleanupRequired: Bool) throws -> Actions {
        if selection.input != .off && !capabilities.microphone { throw Problem.inputUnavailable }
        if selection.output != .off && !capabilities.playback { throw Problem.outputUnavailable }
        if cleanupRequired && (selection.input != .off || current.input != .off) { throw Problem.cleanupRequired }
        let microphone = selection.input != .off
        let playback = selection.output != .off
        if microphone && current.input == .off && !canStartMicrophone { throw Problem.microphoneBusy }
        return Actions(microphone: selection.input == current.input ? nil : microphone,
                       playback: selection.output == current.output ? nil : playback)
    }
}

struct IPadAudioRouteOffer {
    private var offered: IPadAudioRouteAcknowledgments.Identity?
    private var phoneOffered = false

    mutating func offerForPhone(connected: Bool, hasSource: Bool, foreground: Bool) -> Bool {
        if !connected { phoneOffered = false; return false }
        guard !phoneOffered, hasSource, foreground else { return false }
        phoneOffered = true
        return true
    }

    mutating func offer(identity: IPadAudioRouteAcknowledgments.Identity?, acknowledged: Bool,
                        hasSource: Bool, supported: Bool, foreground: Bool) -> Bool {
        guard let identity, !acknowledged, offered != identity,
              hasSource, supported, foreground else { return false }
        offered = identity
        return true
    }

    mutating func openedManually(identity: IPadAudioRouteAcknowledgments.Identity?) {
        offered = identity
    }
}

/// This record acknowledges an explanation. It contains no media selection or permission grant.
struct IPadAudioRouteAcknowledgments {
    struct Identity: Codable, Equatable {
        let macID: String
        let pin: Data

        init?(macID: String, pin: Data) {
            guard !macID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  macID.utf8.count <= 256, pin.count == 32 else { return nil }
            self.macID = macID
            self.pin = pin
        }
    }

    private struct Record: Codable {
        let version: Int
        var identities: [Identity]
    }

    static let key = "iPadAudioRouteAcknowledgments.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var identities: [Identity] {
        guard let data = defaults.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1,
              record.identities.allSatisfy({ Identity(macID: $0.macID, pin: $0.pin) != nil }) else { return [] }
        return record.identities
    }

    func contains(_ identity: Identity) -> Bool { identities.contains(identity) }

    func acknowledge(_ identity: Identity) {
        var next = identities
        guard !next.contains(identity) else { return }
        // A new trust pin replaces the old acknowledgment for this Mac.
        next.removeAll { $0.macID == identity.macID }
        next.append(identity)
        if let data = try? JSONEncoder().encode(Record(version: 1, identities: next)) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
