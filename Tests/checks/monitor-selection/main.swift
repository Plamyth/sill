import Foundation
import StreamProtocol

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
    checks += 1
    print("PASS \(label)")
}
let main = DisplayInfo(id: 8, name: "내장 모니터", width: 3024, height: 1964, isMain: true)
let external = DisplayInfo(id: 19, name: "외장 모니터", width: 1920, height: 1080, isMain: false)
var inventory = DisplayInventory()
check(inventory.update([external, main], signatures: ["external", "built-in"]), "initial inventory publishes")
let original = inventory.revision!
check(inventory.current?.displayID == main.id, "default desktop uses main regardless of inventory order")
check(!inventory.update([external, main], signatures: ["external", "built-in"]), "unchanged poll preserves inventory token")
let pick = DisplaySelection(displayID: external.id, inventoryID: original)
check(inventory.select(pick), "fresh external monitor pick accepted")
check(inventory.current == pick, "desktop category has separate selected display")
check(!inventory.select(DisplaySelection(displayID: 99, inventoryID: original)), "unlisted display cannot be selected")
check(inventory.current == pick, "invalid pick keeps existing display")
check(!inventory.select(DisplaySelection(displayID: main.id, inventoryID: UUID())), "stale inventory refused even for valid numeric ID")
check(inventory.current == pick, "stale pick does not switch to main")
let oldScope = DisplayInventory.scope(inventory.current)
inventory.invalidate()
check(inventory.current == nil && inventory.revision == nil && inventory.requiresSelection, "topology event immediately blocks capture and selection")
check(!inventory.select(pick), "request from before topology callback rejected")
_ = inventory.update([main], signatures: ["built-in"])
check(inventory.current == nil, "unplug never silently captures another monitor")
check(inventory.revision != original && !inventory.select(pick), "unplug replaces token and rejects removed display")
_ = inventory.update([external, main], signatures: ["different-hardware-same-id", "built-in"])
check(inventory.current == nil && !inventory.select(pick), "reconnect reusing numeric ID cannot restore old selection")
let reconnected = DisplaySelection(displayID: external.id, inventoryID: inventory.revision!)
check(inventory.select(reconnected), "reconnected hardware needs fresh explicit selection")
check(DisplayInventory.scope(inventory.current) != oldScope, "reused numeric ID has a different input fence identity")
_ = inventory.update([external, main], signatures: ["moved-external", "built-in"])
check(inventory.current == nil && inventory.requiresSelection, "layout changes invalidate geometry rather than retaining old capture")

var fence = SourceInputFence<String>()
check(fence.join("legacy", source: .desktop, switching: false, desktopScope: oldScope), "legacy peer pins original monitor")
let newScope = DisplayInventory.scope(reconnected)
check(!fence.allowsSelection(.desktop, desktopScope: newScope), "legacy pin distinguishes desktops on two monitors")
check(fence.allowsSelection(.desktop, desktopScope: oldScope), "legacy peer can restart original monitor")
check(fence.allowsSelection(.none), "unplug can stop despite legacy pin")
fence.sourceChanged(to: .none)
check(!fence.allowsSelection(.desktop, desktopScope: newScope), "stopping does not release legacy monitor pin")
check(!fence.accepts("legacy", generation: nil, current: "new", source: .desktop, desktopScope: newScope), "unscoped old input never reaches replacement monitor")
check(fence.accepts("legacy", generation: nil, current: "old", source: .desktop, desktopScope: oldScope), "legacy input works on its original display")
fence.negotiate("legacy", supportsScoped: true)
check(fence.allowsSelection(.desktop, desktopScope: newScope), "negotiating scoped input releases monitor pin")
check(!fence.accepts("legacy", generation: "old", current: "new", source: .desktop, desktopScope: newScope), "queued input from previous monitor generation rejected")
check(fence.accepts("legacy", generation: "new", current: "new", source: .desktop, desktopScope: newScope), "current generation admitted")
check(!fence.accepts("legacy", generation: nil, current: "new", source: .desktop, desktopScope: newScope), "negotiated peer cannot downgrade to raw input")
_ = fence.join("second-legacy", source: .desktop, switching: false, desktopScope: newScope)
check(!fence.allowsSelection(.desktop, desktopScope: oldScope), "mixed clients keep newly joined legacy peer safe")
fence.leave("second-legacy")
check(fence.allowsSelection(.desktop, desktopScope: oldScope), "disconnecting last legacy peer releases pin")

let legacy = Wire.decode(WindowList.self, from: Data(#"{"macName":"Legacy","windows":[],"active":{"desktop":{}}}"#.utf8))!
check(legacy.displaySelection == nil && legacy.displays == nil && legacy.displayInventoryID == nil, "old host catalog remains decodable without display capability")
check(legacy.active == .desktop, "desktop wire enum unchanged")
let list = WindowList(macName: "Mac", windows: [], active: .desktop, remoteAudio: 1, inputGeneration: "g2",
                      displaySelection: 1, displays: [main, external], displayInventoryID: original,
                      activeDisplayID: external.id, desktopSelectionRequired: false)
let decoded = Wire.decode(WindowList.self, from: Wire.encode(list))!
check(decoded.displays == [main, external] && decoded.activeDisplayID == external.id, "modern catalog preserves inventory and selected display")
check(decoded.displaySelection == 1 && decoded.displayInventoryID == original, "capability and inventory token round trip")
struct LegacyList: Decodable { let macName: String; let windows: [WindowInfo]; let active: StreamSource }
check(Wire.decode(LegacyList.self, from: Wire.encode(list))?.active == .desktop, "old client ignores new catalog keys")
check(Wire.decode(DisplaySelection.self, from: Wire.encode(pick)) == pick, "selection request round trips")
check(Wire.decode(DisplaySelection.self, from: Data(#"{"displayID":19}"#.utf8)) == nil, "numeric ID alone cannot select")
check(StreamMessageKind.selectDisplay.rawValue == 211 && StreamMessageKind(rawValue: 6) == .selectSource, "additive message preserves existing kind values")
check(SillProtocol.current == 1, "additive feature keeps transport protocol version")

let peer = NSObject()
var stops = 0
var sends: [RemoteAudioSubscription] = []
let audio = IPadRemoteAudioController(send: { _, request in sends.append(request) }, stop: { stops += 1 }, play: { _ in }, changed: { _ in })
audio.setConnection(ObjectIdentifier(peer))
audio.receive(list, from: ObjectIdentifier(peer))
audio.toggle()
let audioID = sends.last!.requestID
audio.receive(RemoteAudioState(enabled: true, requestID: audioID), from: ObjectIdentifier(peer))
check(audio.status.requested, "audio consent starts on selected monitor")
var nextMonitor = list
nextMonitor.inputGeneration = "g3"
nextMonitor.activeDisplayID = main.id
let beforeStops = stops
audio.receive(nextMonitor, from: ObjectIdentifier(peer))
check(!audio.status.requested && stops > beforeStops && sends.last?.enabled == false, "same desktop category with new generation revokes old audio consent")
print("\(checks) monitor selection checks passed")
