import Foundation
import PencilKit
import AppKit

@main struct InkVisibilityCheck {
    @MainActor static func main() throws {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/"))
        precondition(FileManager.default.homeDirectoryForCurrentUser.path == home)
        print("ISOLATION support=\(support.path)")
        var failures = 0
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }
        func matches(_ point: InkPoint, _ source: PKStrokePoint, _ transform: CGAffineTransform) -> Bool {
            let p = source.location.applying(transform)
            return near(point.x, Double(p.x)) && near(point.y, Double(p.y)) &&
                near(point.pressure, Double(source.force))
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
        let zeroArea = NSBezierPath()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let store = CanvasStore()
        check(store.eraserStyle == .partial && store.eraserStyle.tool.eraserType == .fixedWidthBitmap &&
              near(Double(store.eraserStyle.tool.width), 20), "default partial eraser matches the visible 20-point cursor")
        store.eraserStyle = .stroke
        check(store.eraserStyle.tool.eraserType == .vector, "whole-stroke erasing remains selectable")
        store.eraserStyle = .partial
        var lastScene = CanvasScene()
        for (transformName, transform) in [
            ("identity", CGAffineTransform.identity),
            ("translation", CGAffineTransform(translationX: 100, y: -50)),
            ("rotation", CGAffineTransform(rotationAngle: .pi / 2)),
            ("scale", CGAffineTransform(scaleX: 2, y: 0.5)),
            ("combined", CGAffineTransform(a: 1.5, b: 0.4, c: -0.2, d: 0.75, tx: 80, ty: -10))
        ] {
            for (name, mask) in [("nil", nil), ("full", full), ("empty", empty),
                                  ("zero-area", zeroArea), ("islands", islands)] as [(String, NSBezierPath?)] {
                let label = "\(transformName)/\(name)"
                let worldMask = mask?.copy() as? NSBezierPath
                worldMask?.transform(using: AffineTransform(m11: transform.a, m12: transform.b,
                    m21: transform.c, m22: transform.d, tX: transform.tx, tY: transform.ty))
                let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path,
                                      transform: transform, mask: worldMask)
                let ranges = stroke.maskedPathRanges
                print("SDK \(label) mask=\(stroke.mask != nil) ranges=\(ranges)")
                let isFull = name == "nil" || name == "full" || name == "zero-area"
                if isFull {
                    check(ranges == [CGFloat(0)...CGFloat(4)], "\(label) SDK full centerline range")
                } else if name == "islands" {
                    check(ranges.count == 2 && near(Double(ranges[0].lowerBound), 0.4) &&
                          near(Double(ranges[0].upperBound), 1.4) &&
                          near(Double(ranges[1].lowerBound), 2.6) &&
                          near(Double(ranges[1].upperBound), 3.6), "\(label) SDK ranges describe visible islands")
                } else {
                    check(ranges.isEmpty, "\(label) SDK no visible centerline")
                }
                store.scene = CanvasScene()
                store.drawing = PKDrawing()
                let drawing = PKDrawing(strokes: [stroke])
                let bytes = drawing.dataRepresentation()
                store.updateDrawing(drawing)
                let scene = store.scene
                let exported = scene.strokes[0]
                check(exported.visibility?.kind == (isFull ? .full : .masked),
                      "\(label) actual Store exports known visibility")
                check(exported.points.count == points.count && zip(exported.points, points).allSatisfy {
                    matches($0, $1, transform)
                }, "\(label) full control point and force provenance preserved")
                check(exported.id == stroke.id && exported.createdAt == path.creationDate,
                      "\(label) original identity and creation time preserved")
                let raw = Data(base64Encoded: scene.drawingBase64)!
                let restored = try PKDrawing(data: raw)
                check(raw == bytes && store.drawing == drawing && store.drawing.strokes[0].transform == transform,
                      "\(label) authoritative raw bytes and original in-memory transform preserved")
                let rt = restored.strokes[0].transform
                check(restored.strokes[0].id == stroke.id &&
                      zip([rt.a, rt.b, rt.c, rt.d, rt.tx, rt.ty],
                          [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]).allSatisfy {
                          near(Double($0), Double($1))
                      }, "\(label) SDK raw readback retains identity and transform within serialization precision")
                let encoded = try encoder.encode(scene)
                let decoded = try JSONDecoder().decode(CanvasScene.self, from: encoded)
                check(decoded == scene && decoded.schemaVersion == 1, "\(label) schema 1 JSON round trip")
                let segments = exported.visibility?.visibleSegments ?? []
                if isFull {
                    check(segments.isEmpty && exported.visiblePointSegments == [exported.points],
                          "\(label) full reuses provenance without duplicate resampling")
                } else {
                    check(segments.count == ranges.count, "\(label) retains every SDK range including masked empty")
                    check(zip(segments, ranges).allSatisfy {
                        $0.lowerBound == Double($1.lowerBound) && $0.upperBound == Double($1.upperBound)
                    }, "\(label) exact fractional SDK bounds preserved")
                    if name == "islands" {
                        check(segments.count == 2 && segments.allSatisfy { $0.worldPoints.count == 3 },
                              "\(label) only endpoints and interior control points exported")
                        if segments.count == 2 && segments.allSatisfy({ $0.worldPoints.count == 3 }) {
                            for i in 0..<2 {
                                check(matches(segments[i].worldPoints[0], path.interpolatedPoint(at: ranges[i].lowerBound), transform) &&
                                      matches(segments[i].worldPoints[1], points[i == 0 ? 1 : 3], transform) &&
                                      matches(segments[i].worldPoints[2], path.interpolatedPoint(at: ranges[i].upperBound), transform),
                                      "\(label) island \(i) fractional endpoints and interior world coordinates with force")
                            }
                        }
                        check(exported.visiblePointSegments.count == 2 &&
                              !exported.visiblePointSegments.flatMap({ $0 }).contains(where: {
                                  near($0.x, Double(points[2].location.applying(transform).x)) &&
                                  near($0.y, Double(points[2].location.applying(transform).y))
                              }), "\(label) fallback supplies separate islands and excludes erased center point")
                    } else {
                        check(exported.visiblePointSegments.isEmpty, "\(label) fallback cannot resurrect masked empty")
                    }
                }
                lastScene = scene
                let revision = scene.revision
                store.updateDrawing(drawing)
                check(store.scene.revision == revision, "\(label) unchanged drawing has no extra revision")
            }
        }
        var legacyJSON = try JSONSerialization.jsonObject(with: encoder.encode(lastScene)) as! [String: Any]
        var legacyStrokes = legacyJSON["strokes"] as! [[String: Any]]
        legacyStrokes[0].removeValue(forKey: "visibility")
        legacyJSON["strokes"] = legacyStrokes
        let legacy = try JSONDecoder().decode(CanvasScene.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        check(legacy.schemaVersion == 1 && legacy.strokes[0].visibility == nil &&
              legacy.strokes[0].points == lastScene.strokes[0].points, "legacy schema 1 decodes with unverified visibility and retained provenance")
        check(legacy.strokes[0].visiblePointSegments == [legacy.strokes[0].points],
              "legacy unknown visibility retains best-effort fallback points")
        var knownFull = legacy.strokes[0]
        knownFull.visibility = .init(kind: .full)
        var knownEmpty = legacy.strokes[0]
        knownEmpty.visibility = .init(kind: .masked)
        check(knownFull != knownEmpty && knownEmpty != legacy.strokes[0] && knownFull != legacy.strokes[0],
              "known full, masked empty and legacy unknown remain distinct")
        let legacyReencoded = try JSONSerialization.jsonObject(with: encoder.encode(legacy.strokes[0])) as! [String: Any]
        check(legacyReencoded["visibility"] == nil, "legacy optional visibility stays omitted on encode")

        var structuralLegacy = CanvasScene()
        structuralLegacy.width = 128
        structuralLegacy.height = 100
        structuralLegacy.strokes = [InkStroke(id: UUID(), points: stride(from: 10, through: 110, by: 20).map {
            InkPoint(x: Double($0), y: 30, pressure: 1)
        }, createdAt: Date(timeIntervalSince1970: 1))]
        let restoredLegacy = try JSONDecoder().decode(CanvasScene.self, from: encoder.encode(structuralLegacy))
        let legacyRuns = restoredLegacy.strokes[0].visiblePointSegments
        check(restoredLegacy.drawingBase64.isEmpty && restoredLegacy.strokes[0].visibility == nil &&
              legacyRuns.map { $0.map(\.x) } == [[10, 30, 50, 70, 90, 110]] &&
              legacyRuns.flatMap { $0 }.allSatisfy { $0.y == 30 },
              "structure-only legacy PNG fixture retains its full y30 fallback across x60")
        check(knownEmpty.visiblePointSegments.isEmpty,
              "known masked-empty never falls back to retained legacy provenance")

        let curvedControls = points.enumerated().map { i, point in
            PKStrokePoint(location: CGPoint(x: point.location.x, y: [40, 70, 10, 70, 40][i]),
                timeOffset: point.timeOffset, size: point.size, opacity: point.opacity,
                force: point.force, azimuth: point.azimuth, altitude: point.altitude)
        }
        let curvedPath = PKStrokePath(controlPoints: curvedControls, creationDate: path.creationDate)
        let curvedMask = NSBezierPath(rect: CGRect(x: 10, y: -100, width: 25, height: 300))
        let curved = PKStroke(ink: PKInk(.pen, color: .black), path: curvedPath, mask: curvedMask)
        store.drawing = PKDrawing()
        store.updateDrawing(PKDrawing(strokes: [curved]))
        let curveSegments = store.scene.strokes[0].visibility?.visibleSegments ?? []
        check(curved.maskedPathRanges.count == 1 && curveSegments.count == 1 &&
              curveSegments[0].worldPoints.count == 3, "curved native mask retains one fractional interval with interior control point")
        if let range = curved.maskedPathRanges.first, let segment = curveSegments.first, segment.worldPoints.count == 3 {
            check(matches(segment.worldPoints[0], curvedPath.interpolatedPoint(at: range.lowerBound), .identity) &&
                  matches(segment.worldPoints[2], curvedPath.interpolatedPoint(at: range.upperBound), .identity),
                  "curved endpoints use actual SDK interpolation")
            let linearY = 40 + 30 * Double(range.lowerBound)
            check(!near(segment.worldPoints[0].y, linearY), "curved fractional endpoint differs from linear control-point interpolation")
        }

        let integerMask = NSBezierPath(rect: CGRect(x: 25, y: 0, width: 50, height: 80))
        let integerStroke = PKStroke(ink: PKInk(.pen, color: .black), path: path, mask: integerMask)
        store.drawing = PKDrawing()
        store.updateDrawing(PKDrawing(strokes: [integerStroke]))
        let integerSegments = store.scene.strokes[0].visibility?.visibleSegments ?? []
        print("SDK integer ranges=\(integerStroke.maskedPathRanges) projected=\(integerSegments)")
        let lower = integerStroke.maskedPathRanges.first?.lowerBound ?? -1
        check(integerStroke.maskedPathRanges.count == 1 && lower >= 1 && lower < 2 &&
              integerStroke.maskedPathRanges[0].upperBound == 3 &&
              integerSegments.count == 1 && integerSegments[0].worldPoints.count == 3 &&
              matches(integerSegments[0].worldPoints[0], path.interpolatedPoint(at: lower), .identity) &&
              integerSegments[0].worldPoints.dropFirst().map(\.x) == [50, 75],
              "native boundary precision is retained and integer upper endpoint occurs once")
        let startMask = NSBezierPath(rect: CGRect(x: -20, y: 0, width: 95, height: 80))
        let startStroke = PKStroke(ink: PKInk(.pen, color: .black), path: path, mask: startMask)
        store.drawing = PKDrawing()
        store.updateDrawing(PKDrawing(strokes: [startStroke]))
        let startSegments = store.scene.strokes[0].visibility?.visibleSegments ?? []
        check(startStroke.maskedPathRanges == [CGFloat(0)...CGFloat(3)] &&
              startSegments.count == 1 && startSegments[0].worldPoints.count == 4 &&
              zip(startSegments[0].worldPoints.map(\.x), [0.0, 25, 50, 75]).allSatisfy(near),
              "integer lower and upper endpoints occur once with all interior control points")

        let manyStrokes = (0..<189).map { index in
            let count = index < 144 ? 33 : 32
            let controls = (0..<count).map { i in
                PKStrokePoint(location: CGPoint(x: i * 3, y: index * 2), timeOffset: Double(i) * 0.01,
                    size: CGSize(width: 3, height: 3), opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
            }
            return PKStroke(ink: PKInk(.pen, color: .black),
                path: PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: 1)))
        }
        store.scene = CanvasScene()
        store.drawing = PKDrawing()
        store.updateDrawing(PKDrawing(strokes: manyStrokes))
        let large = store.scene
        let largeBytes = try encoder.encode(large)
        var withoutVisibility = large
        for i in withoutVisibility.strokes.indices { withoutVisibility.strokes[i].visibility = nil }
        let baselineBytes = try encoder.encode(withoutVisibility)
        let growth = largeBytes.count - baselineBytes.count
        check(large.strokes.count == 189 && large.strokes.reduce(0, { $0 + $1.points.count }) == 6192,
              "size fixture uses 189 strokes and 6192 control points")
        check(large.strokes.allSatisfy { $0.visibility?.kind == .full && $0.visibility?.visibleSegments.isEmpty == true },
              "size fixture duplicates no full-stroke coordinates")
        check(largeBytes.count <= 1024 * 1024 && 616040 + growth <= 1024 * 1024,
              "synthetic scene and reported 616040-byte baseline plus measured full metadata fit existing 1 MiB")
        print("SIZE syntheticBytes=\(largeBytes.count) metadataGrowth=\(growth) reportedBaselinePlusMetadata=\(616040 + growth)")
        store.saveNow()
        let saved = try Data(contentsOf: support.appendingPathComponent("CanvasScene.json"))
        check(try JSONDecoder().decode(CanvasScene.self, from: saved) == large, "actual Store save stays in isolated HOME and round trips")
        print("INK_VISIBILITY_CHECKS total=\(checks) failed=\(failures)")
        if failures > 0 { exit(1) }
    }
}
