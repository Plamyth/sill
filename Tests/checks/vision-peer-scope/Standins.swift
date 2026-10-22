import Foundation
import Network
import StreamProtocol

final class MacMenuHub {
    static let shared = MacMenuHub()
    func menusChanged(_ client: StreamClient) {}
}

final class StreamClient {
    var visionPeerStreams = VisionPeerStreams()
    var visionSourceSelectionFailure: String?
    var visionMenuPresentation: UUID?
    var visionInputBinding = VisionInputBinding.awaitingCatalog
    var visionInputPermit: UUID?
    var visionTextForeground = true
    struct Display { var inputBlocked = false; var blocksDesktopRequest = false }
    var visionDisplaySelection = Display()
    var moving: UUID?
    var visionMovePreparation: UUID?
    let link = SessionLink()
    var connection: NWConnection? {
        get { link.connection }
        set { link.connection = newValue }
    }
    let queue = DispatchQueue(label: "inert-vision-commands")
    var active = StreamSource.none
    var connected = true
    var hostGestures: Int? = 1
    static var gesturesOn = true
    var selected: [StreamSource] = []
    var menus = MacMenuState()
    var menuKey = 0
    var menuToken = 1
    var menuCompletions: [Int: (MacMenuState.Content) -> Void] = [:]
    var finished: [MacMenuState.Done] = []
    func noteAction() {}
    func select(_ source: StreamSource) { selected.append(source) }
    func flushPendingMove() {}
    func scheduleMenusExpiry() {}
    func menuRefused(_ refusal: MacMenuState.Refusal) {}
    func finishMenus(_ done: [MacMenuState.Done]) {
        finished += done
        for item in done { menuCompletions.removeValue(forKey: item.key)?(item.content) }
    }
    func nextMenuToken() -> Int { defer { menuToken += 1 }; return menuToken }
    func send(_ kind: StreamMessageKind, payload: Data) { send(kind, payload) }
    func send(_ kind: StreamMessageKind, _ payload: Data) {
        link.send(StreamMessage(kind: kind, timestamp: 0, isKeyframe: false, payload: payload).serialized())
    }
    var choicesSent = 0
    var visionAudioIntentAwaitingSource: StreamSource?
    final class Audio { var stops = 0; func stop() { stops += 1 } }
    var visionAudio = Audio()
    struct InputSession { func takeReleases() -> [InputEvent] { [] } }
    var visionInputSession: InputSession?
    func prepareVisionManualSource() {}
    var microphoneStops = 0
    func microphoneSourceWillChange() { microphoneStops += 1 }
    func confirmVisionDisplayPresentation() {}
    func reconcileVisionAudioIntent() {}
    func cancelVisionCursor() {}
    func revokeVisionTextDrafts() {}
    let visionInputDebt = VisionInputDebt()
    // METHODS
}

class UIMenuElement {}
final class UIDeferredMenuElement: UIMenuElement {
    let provider: (@escaping ([UIMenuElement]) -> Void) -> Void
    init(_ provider: @escaping (@escaping ([UIMenuElement]) -> Void) -> Void) { self.provider = provider }
    static func uncached(_ provider: @escaping (@escaping ([UIMenuElement]) -> Void) -> Void) -> UIDeferredMenuElement {
        UIDeferredMenuElement(provider)
    }
    func open() { provider { _ in } }
}
enum MacMenuElements {
    static func noteAction(_ text: String) -> UIMenuElement { UIMenuElement() }
    static func elements(_ content: MacMenuState.Content, client: StreamClient) -> [UIMenuElement] { [] }
    // DEFERRED
}
