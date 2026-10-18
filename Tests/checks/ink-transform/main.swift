import Foundation
import PencilKit
import AppKit

@main struct InkTransformCheck {
    @MainActor static func main() throws {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/"))
        var failures = 0
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        let points = [CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 50), CGPoint(x: 70, y: 80)]
            .enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) * 0.1,
                    size: CGSize(width: 3, height: 3), opacity: 1,
                    force: 0.25 + Double(index) * 0.1, azimuth: 0, altitude: 1)
            }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1))
        for (name, transform) in [
            ("identity", CGAffineTransform.identity),
            ("translated", CGAffineTransform(translationX: 100, y: -50)),
            ("rotated", CGAffineTransform(rotationAngle: .pi / 2)),
            ("scaled", CGAffineTransform(scaleX: 2, y: 0.5))
        ] {
            let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path, transform: transform)
            let drawing = PKDrawing(strokes: [stroke])
            let store = CanvasStore()
            store.scene = CanvasScene()
            store.drawing = PKDrawing()
            store.updateDrawing(drawing)
            let raw = Data(base64Encoded: store.scene.drawingBase64)!
            let restored = try PKDrawing(data: raw)
            let exported = store.scene.strokes[0]
            let source = restored.strokes[0]
            let expected = source.path.map { $0.location.applying(source.transform) }
            check(zip(exported.points, expected).allSatisfy {
                abs($0.x - Double($1.x)) < 0.0001 && abs($0.y - Double($1.y)) < 0.0001
            }, "\(name) exported coordinates match serialized drawing world coordinates")
            check(exported.id == source.id && exported.createdAt == source.path.creationDate,
                "\(name) stable stroke identity and time preserved")
            check(zip(exported.points, source.path).allSatisfy { abs($0.pressure - Double($1.force)) < 0.0001 },
                "\(name) pressure preserved")
            check(store.drawing == drawing && restored == drawing,
                "\(name) original PencilKit drawing preserved")
            let encoded = try JSONEncoder().encode(store.scene)
            let decoded = try JSONDecoder().decode(CanvasScene.self, from: encoded)
            check(decoded.strokes == store.scene.strokes, "\(name) structured scene round trip")
        }
        print("INK_TRANSFORM_CHECKS total=\(checks) failed=\(failures)")
        if failures > 0 { exit(1) }
    }
}
