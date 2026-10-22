import Foundation
import StreamProtocol

@main struct WireChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        let epoch = UUID(), generation = "peer-incarnation-generation"
        let gesture = TrackpadGesture(gesture: TrackpadGesture.swipeUp, fingers: 3, generation: generation, videoEpoch: epoch)
        let fetch = FetchMenu(version: 2, id: "1.2", title: "메뉴", token: 9, generation: generation, videoEpoch: epoch)
        let press = PressMenuItem(version: 2, id: "1.2", title: "항목", token: 10, generation: generation, videoEpoch: epoch)
        let window = WindowCommand(id: 7, action: .minimize, generation: generation, videoEpoch: epoch)
        func object<T: Encodable>(_ value: T) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Wire.encode(value)) as! [String: Any]
        }
        for value in [try object(gesture), try object(fetch), try object(press), try object(window)] {
            check(value["generation"] as? String == generation, "generation preserved")
            check(value["videoEpoch"] as? String == epoch.uuidString, "epoch preserved")
        }
        check(Wire.decode(TrackpadGesture.self, from: Wire.encode(gesture)) == gesture, "scoped gesture roundtrip")
        check(Wire.decode(FetchMenu.self, from: Wire.encode(fetch)) == fetch, "scoped fetch roundtrip")
        check(Wire.decode(PressMenuItem.self, from: Wire.encode(press)) == press, "scoped press roundtrip")
        let decoded = Wire.decode(WindowCommand.self, from: Wire.encode(window))!
        check(decoded.generation == generation && decoded.videoEpoch == epoch, "scoped window roundtrip")
        for value in [try object(TrackpadGesture(gesture: "swipeUp")), try object(FetchMenu()),
                      try object(PressMenuItem(id: "1.2")), try object(WindowCommand(id: 7, action: .close))] {
            check(value["generation"] == nil && value["videoEpoch"] == nil, "legacy wire omits new scope")
        }
        check(Wire.decode(FetchMenu.self, from: Data("{}".utf8))?.id == nil, "initial subscription remains unscoped")
        var list = WindowList(macName: "Mac", windows: [], active: .none)
        check(try object(list)["independentStreams"] == nil, "legacy host no independent guarantee")
        list.independentStreams = 1; list.sourceSelectionEffects = 0; list.sourceSelectionFailure = "화면을 확인할 수 없습니다."
        let roundtrip = Wire.decode(WindowList.self, from: Wire.encode(list))!
        check(roundtrip.independentStreams == 1 && roundtrip.sourceSelectionEffects == 0, "independent capability roundtrip")
        check(roundtrip.sourceSelectionFailure == list.sourceSelectionFailure, "Korean selection failure preserved")
        var invalid = try object(list); invalid["independentStreams"] = true
        check(Wire.decode(WindowList.self, from: try JSONSerialization.data(withJSONObject: invalid)) == nil, "boolean capability rejected")
        invalid = try object(gesture); invalid["videoEpoch"] = "not-a-uuid"
        check(Wire.decode(TrackpadGesture.self, from: try JSONSerialization.data(withJSONObject: invalid)) == nil, "malformed scope rejected")
        let menuReply = MacMenu(version: 8, answering: 1, pressed: true, generation: generation, videoEpoch: epoch)
        check(Wire.decode(MacMenu.self, from: Wire.encode(menuReply)) == menuReply, "menu response keeps producing scope")
        check(try object(MacMenu())["videoEpoch"] == nil, "legacy menu response omits scope")
        print("PASS \(checks) independent peer wire compatibility checks")
    }
}
