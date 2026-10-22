import Foundation
import Network
import StreamProtocol

enum VisionInputBinding: Equatable {
    case awaitingCatalog
    case confirmedLegacy
    case scoped(generation: String)
    case awaitingPresentation(VideoEpoch?)
    case presented(VideoEpoch)

    init(catalog: WindowList) {
        if catalog.presentationInput == 1 {
            if let epoch = catalog.videoEpoch, epoch.matches(source: catalog.active, generation: catalog.inputGeneration) {
                self = .awaitingPresentation(epoch)
            } else { self = .awaitingPresentation(nil) }
        }
        else if let generation = catalog.inputGeneration { self = .scoped(generation: generation) }
        else { self = .confirmedLegacy }
    }

    var epoch: VideoEpoch? {
        switch self {
        case .awaitingPresentation(let epoch): return epoch
        case .presented(let epoch): return epoch
        default: return nil
        }
    }

    var isModern: Bool {
        switch self {
        case .awaitingPresentation, .presented: return true
        default: return false
        }
    }

    var isLegacy: Bool {
        switch self {
        case .confirmedLegacy, .scoped: return true
        default: return false
        }
    }

    var isConfirmed: Bool {
        switch self {
        case .awaitingCatalog, .awaitingPresentation: return false
        case .confirmedLegacy, .scoped, .presented: return true
        }
    }

    func capture(_ event: InputEvent) -> CapturedVisionInput? {
        switch self {
        case .awaitingCatalog, .awaitingPresentation: return nil
        case .presented(let epoch): return CapturedVisionInput(event: event, generation: epoch.generation, videoEpoch: epoch.id)
        case .confirmedLegacy: return CapturedVisionInput(event: event, generation: nil)
        case .scoped(let generation): return CapturedVisionInput(event: event, generation: generation)
        }
    }
}

struct VisionPeerStreams: Equatable {
    let connection = UUID()
    private(set) var requiresScope = false
    private(set) var compatible = false
    private(set) var source = StreamSource.none
    private(set) var epoch: VideoEpoch?
    private(set) var failure: String?

    enum Selection: Equatable {
        case source(StreamSource)
        case display(UInt32)
        case launch(String)

        func matches(_ catalog: WindowList) -> Bool {
            switch self {
            case .source(let source): return catalog.active == source
            case .display(let id): return catalog.active == .desktop && catalog.activeDisplayID == id
            case .launch(let bundle):
                guard case .window(let id) = catalog.active else { return false }
                return catalog.windows.contains { $0.id == id && $0.bundleID == bundle }
            }
        }
    }
    private var revision: String?
    private var catalogEpoch: UUID?
    private var activeDisplay: UInt32?
    private var activeBundle: String?
    private struct PendingSelection: Equatable {
        let selection: Selection
        let revision: String?
        let epoch: UUID?
    }
    private var pendingSelection: PendingSelection?

    @discardableResult
    mutating func selectionRequested(_ selection: Selection, presented: VideoEpoch? = nil) -> Bool {
        let sameTarget: Bool
        switch selection {
        case .source(let requested): sameTarget = source == requested
        case .display(let id): sameTarget = source == .desktop && activeDisplay == id
        case .launch(let bundle): sameTarget = activeBundle == bundle
        }
        if pendingSelection == nil, let presented, presented == epoch, sameTarget { return false }
        pendingSelection = PendingSelection(selection: selection, revision: revision, epoch: catalogEpoch)
        epoch = nil
        return true
    }

    mutating func observe(_ catalog: WindowList) {
        requiresScope = requiresScope || catalog.independentStreams != nil || catalog.sourceSelectionEffects != nil
        compatible = catalog.independentStreams == 1 && catalog.sourceSelectionEffects == 0 && catalog.presentationInput == 1
        source = catalog.active
        activeDisplay = catalog.activeDisplayID
        if case .window(let id) = source { activeBundle = catalog.windows.first { $0.id == id }?.bundleID }
        else { activeBundle = nil }
        failure = catalog.sourceSelectionFailure.map { SafeText.label($0, limit: 300) }.flatMap { $0.isEmpty ? nil : $0 }
        if requiresScope && !compatible { failure = "Mac의 독립 화면 정보를 확인할 수 없습니다. 다시 연결해 주세요." }
        if let pending = pendingSelection, pending.selection.matches(catalog),
           catalog.selectionRevision != pending.revision || catalog.videoEpoch?.id != pending.epoch {
            pendingSelection = nil
        }
        revision = catalog.selectionRevision
        catalogEpoch = catalog.videoEpoch?.id
        epoch = pendingSelection == nil && compatible && failure == nil && catalog.videoEpoch?.matches(source: catalog.active, generation: catalog.inputGeneration) == true
            ? catalog.videoEpoch : nil
    }

    func presentedEpoch(_ binding: VisionInputBinding) -> VideoEpoch? {
        guard requiresScope, compatible, case .presented(let shown) = binding, shown == epoch else { return nil }
        return shown
    }

    func inputCatalog(_ catalog: WindowList) -> WindowList {
        guard requiresScope else { return catalog }
        var result = catalog
        result.presentationInput = 1
        result.videoEpoch = epoch
        return result
    }
}

struct CapturedVisionInput {
    let event: InputEvent
    let generation: String?
    var videoEpoch: UUID? = nil

    var payload: Data { SourceInput.payload(event, generation: generation, videoEpoch: videoEpoch) }

    func replacing(_ event: InputEvent) -> Self {
        Self(event: event, generation: generation, videoEpoch: videoEpoch)
    }
}

// Accessed only while SessionLink holds its send lock. Queued inputs own no release debt.
final class VisionInputDebt {
    private struct HeldKey {
        let usage: UInt16
        let input: CapturedVisionInput
    }
    private var peer: NWConnection?
    private var keys: [HeldKey] = []
    private var left: CapturedVisionInput?
    private var right: CapturedVisionInput?
    private var scroll: CapturedVisionInput?

    func record(_ input: CapturedVisionInput, on connection: NWConnection) {
        if peer !== connection {
            peer = connection
            keys = []; left = nil; right = nil; scroll = nil
        }
        switch input.event {
        case .key(let key, let down, let flags):
            keys.removeAll { held in
                guard held.usage != key, let modifier = KeyModifiers.flag(forKey: held.usage) else { return false }
                return flags & modifier.rawValue == 0
            }
            keys.removeAll { $0.usage == key }
            if down { keys.append(HeldKey(usage: key, input: input)) }
        case .pointer(let action, let x, let y):
            switch action {
            case .leftDown: left = input
            case .rightDown: right = input
            case .leftUp: left = nil
            case .rightUp: right = nil
            case .move:
                left = left?.replacing(.pointer(.leftDown, x: x, y: y))
                right = right?.replacing(.pointer(.rightDown, x: x, y: y))
            }
        case .scrollGesture(let phase, _, _):
            switch phase {
            case .began, .momentumBegan: scroll = input
            case .ended, .momentumEnded: scroll = nil
            }
        case .text:
            keys.removeAll { KeyModifiers.flag(forKey: $0.usage) != nil }
        case .scroll: break
        }
    }

    func release(on connection: NWConnection?) -> [CapturedVisionInput] {
        guard peer === connection else { return [] }
        var out: [CapturedVisionInput] = []
        if let left, case .pointer(_, let x, let y) = left.event {
            out.append(left.replacing(.pointer(.leftUp, x: x, y: y)))
        }
        if let right, case .pointer(_, let x, let y) = right.event {
            out.append(right.replacing(.pointer(.rightUp, x: x, y: y)))
        }
        if let scroll, case .scrollGesture(let phase, let x, let y) = scroll.event {
            out.append(scroll.replacing(.scrollGesture(phase == .momentumBegan ? .momentumEnded : .ended, x: x, y: y)))
        }
        while let key = keys.popLast() {
            let flags = keys.reduce(UInt64(0)) { $0 | (KeyModifiers.flag(forKey: $1.usage)?.rawValue ?? 0) }
            out.append(key.input.replacing(.key(hidUsage: key.usage, down: false, modifiers: flags)))
        }
        peer = nil; left = nil; right = nil; scroll = nil
        return out
    }
}
