import Foundation
import Network
import StreamProtocol
import SwiftUI

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
    static var noAutoDesktop = true
    var resumeSource: StreamSource?
    var requested: [StreamSource] = []
    func request(_ source: StreamSource) { requested.append(source) }
    var active = StreamSource.desktop
    var windows: [WindowInfo] = []
    var connected = true
    weak var visionInputSession: VisionInputSession?
    var visionMovePreparation: UUID?
    let visionInputDebt = VisionInputDebt()
    // BINDING_STATE
    let link = SessionLink()
    let queue = DispatchQueue(label: "fixture.input")
    var moving: Move?
    var lastInputAt = 0.0
    var notes: [InputEvent] = []
    var completions = 0
    var retained: [(peer: NWConnection, header: StreamHeader, payload: Data)] = []
    func pointerNoteSent(_ event: InputEvent) { notes.append(event) }
    func resetVisionAudio() {}
    func finishMoveAfterInputDrain(_ c: NWConnection, kind: MoveKind, kept: [(header: StreamHeader, payload: Data)]) {
        // MOVE_INPUT_RESET
        moving = nil
        completions += 1
        let old = link.connection!
        link.handOver(from: old, to: c, fencePing: Data([12, 1]), nonce: Data([1]))
        retained += kept.map { (peer: c, header: $0.header, payload: $0.payload) }
    }
    func finish(_ c: NWConnection, kept: [(header: StreamHeader, payload: Data)] = []) { finishMove(c, kind: .toCable, kept: kept) }
    func deliverRetainedCatalogs() {
        let pending = retained
        retained = []
        for message in pending where message.header.kind == .windowList {
            if let list = Wire.decode(WindowList.self, from: message.payload) {
                _ = applyVisionInputCatalog(list, from: message.peer)
            }
        }
    }
    func catalog(_ list: WindowList, from peer: NWConnection?) -> Bool { applyVisionInputCatalog(list, from: peer) }
    static var hello: Data { helloPayload }
    static var iPadHello: Data { iPadHelloPayload }
    // EXTRACTED
}
