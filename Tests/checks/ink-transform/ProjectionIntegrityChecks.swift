import Foundation
import PencilKit
import AppKit

@main struct ProjectionIntegrityChecks {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/"))
        let store = CanvasStore()
        store.scene = CanvasScene()
        let controls: [PKStrokePoint] = (0..<4).map { index -> PKStrokePoint in
            let location = CGPoint(x: CGFloat(30 + index * 20), y: CGFloat(24 + index * 10))
            return PKStrokePoint(location: location,
                timeOffset: Double(index) * 0.1, size: CGSize(width: 4, height: 4),
                opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: 1))
        let yellow = PKStroke(ink: PKInk(.pen, color: .yellow), path: path,
            transform: CGAffineTransform(translationX: 8, y: 12))
        precondition(store.updateDrawing(PKDrawing(strokes: [yellow])))
        store.saveNow()
        let sceneURL = support.appendingPathComponent("CanvasScene.json")
        let healthy = store.scene
        let saved = try Data(contentsOf: sceneURL)
        let native = store.drawing
        let encoder = JSONEncoder()
        let session = VoiceSession(threadId: UUID(), sessionId: "projection-fixture", observedAt: "fixture")
        let image = native.image(from: CGRect(x: 0, y: 0, width: 128, height: 100), scale: 1)
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let healthyPacket = try CanvasPacket(scene: healthy, imagePNG: png, session: session)
        var failures = [String]()
        var checks = 0
        func check(_ pass: Bool, _ label: String) {
            checks += 1
            if !pass { failures.append(label) }
            print("\(pass ? "PASS" : "FAIL") \(label)")
        }
        func refused(_ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch { return true }
        }
        let mutations: [(String, (inout CanvasScene) -> Void)] = [
            ("color cyan versus native yellow", { $0.strokes[0].style!.color = .init(red: 0, green: 1, blue: 1, alpha: 1) }),
            ("marker versus native pen", { $0.strokes[0].style!.inkType = PKInk(.marker, color: .cyan).inkType.rawValue }),
            ("transform tx108 versus native8", { $0.strokes[0].style!.transform.tx = 108 }),
            ("sample width12 versus native4", { $0.strokes[0].style!.samples[0].width = 12 }),
            ("sample opacity", { $0.strokes[0].style!.samples[0].opacity = 0.25 }),
            ("native ID", { $0.strokes[0].id = UUID() }),
            ("world points", { $0.strokes[0].points[0].x += 100 }),
            ("pressure", { $0.strokes[0].points[0].pressure = 0.9 }),
            ("creation date", { $0.strokes[0].createdAt += 10 }),
            ("mask visibility", { $0.strokes[0].visibility = .init(kind: .masked) }),
            ("missing native strokes", { $0.drawingBase64 = PKDrawing().dataRepresentation().base64EncodedString() })
        ]
        for (label, mutate) in mutations {
            var forged = healthy
            mutate(&forged)
            precondition(forged.hasSupportedInkProjection)
            let bytes = try encoder.encode(forged)
            let decoded = try JSONDecoder().decode(CanvasScene.self, from: bytes)
            try store.importScene(healthy)
            check(refused { try store.importScene(decoded) } && store.scene == healthy && store.drawing == native,
                  "import rejects \(label) atomically")
            try bytes.write(to: sceneURL, options: .atomic)
            let reopened = CanvasStore()
            check(try reopened.scene != forged && Data(contentsOf: sceneURL) == bytes,
                  "restore refuses \(label) without rewriting the file")
            check(refused { _ = try CanvasPacket(scene: forged, imagePNG: png, session: session) },
                  "packet creation refuses \(label)")
            var packetJSON = try JSONSerialization.jsonObject(with: encoder.encode(healthyPacket)) as! [String: Any]
            packetJSON["sceneJSONBase64"] = bytes.base64EncodedString()
            packetJSON["sceneSha256"] = CanvasPacket.sha(bytes)
            let packet = try JSONDecoder().decode(CanvasPacket.self,
                from: JSONSerialization.data(withJSONObject: packetJSON))
            check(refused { _ = try packet.frozenScene() }, "packet read refuses \(label) even with a matching hash")
            store.scene = forged
            try saved.write(to: sceneURL, options: .atomic)
            store.saveNow()
            check(try Data(contentsOf: sceneURL) == saved, "save refuses \(label) and preserves the last good file")
        }
        try store.importScene(healthy)
        store.saveNow()
        let reopened = CanvasStore()
        check(reopened.scene == healthy && reopened.drawing == native, "healthy native style survives Store save and reopen")
        check(try healthyPacket.frozenScene() == healthy, "healthy packet read preserves native style")
        check(reopened.scene.drawingBase64 == healthy.drawingBase64 &&
              reopened.drawing.image(from: CGRect(x: 0, y: 0, width: 128, height: 100), scale: 1).tiffRepresentation == image.tiffRepresentation,
              "native bytes and offscreen pixels remain unchanged")
        var legacy = healthy
        legacy.schemaVersion = 1
        legacy.strokes[0].style = nil
        legacy.strokes[0].visibility = nil
        try store.importScene(legacy)
        store.saveNow()
        check(CanvasStore().scene == legacy, "legacy unknown style and visibility remain supported")
        let mask = NSBezierPath(rect: CGRect(x: 20, y: 0, width: 40, height: 100))
        let p3 = PKStroke(ink: PKInk(.marker, color: NSColor(displayP3Red: 0.2, green: 0.7, blue: 0.9, alpha: 0.6)),
            path: path, transform: CGAffineTransform(a: 1.1234567, b: 0.25, c: -0.125, d: 0.75, tx: 8.25, ty: 12.125), mask: mask)
        check(store.updateDrawing(PKDrawing(strokes: [p3])), "masked Display P3 drawing is accepted")
        let precise = store.scene
        try store.importScene(precise)
        store.saveNow()
        check(CanvasStore().scene == precise && store.drawing.strokes[0].mask != nil,
              "native ID mask precision and sRGB conversion survive raw-byte verification")
        print("PROJECTION_INTEGRITY_CHECKS total=\(checks) failed=\(failures.count)")
        if !failures.isEmpty { throw NSError(domain: "ProjectionIntegrityChecks", code: failures.count,
            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
    }
}
