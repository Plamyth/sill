import Foundation
import CoreFoundation
import Network
import StreamProtocol

typealias CGWindowID = UInt32
struct FakeWindow { var frame: CGRect }
struct FakeDisplay { let displayID: UInt32; var frame: CGRect }
final class GeometryCatalog {
    var display: FakeDisplay? = FakeDisplay(displayID: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    var cached = FakeWindow(frame: CGRect(x: 5, y: 5, width: 800, height: 600))
    func window(id: UInt32) -> FakeWindow? { cached }
}
final class GeometryStage { var isStaged = false; var captureRectOnScreen: CGRect? }
struct GeometryPointer { var hasTestPointer = false }
enum LiveGeometry {
    static var window: CGRect? = CGRect(x: 0, y: 0, width: 800, height: 600)
    static var display = CGRect(x: 0, y: 0, width: 800, height: 600)
    static var active: UInt32 = 1
    static var queries = 0
}
func CGDisplayIsActive(_ id: UInt32) -> UInt32 { LiveGeometry.active }
func CGDisplayBounds(_ id: UInt32) -> CGRect { LiveGeometry.queries += 1; return LiveGeometry.display }
final class GeometryServer {
    var resets = 0
    func resetForNewStream() { resets += 1 }
}
final class GeometryInjector {
    var output: [(InputEvent, CGRect)] = []
    var down: Set<UInt16> = []
    func isUpOfSomethingDown(_ event: InputEvent, from: KeyStrokes.Device) -> Bool {
        if case .key(let usage, false, _) = event { return down.contains(usage) }
        return false
    }
    func apply(_ event: InputEvent, in rect: CGRect, from: KeyStrokes.Device) {
        if case .key(let usage, let pressed, _) = event {
            if pressed { down.insert(usage) } else { down.remove(usage) }
        }
        output.append((event, rect))
    }
    func chord(keyCode: UInt16, flags: UInt64) {}
    func releaseInput(of: KeyStrokes.Device) {}
}
final class GeometryGesture {
    var inputs = 0
    func input(_ event: InputEvent) { inputs += 1 }
}
final class GeometryHost {
    var desktopScope: String?
    var inputFence = SourceInputFence<ObjectIdentifier>()
    let gestureChords = GeometryGesture()
    var focusEffects = 0
    static func gestureInput(_ event: InputEvent) -> InputEvent { event }
    func raiseIfInteracting(_ event: InputEvent) { focusEffects += 1 }
    func desktopInputMayActivate(_ event: InputEvent) {}
    var active = StreamSource.window(42)
    var inputGeneration = "generation-A"
    var videoEpoch: VideoEpoch?
    var switching = false
    var shuttingDown = false
    var geometryRecovery = GeometryRecovery.idle
    var synthetic = false
    var virtualDisplay = false
    var pointer = GeometryPointer()
    let catalog = GeometryCatalog()
    let stage = GeometryStage()
    let server = GeometryServer()
    let injector = GeometryInjector()
    var rectCache: (id: UInt32, rect: CGRect, at: CFAbsoluteTime)?
    var selections: [(StreamSource, Bool)] = []
    var catalogs = 0
    var heldInput: [Held] = []
    var holdUntil = 0.0
    static let testPatternRect = CGRect(x: 0, y: 0, width: 1512, height: 949)
    func broadcastList() { catalogs += 1 }
    func select(_ source: StreamSource, bringForward: Bool = false) async { selections.append((source, bringForward)) }
    static func liveBounds(of: UInt32) -> CGRect? { LiveGeometry.queries += 1; return LiveGeometry.window }
    func logClick(_ event: InputEvent, in rect: CGRect) {}
    // METHODS
}
