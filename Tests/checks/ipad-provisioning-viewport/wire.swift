import Foundation

// OLD_VIEWPORT
// OLD_DIMENSIONS

extension Checks {
    @MainActor static func wireChecks() {
        let legacy = OldViewport(width: 1350, height: 890, scale: 1.5, localCursor: true, fps: 120)
        let oldBytes = Wire.encode(legacy)
        let decoded = Wire.decode(Viewport.self, from: oldBytes)!
        check(decoded.extendedDesktop == nil && decoded.width == 1350 && decoded.scale == 1.5,
              "new decoder accepts legacy viewport with optional field absent")
        let omitted = try! JSONSerialization.jsonObject(with: Wire.encode(decoded)) as! [String: Any]
        check(omitted["extendedDesktop"] == nil, "nil native size is omitted on the wire")
        var modern = decoded
        modern.extendedDesktop = .init(width: 1350, height: 976)
        let bytes = Wire.encode(modern)
        check(Wire.decode(Viewport.self, from: bytes) == modern, "native intent round trips on wire")
        check(Wire.decode(OldViewport.self, from: bytes) == legacy,
              "old host ignores native field and retains actual panel, scale, cursor and FPS")
        check(OldDimensions(viewport: Wire.decode(OldViewport.self, from: bytes)!)?.heightPt == 890,
              "original host allocation reads actual panel from new wire bytes")
        check(ExtendedDesktop.Dimensions(viewport: decoded)?.heightPt == 890,
              "new host uses legacy panel fallback when native intent is absent")
        check(ExtendedDesktop.Dimensions(viewport: modern)?.heightPt == 976,
              "new host allocation consumes explicit native height independently of Aa")
        modern.scale = nil
        check(VirtualStage.windowSize(for: modern, own: .zero) == CGSize(width: 1350, height: 890),
              "nil scale means actual panel at 1x in VirtualStage, ignoring native allocation")
        for scale: Double? in [nil, 0.8, 1.0, 1.5, 2.0] {
            modern.scale = scale
            check(ExtendedDesktop.Dimensions(viewport: modern)?.heightPt == 976,
                  "native allocation is independent of scale \(String(describing: scale))")
        }
        for (width, height) in [(320.0, 240.0), (2048.0, 2048.0), (1350.4, 975.6)] {
            let native = Viewport.ExtendedDesktopSize(width: width, height: height)
            check(native != nil, "native schema accepts bounded finite dimensions")
            modern.extendedDesktop = native
            check(Wire.decode(Viewport.self, from: Wire.encode(modern)) == modern,
                  "native schema round trips bounds and fractional points")
            check(ExtendedDesktop.Dimensions(viewport: modern)?.heightPt == Int(height.rounded()),
                  "allocation rounds validated native dimensions")
        }
        let invalid: [(Double, Double)] = [(.nan, 976), (.infinity, 976), (-.infinity, 976),
            (1350, .nan), (1350, .infinity), (1350, -.infinity), (0, 976), (319.9, 976),
            (2048.1, 976), (1350, 0), (1350, 239.9), (1350, 2048.1)]
        for (width, height) in invalid {
            check(Viewport.ExtendedDesktopSize(width: width, height: height) == nil,
                  "native constructor refuses invalid dimensions before allocation")
        }
        let malformed = [#"{"width":319,"height":976}"#, #"{"width":1350,"height":239}"#,
            #"{"width":2049,"height":976}"#, #"{"width":1350,"height":2049}"#,
            #"{"width":1e309,"height":976}"#, #"{"width":1350,"height":1e309}"#,
            #"{"width":"NaN","height":976}"#, #"{"width":1350,"height":"Infinity"}"#,
            #"{"width":null,"height":976}"#, #"{"height":976}"#, #"[]"#]
        for native in malformed {
            let json = "{\"width\":1350,\"height\":890,\"scale\":1.5,\"extendedDesktop\":\(native)}"
            check(Wire.decode(Viewport.self, from: Data(json.utf8)) == nil,
                  "wire boundary rejects malformed native intent without panel fallback")
        }
        let null = Data(#"{"width":1350,"height":890,"extendedDesktop":null}"#.utf8)
        check(Wire.decode(Viewport.self, from: null)?.extendedDesktop == nil,
              "null optional native intent retains backward decode")
    }
}
