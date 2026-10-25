import Foundation

@main struct PenSettingsChecks {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            count += 1
            print("PASS \(label)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        var scene = CanvasScene()
        let legacy = try decoder.decode(CanvasScene.self, from: encoder.encode(scene))
        check(legacy.penSettings == nil && legacy.effectivePenSettings == .default,
              "legacy scene defaults only the next pen settings")
        let stroke = InkStroke(id: UUID(), points: [.init(x: 1, y: 2, pressure: 0.7)], createdAt: Date())
        scene.strokes = [stroke]
        scene.drawingBase64 = "original-native-bytes"
        let original = scene
        let yellow = CanvasPenSettings(color: .yellow, width: 8)
        let command = CanvasPenSettingsChange(expected: .default, settings: yellow)
        let result = try scene.setPenSettings(command, sceneID: scene.id, baseRevision: scene.revision)
        check(result.disposition == .applied && result.settings == yellow && result.revision == 1,
              "settings command returns actual settings and revision")
        check(scene.schemaVersion == 2 && scene.strokes == original.strokes &&
              scene.drawingBase64 == original.drawingBase64 && scene.hasSameGraph(as: original),
              "settings promote the writer version without touching native ink or graph")
        let saved = try encoder.encode(scene)
        check(try decoder.decode(CanvasScene.self, from: saved) == scene, "settings survive scene serialization")
        let same = CanvasPenSettingsChange(expected: yellow, settings: yellow)
        let noop = try scene.setPenSettings(same, sceneID: scene.id, baseRevision: scene.revision)
        check(try noop.disposition == .noop && encoder.encode(scene) == saved,
              "exact no-op leaves every encoded byte unchanged")
        func refuses(_ expected: CanvasPenSettingsError, _ command: CanvasPenSettingsChange,
                     id: UUID? = nil, revision: Int? = nil, busy: Bool = false) {
            var copy = scene
            do {
                _ = try copy.setPenSettings(command, sceneID: id ?? scene.id,
                    baseRevision: revision ?? scene.revision, inkBusy: busy)
                preconditionFailure("must refuse \(expected.rawValue)")
            } catch {
                check(error as? CanvasPenSettingsError == expected && copy == scene,
                      "\(expected.rawValue) refuses atomically")
            }
        }
        refuses(.staleRevision, command, revision: 0)
        refuses(.staleRevision, command)
        refuses(.staleRevision, same, id: UUID())
        refuses(.staleRevision, same, revision: 5)
        refuses(.inkBusy, same, busy: true)
        for width in [-1.0, 0, 3, 9, .infinity, .nan] {
            refuses(.invalidPenSettings, .init(expected: yellow, settings: .init(color: .cyan, width: width)))
        }
        refuses(.invalidPenSettings, .init(expected: yellow, settings: .init(version: 2, color: .cyan, width: 4)))
        for color in CanvasPenSettings.Color.allCases {
            for width in CanvasPenSettings.widths {
                var copy = scene
                let desired = CanvasPenSettings(color: color, width: width)
                _ = try copy.setPenSettings(.init(expected: yellow, settings: desired),
                    sceneID: scene.id, baseRevision: scene.revision)
                check(copy.effectivePenSettings == desired, "supported palette and width \(color.rawValue)/\(width)")
            }
        }
        var agent = AgentRevision(sceneId: scene.id, baseRevision: scene.revision,
            annotations: [], proposedNodes: [], setPenSettings: .init(expected: yellow, settings: .default))
        let incoming = try decoder.decode(AgentRevision.self, from: encoder.encode(agent))
        var applied = scene
        check(applied.apply(incoming) && applied.effectivePenSettings == .default,
              "AgentRevision.apply reaches the common next-pen command")
        let agentApplied = applied
        check(!applied.apply(incoming) && applied == agentApplied,
              "stale agent retry refuses rather than recoloring prior strokes")
        agent.annotations = [.init(id: UUID(), nodeId: nil, text: "mixed", author: "agent")]
        var mixed = scene
        check(!mixed.apply(agent) && mixed == scene, "mixed ink and graph edits refuse atomically")
        var wire = try JSONSerialization.jsonObject(with: encoder.encode(incoming)) as! [String: Any]
        for field in ["drawingBase64", "strokes", "inkEdits", "recolorStrokes"] {
            var unsupported = wire
            unsupported[field] = "opaque replacement"
            do {
                _ = try decoder.decode(AgentRevision.self, from: JSONSerialization.data(withJSONObject: unsupported))
                preconditionFailure("opaque ink edit decoded")
            } catch {
                check(error as? CanvasPenSettingsError == .unsupportedInkEdit, "rejects agent field \(field)")
            }
        }
        var nested = wire["setPenSettings"] as! [String: Any]
        nested["drawingBase64"] = "replacement"
        wire["setPenSettings"] = nested
        do {
            _ = try decoder.decode(AgentRevision.self, from: JSONSerialization.data(withJSONObject: wire))
            preconditionFailure("nested ink replacement decoded")
        } catch {
            check(error as? CanvasPenSettingsError == .unsupportedInkEdit, "nested opaque edit rejected")
        }
        var huge = scene
        huge.drawingBase64 = String(repeating: "x", count: CanvasScene.localByteLimit)
        let beforeHuge = huge
        do {
            _ = try huge.setPenSettings(.init(expected: yellow, settings: .default),
                sceneID: huge.id, baseRevision: huge.revision)
            preconditionFailure("oversized scene accepted")
        } catch {
            check(error as? CanvasPenSettingsError == .sceneTooLarge && huge == beforeHuge,
                  "4 MiB failure preserves the original scene")
        }
        var future = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        future["schemaVersion"] = 3
        do {
            _ = try decoder.decode(CanvasScene.self, from: JSONSerialization.data(withJSONObject: future))
            preconditionFailure("future writer decoded")
        } catch { check(true, "future scene versions refuse before a lossy writer can save") }
        check(CanvasPacket.sceneByteLimit == 1024 * 1024 && CanvasScene.localByteLimit == 4 * 1024 * 1024,
              "packet and local scene limits remain distinct")
        check(stroke.style == nil, "legacy stroke style remains unknown")
        var projected = scene
        projected.strokes[0].style = .init(inkType: "pen", color: nil,
            transform: .init(a: 1, b: 0, c: 0, d: 1, tx: 10, ty: 20),
            samples: [.init(width: 2, height: 3, opacity: 0.7)])
        let unknownColor = try decoder.decode(CanvasScene.self, from: encoder.encode(projected))
        check(unknownColor.strokes[0].style?.color == nil && unknownColor.strokes[0].style != nil,
              "unknown sRGB color stays distinct from a missing legacy style")
        for mutation: (inout CanvasScene) -> Void in [
            { $0.schemaVersion = 1 },
            { $0.strokes[0].style!.version = 2 },
            { $0.strokes[0].style!.samples = [] },
            { $0.strokes[0].style!.samples[0].opacity = 2 },
            { $0.strokes[0].style!.samples[0].width = -1 },
            { $0.drawingBase64 = "" }
        ] {
            var invalid = projected
            mutation(&invalid)
            do {
                _ = try decoder.decode(CanvasScene.self, from: encoder.encode(invalid))
                preconditionFailure("invalid projection decoded")
            } catch {
                check(error as? CanvasPenSettingsError == .unsupportedInkProjection,
                      "invalid or downgraded projection cannot be read and rewritten")
            }
        }
        var invalidColor = try JSONSerialization.jsonObject(with: encoder.encode(yellow)) as! [String: Any]
        invalidColor["color"] = "unobserved-color"
        do {
            _ = try decoder.decode(CanvasPenSettings.self, from: JSONSerialization.data(withJSONObject: invalidColor))
            preconditionFailure("unsupported color decoded")
        } catch { check(error as? CanvasPenSettingsError == .invalidPenSettings, "wire color is validated at the boundary") }
        print("PEN_SETTINGS_CHECKS total=\(count) failed=0")
    }
}
