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
    private var offered = false

    mutating func offer(connected: Bool, hasSource: Bool, foreground: Bool) -> Bool {
        if !connected { offered = false; return false }
        guard !offered, hasSource, foreground else { return false }
        offered = true
        return true
    }
}
