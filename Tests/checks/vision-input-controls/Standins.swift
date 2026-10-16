import Foundation
import Network
import StreamProtocol

enum ClientStatsReporter { static let deviceName = "Vision fixture" }
final class InputOverlayProxy { var view: InputOverlayView? }
final class InputOverlayView {
    var latchedModifiers: KeyModifiers = []
    var forwarded = ForwardedKeys()
    func resignFirstResponder() -> Bool { true }
    // OVERLAY_DRAIN
}
final class StreamClient {
    enum MoveKind { case fromDirect, toCable, toWifi, fromRemote }
    struct Move { let connection: NWConnection }
    var active = StreamSource.desktop
    var windows: [WindowInfo] = []
    var connected = true
    weak var visionInputSession: VisionInputSession?
    var visionMovePreparation: UUID?
    let visionInputDebt = VisionInputDebt()
    private var visionInputGeneration: String?
    let link = SessionLink()
    let queue = DispatchQueue(label: "fixture.input")
    var moving: Move?
    var lastInputAt = 0.0
    var notes: [InputEvent] = []
    var completions = 0
    func pointerNoteSent(_ event: InputEvent) { notes.append(event) }
    func resetVisionAudio() {}
    func finishMoveAfterInputDrain(_ c: NWConnection, kind: MoveKind, kept: [(header: StreamHeader, payload: Data)]) {
        // MOVE_INPUT_RESET
        moving = nil
        completions += 1
        let old = link.connection!
        link.handOver(from: old, to: c, fencePing: Data([12, 1]), nonce: Data([1]))
    }
    func finish(_ c: NWConnection) { finishMove(c, kind: .toCable, kept: []) }
    func catalog(_ list: WindowList, from peer: NWConnection?) -> Bool { applyVisionInputCatalog(list, from: peer) }
    static var hello: Data { helloPayload }
    static var legacyHello: Data { legacyHelloPayload }
    // EXTRACTED
}
