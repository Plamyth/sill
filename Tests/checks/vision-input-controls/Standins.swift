import Foundation
import Network
import StreamProtocol

enum Wire {
    static func encode<T: Encodable>(_ value: T) -> Data { try! JSONEncoder().encode(value) }
}
enum StreamMessageKind: UInt8 { case input = 8, ping = 12 }
struct StreamHeader {}
struct StreamMessage {
    let kind: StreamMessageKind
    let timestamp: Double
    let isKeyframe: Bool
    let payload: Data
    func serialized() -> Data { Data([kind.rawValue]) + payload }
}
final class InputOverlayProxy { var view: InputOverlayView? }
final class InputOverlayView {
    var latchedModifiers: KeyModifiers = []
    var forwarded = ForwardedKeys()
    func resignFirstResponder() -> Bool { true }
    // OVERLAY_DRAIN
}
final class StreamClient {
    enum Source { case none, desktop, window }
    enum MoveKind { case fromDirect, toCable, toWifi, fromRemote }
    struct Move { let connection: NWConnection }
    var active = Source.desktop
    var connected = true
    weak var visionInputSession: VisionInputSession?
    var visionMovePreparation: UUID?
    let visionInputDebt = VisionInputDebt()
    let link = SessionLink()
    let queue = DispatchQueue(label: "fixture.input")
    var moving: Move?
    var lastInputAt = 0.0
    var notes: [InputEvent] = []
    var completions = 0
    func pointerNoteSent(_ event: InputEvent) { notes.append(event) }
    func resetVisionAudio() {}
    func finishMoveAfterInputDrain(_ c: NWConnection, kind: MoveKind, kept: [(header: StreamHeader, payload: Data)]) {
        moving = nil
        completions += 1
        let old = link.connection!
        link.handOver(from: old, to: c, fencePing: Data([12, 1]), nonce: Data([1]))
    }
    func finish(_ c: NWConnection) { finishMove(c, kind: .toCable, kept: []) }
    // EXTRACTED
}
