import Foundation
import CoreGraphics

@MainActor enum WindowCatalog {
    static var physical = [UInt32(1), UInt32(3)]
    static func physicalDisplayIDs() -> [UInt32] { physical }
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
}
struct Mode { var refreshRate: Double }
let fixturekCGNullDirectDisplay: UInt32 = 0
@MainActor func fixtureCGDisplayIsActive(_ id: UInt32) -> Int32 { CoreGraphicsFixture.active }
@MainActor func fixtureCGDisplayMirrorsDisplay(_ id: UInt32) -> UInt32 { CoreGraphicsFixture.mirror }
@MainActor func fixtureCGDisplayIsInMirrorSet(_ id: UInt32) -> Int32 { CoreGraphicsFixture.mirrorSet }
@MainActor func fixtureCGDisplayCopyDisplayMode(_ id: UInt32) -> Mode? { Mode(refreshRate:CoreGraphicsFixture.refresh) }
@MainActor func fixtureCGDisplayBounds(_ id: UInt32) -> CGRect { CoreGraphicsFixture.bounds[id] ?? .zero }

@MainActor enum AdapterFixture {
    // VALID_ADAPTER
}
