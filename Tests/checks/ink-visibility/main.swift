import Foundation
import PencilKit
import AppKit

@main struct InkVisibilityCheck {
    @MainActor static func main() throws {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/"))
        print("ISOLATION support=\(support.path)")
        var failures = 0
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        let points = (0..<5).map { i in
            PKStrokePoint(location: CGPoint(x: i * 25, y: 40), timeOffset: Double(i) * 0.1,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 0.3 + Double(i) * 0.1,
                azimuth: 0, altitude: 1)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1))
        let full = NSBezierPath(rect: CGRect(x: -20, y: 0, width: 140, height: 80))
        let islands = NSBezierPath(rect: CGRect(x: 10, y: 0, width: 25, height: 80))
        islands.appendRect(CGRect(x: 65, y: 0, width: 25, height: 80))
        let empty = NSBezierPath(rect: CGRect(x: 200, y: 0, width: 20, height: 80))
        for (name, mask) in [("nil", nil), ("full", full), ("empty", empty), ("islands", islands)] as [(String, NSBezierPath?)] {
            let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path, mask: mask)
            print("SDK \(name) mask=\(stroke.mask != nil) ranges=\(stroke.maskedPathRanges) bounds=\(stroke.renderBounds)")
            for r in stroke.maskedPathRanges {
                print("SDK endpoint \(path.interpolatedPoint(at:r.lowerBound).location) .. \(path.interpolatedPoint(at:r.upperBound).location)")
            }
            let store = CanvasStore()
            store.scene = CanvasScene()
            store.drawing = PKDrawing()
            let drawing = PKDrawing(strokes: [stroke])
            store.updateDrawing(drawing)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.scene)) as! [String: Any]
            let exported = (json["strokes"] as! [[String: Any]])[0]
            check(exported["visibility"] != nil, "\(name) actual Store exports known visibility")
            check(store.drawing == drawing, "\(name) original drawing retained")
        }
        print("INK_VISIBILITY_CHECKS total=\(checks) failed=\(failures)")
        if failures > 0 { exit(1) }
    }
}
