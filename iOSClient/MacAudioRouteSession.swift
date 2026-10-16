import Foundation
import StreamProtocol

struct MacAudioRouteSession {
    enum Outcome {
        case waiting
        case answered(AudioRouteResult)
        case timedOut

        var isSuccess: Bool {
            switch self {
            case .answered(.applied), .answered(.unchanged): true
            default: false
            }
        }

        var title: String {
            switch self {
            case .waiting: "Mac의 적용 결과를 기다리는 중…"
            case .answered(.applied): "Mac 시스템 기본 장치가 변경되었습니다."
            case .answered(.unchanged): "Mac 시스템 기본 장치가 이미 선택되어 있습니다."
            case .answered(.stale): "Mac 장치 목록이 바뀌었습니다. 다시 선택하세요."
            case .answered(.invalid): "Mac이 선택한 장치를 사용할 수 없다고 응답했습니다."
            case .answered(.conflict): "Mac의 기본 장치가 다른 곳에서 변경되었습니다. 다시 선택하세요."
            case .answered(.unavailable): "Mac 오디오 장치를 읽을 수 없습니다."
            case .answered(.failed): "Mac 기본 장치 변경에 실패했습니다."
            case .answered(.rollbackFailed): "Mac 기본 장치 변경에 실패했고 이전 상태 복원도 확인되지 않았습니다. 현재 기본값을 확인하세요."
            case .timedOut: "Mac의 적용 응답을 받지 못해 변경 여부를 알 수 없습니다. 현재 기본값을 새로고침하세요."
            }
        }
    }

    enum Problem: LocalizedError {
        case unavailable, pending, noChange, invalidInput, invalidOutput

        var errorDescription: String? {
            switch self {
            case .unavailable: "Mac 오디오 장치 목록을 아직 받지 못했습니다."
            case .pending: "Mac의 이전 적용 결과를 기다리고 있습니다."
            case .noChange: "변경할 Mac 입력 또는 출력 장치를 선택하세요."
            case .invalidInput: "선택한 Mac 입력 장치는 현재 목록에 없습니다."
            case .invalidOutput: "선택한 Mac 출력 장치는 현재 목록에 없습니다."
            }
        }
    }

    private(set) var peer: ObjectIdentifier?
    private(set) var state: AudioRouteState?
    private(set) var pending: AudioRouteSelection?
    private(set) var outcome: Outcome?

    mutating func bind(_ peer: ObjectIdentifier?) {
        guard self.peer != peer else { return }
        self.peer = peer
        state = nil
        pending = nil
        outcome = nil
    }

    mutating func receive(_ next: AudioRouteState, from peer: ObjectIdentifier) {
        guard self.peer == peer, Self.valid(next) else { return }
        state = next
        if let pending, next.answering == pending.requestID, let result = next.result {
            self.pending = nil
            outcome = .answered(result)
        }
    }

    mutating func request(inputUID: String?, outputUID: String?) throws -> AudioRouteSelection {
        guard let state, state.available else { throw Problem.unavailable }
        guard pending == nil else { throw Problem.pending }
        let input = inputUID == state.defaults.inputUID ? nil : inputUID
        let output = outputUID == state.defaults.outputUID ? nil : outputUID
        guard input != nil || output != nil else { throw Problem.noChange }
        if let input, !state.endpoints.contains(where: { $0.uid == input && $0.input }) { throw Problem.invalidInput }
        if let output, !state.endpoints.contains(where: { $0.uid == output && $0.output }) { throw Problem.invalidOutput }
        let request = AudioRouteSelection(revision: state.revision, expected: state.defaults,
                                          inputUID: input, outputUID: output)
        guard AudioRoutingPolicy.valid(request) else { throw Problem.unavailable }
        pending = request
        outcome = .waiting
        return request
    }

    mutating func expire(_ requestID: UUID, on peer: ObjectIdentifier) {
        guard self.peer == peer, pending?.requestID == requestID else { return }
        pending = nil
        outcome = .timedOut
        state = nil
    }

    private static func valid(_ state: AudioRouteState) -> Bool {
        guard state.endpoints.count <= AudioRoutingPolicy.maxEndpoints,
              (state.available || state.endpoints.isEmpty),
              [state.defaults.inputUID, state.defaults.outputUID].compactMap({ $0 }).allSatisfy(AudioRoutingPolicy.validUID) else { return false }
        var seen = Set<String>()
        return state.endpoints.allSatisfy {
            AudioRoutingPolicy.validUID($0.uid) && seen.insert($0.uid).inserted &&
            !$0.name.isEmpty && $0.name.utf8.count <= AudioRoutingPolicy.maxNameBytes &&
            !$0.name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
            ($0.input || $0.output)
        }
    }
}
