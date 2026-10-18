import Foundation
import CoreGraphics

@MainActor enum WindowCatalog {
    static var physical = [UInt32(1), UInt32(3)]
    static func physicalDisplayIDs() -> [UInt32] { physical }
    static func onlineDisplayIDs() -> [UInt32] { physical + [13] }
}

@MainActor final class VirtualDisplay {
    var displayID: UInt32 = 13
    var isAlive = true
    var bounds = CGRect(x:3432,y:-98,width:1350,height:976)
    var widthPt = 1350
    var heightPt = 976
    var scale = 2
    var pixelSize = (width:2700,height:1952)
}

@MainActor enum CoreGraphicsFixture {
    static var active: Int32 = 1
    static var mirror: UInt32 = 0
    static var mirrorSet: Int32 = 0
    static var refresh: Double = 60
    static var bounds: [UInt32:CGRect] = [1:CGRect(x:0,y:0,width:1512,height:982),
        3:CGRect(x:1512,y:-98,width:1920,height:1080)]
    static var configuredIDs = [UInt32]()
    static var display: VirtualDisplay?
}
typealias CGDisplayConfigRef = Int
enum CGResult { case success }
enum CGConfiguration { case forSession }
@MainActor func fixtureCGBeginDisplayConfiguration(_ config: inout Int?) -> CGResult { config = 1; return .success }
@MainActor func fixtureCGConfigureDisplayMirrorOfDisplay(_ config: Int, _ id: UInt32, _ mirror: UInt32) -> CGResult {
    CoreGraphicsFixture.configuredIDs.append(id); CoreGraphicsFixture.mirror = mirror; return .success
}
@MainActor func fixtureCGConfigureDisplayOrigin(_ config: Int, _ id: UInt32, _ x: Int32, _ y: Int32) -> CGResult {
    CoreGraphicsFixture.configuredIDs.append(id)
    CoreGraphicsFixture.display?.bounds.origin = CGPoint(x: Double(x), y: Double(y)); return .success
}
func fixtureCGCancelDisplayConfiguration(_ config: Int) {}
func fixtureCGCompleteDisplayConfiguration(_ config: Int, _ option: CGConfiguration) -> CGResult { .success }
struct Mode { var refreshRate: Double }
let fixturekCGNullDirectDisplay: UInt32 = 0
@MainActor func fixtureCGDisplayIsActive(_ id: UInt32) -> Int32 { CoreGraphicsFixture.active }
@MainActor func fixtureCGDisplayMirrorsDisplay(_ id: UInt32) -> UInt32 { CoreGraphicsFixture.mirror }
@MainActor func fixtureCGDisplayIsInMirrorSet(_ id: UInt32) -> Int32 { CoreGraphicsFixture.mirrorSet }
@MainActor func fixtureCGDisplayCopyDisplayMode(_ id: UInt32) -> Mode? { Mode(refreshRate:CoreGraphicsFixture.refresh) }
@MainActor func fixtureCGDisplayBounds(_ id: UInt32) -> CGRect { CoreGraphicsFixture.bounds[id] ?? .zero }

@MainActor enum AdapterFixture {
    enum Failure: Error { case noPhysicalDisplay, configuration, verification }
    // VALID_ADAPTER
}

enum Source { case none, desktop }
@MainActor final class CatalogFixture {
    var displayInventory = DisplayInventory()
    var display: UInt32? { displayInventory.current?.displayID }
}
@MainActor final class ServerFixture {
    var resets = 0
    func resetForNewStream() { resets += 1 }
}
@MainActor final class PointerFixture {
    var cleared = false
    func setGeometry(_ geometry: Int?, fps: Int) { cleared = geometry == nil }
}
@MainActor final class ExtendedFixture { func checkDisplay() {} }
@MainActor final class CoordinatorFixture {
    var synthetic = false
    let extendedDesktop = ExtendedFixture()
    var active = Source.desktop
    var videoEpoch: UUID? = UUID()
    var inputGeneration = "old"
    let server = ServerFixture()
    let pointer = PointerFixture()
    let catalog = CatalogFixture()
    let fps = 60
    var switching = false
    var restarts = 0
    var stops = 0
    func broadcastList() {}
    func revokeRemoteAudio(reason: String) async {}
    func select(_ source: Source, bringForward: Bool = true) async {
        active = source
        if source == .desktop { restarts += 1; videoEpoch = UUID() } else { stops += 1 }
    }
    // COORDINATOR_ADAPTER
}
