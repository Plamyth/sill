import Foundation
import Network
import SwiftUI
import StreamProtocol

final class FakeInput {
    var allowed = true
    var releases = 0
    func releaseAll() { releases += 1 }
}
final class FakeAudio {
    var stops = 0
    func stop() { stops += 1 }
}
final class StreamClient {
    var visionDisplayApplicationActive = true
    enum Binding { case awaiting, presented(VideoEpoch) }
    var visionInputBinding = Binding.awaiting
    let visionInputSession: FakeInput? = FakeInput()
    let visionAudio = FakeAudio()
    let link = SessionLink()
    var connection: NWConnection? {
        get { link.connection }
        set { bindVisionDisplays(to: newValue); link.connection = newValue }
    }
    var releaseCallbacks: [(Bool) -> Void] = []
    var draftRevocations = 0
    var microphoneStops = 0
    var choicesSent = 0
    var active = StreamSource.none
    func revokeVisionTextDrafts() { draftRevocations += 1 }
    func microphoneSourceWillChange() { microphoneStops += 1 }
    func afterVisionInputRelease(_ completion: @escaping (Bool) -> Void) { releaseCallbacks.append(completion) }
    func send(_ kind: StreamMessageKind, _ payload: Data) {
        link.send(StreamMessage(kind: kind, timestamp: 0, isKeyframe: false, payload: payload).serialized())
    }
    func automatic(_ source: StreamSource) { request(source) }
    // PRODUCTION_DISPLAY_STORAGE
    // PRODUCTION_REQUEST
    // PRODUCTION_RESIGN
}
