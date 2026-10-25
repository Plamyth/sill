import Foundation
import PencilKit
import AppKit

@main struct EraserSizeCheck {
    @MainActor static func main() async throws {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/"))
        precondition(FileManager.default.homeDirectoryForCurrentUser.path == home)
        let preferencesPath = home + "/eraser-preferences"
        let defaults = UserDefaults(suiteName: preferencesPath)!
        let sceneURL = try CanvasRuntime.stateURL(.scene)
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        func finish() {
            print("RESULT checks=\(checks) failures=\(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--restore") {
            let before = try Data(contentsOf: sceneURL)
            let store = CanvasStore(defaults: defaults)
            let saved = try JSONDecoder().decode(CanvasScene.self, from: before)
            check(store.scene == saved, "new process restores identical scene content and raw drawing")
            try await Task.sleep(for: .milliseconds(350))
            let settledBytes = try Data(contentsOf: sceneURL)
            check(store.eraserSize == .broad && store.eraserStyle == .stroke,
                  "new process restores size and whole-stroke preference")
            check(store.eraserTool.eraserType == .vector && store.eraserPreviewWidth == nil,
                  "restored whole-stroke mode advertises no spatial size")
            store.eraserStyle = .partial
            check(store.eraserTool.width == 80 && store.eraserPreviewWidth == 80,
                  "new process returns to retained partial width")
            check(store.scene.strokes.first?.visibility?.visibleSegments.count == 2,
                  "new process restores partial mask intervals")
            check(try PKDrawing(data: Data(base64Encoded: store.scene.drawingBase64)!) == store.drawing,
                  "new process decodes the authoritative masked native drawing")
            try await Task.sleep(for: .milliseconds(350))
            check(try Data(contentsOf: sceneURL) == settledBytes,
                  "preference restore and mode switch do not rewrite saved scene bytes")
            finish()
        }

        let store = CanvasStore(defaults: defaults)
        check(store.eraserStyle == .partial && store.eraserSize == .standard && store.eraserTool.width == 20,
              "absent settings preserve partial mode and original 20-point default")
        check(CanvasEraserSize.allCases.count == 6 && Set(CanvasEraserSize.allCases.map(\.rawValue)).count == 6,
              "exactly six distinct CCR widths")
        let points = (0..<5).map { i in
            PKStrokePoint(location: CGPoint(x: 10 + i * 25, y: 40), timeOffset: Double(i) * 0.1,
                size: CGSize(width: 6, height: 6), opacity: 1, force: 0.4 + Double(i) * 0.1,
                azimuth: 0, altitude: 1)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1))
        let transform = CGAffineTransform(a: 1.5, b: 0.4, c: -0.2, d: 0.75, tx: 80, ty: -10)
        let mask = NSBezierPath(rect: CGRect(x: 0, y: 0, width: 45, height: 100))
        mask.appendRect(CGRect(x: 75, y: 0, width: 53, height: 100))
        mask.transform(using: AffineTransform(m11: transform.a, m12: transform.b,
            m21: transform.c, m22: transform.d, tX: transform.tx, tY: transform.ty))
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path, transform: transform, mask: mask)
        let drawing = PKDrawing(strokes: [stroke])
        store.updateDrawing(drawing)
        store.saveNow()
        let originalScene = store.scene
        let originalData = drawing.dataRepresentation()
        let originalReadback = try PKDrawing(data: originalData)
        let savedBytes = try Data(contentsOf: sceneURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalJSON = try encoder.encode(originalScene)
        check(stroke.maskedPathRanges.count == 2 && originalScene.strokes.first?.visibility?.visibleSegments.count == 2,
              "fixture contains real transformed PencilKit stroke with a partially erased gap")

        for (size, width) in zip(CanvasEraserSize.allCases, [18.0, 20, 30, 40, 60, 80]) {
            store.mode = .eraser
            store.eraserStyle = .partial
            store.eraserSize = size
            check(store.eraserTool.eraserType == .fixedWidthBitmap && store.eraserTool.width == width &&
                  store.eraserPreviewWidth == width, "native partial tool and preview width \(width)")
            check(CanvasStore(defaults: defaults).eraserSize == size, "fresh Store restores selected width \(width)")
            store.eraserStyle = .stroke
            check(store.eraserTool.eraserType == .vector && store.eraserPreviewWidth == nil,
                  "whole-stroke mode has no size footprint for retained width \(width)")
            store.mode = .pen
            store.mode = .eraser
            store.eraserStyle = .partial
            check(store.eraserTool.width == width, "pen and stroke mode roundtrip retains width \(width)")
            for zoom in [0.5, 1.0, 3.0] {
                store.viewport = CanvasViewport(zoom: zoom)
                check(store.eraserTool.width == width && store.eraserPreviewWidth == width && store.zoom == zoom,
                      "zoom \(zoom) keeps tool and preview in the same scene units at width \(width)")
            }
            let decoded = try JSONDecoder().decode(CanvasScene.self, from: encoder.encode(store.scene))
            let native = try PKDrawing(data: Data(base64Encoded: decoded.drawingBase64)!)
            check(decoded == originalScene && native == originalReadback &&
                  Data(base64Encoded: decoded.drawingBase64) == originalData && store.drawing == drawing,
                  "size \(width) preserves full JSON and raw drawing bytes")
            check(native.strokes[0].id == stroke.id &&
                  native.strokes[0].transform == originalReadback.strokes[0].transform &&
                  native.strokes[0].path.creationDate == path.creationDate &&
                  native.strokes[0].maskedPathRanges == originalReadback.strokes[0].maskedPathRanges &&
                  store.drawing.strokes[0].transform == transform,
                  "size \(width) preserves native ID, transform, date and partial mask")
        }
        for bad: Any in [Double.nan, Double.infinity, -Double.infinity, -1.0, 0.0, 999.0,
                         5.0, 10.0, 15.0, 20.001, "20", "폐기한 크기", true, [20], ["width": 20]] {
            defaults.set(bad, forKey: CanvasStore.eraserSizeKey)
            let restored = CanvasStore(defaults: defaults)
            check(restored.eraserSize == .standard && restored.eraserTool.width == 20,
                  "invalid or retired persisted width safely restores 20 points: \(bad)")
            check(restored.scene == originalScene, "invalid width restore preserves existing scene")
        }
        defaults.set("폐기한 방식", forKey: CanvasStore.eraserStyleKey)
        check(CanvasStore(defaults: defaults).eraserStyle == .partial, "unknown eraser mode restores partial default")
        store.eraserSize = .broad
        store.eraserStyle = .stroke
        check(defaults.double(forKey: CanvasStore.eraserSizeKey) == 80,
              "valid selection replaces corrupt saved width")
        check(try encoder.encode(store.scene) == originalJSON && store.scene == originalScene,
              "all preference and mode changes preserve scene revision, IDs and graph")
        try await Task.sleep(for: .milliseconds(350))
        check(try Data(contentsOf: sceneURL) == savedBytes,
              "settings never schedule scene autosave or rewrite persisted scene")
        check(defaults.synchronize(), "isolated preferences flush for separate-process reopen")
        let preferences = NSDictionary(contentsOfFile: preferencesPath + ".plist")
        check((preferences?[CanvasStore.eraserSizeKey] as? NSNumber)?.doubleValue == 80,
              "preferences physically persist inside the isolated external home")
        finish()
    }
}
