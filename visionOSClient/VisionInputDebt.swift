import Foundation
import Network
import StreamProtocol

enum VisionInputBinding: Equatable {
    case awaitingCatalog
    case confirmedLegacy
    case scoped(generation: String)

    init(catalog: WindowList) {
        if let generation = catalog.inputGeneration { self = .scoped(generation: generation) }
        else { self = .confirmedLegacy }
    }

    var isConfirmed: Bool {
        if case .awaitingCatalog = self { return false }
        return true
    }

    func capture(_ event: InputEvent) -> CapturedVisionInput? {
        switch self {
        case .awaitingCatalog: return nil
        case .confirmedLegacy: return CapturedVisionInput(event: event, generation: nil)
        case .scoped(let generation): return CapturedVisionInput(event: event, generation: generation)
        }
    }
}

struct CapturedVisionInput {
    let event: InputEvent
    let generation: String?

    var payload: Data { SourceInput.payload(event, generation: generation) }

    func replacing(_ event: InputEvent) -> Self {
        Self(event: event, generation: generation)
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
        if let scroll, case .scrollGesture(_, let x, let y) = scroll.event {
            out.append(scroll.replacing(.scrollGesture(.ended, x: x, y: y)))
        }
        while let key = keys.popLast() {
            let flags = keys.reduce(UInt64(0)) { $0 | (KeyModifiers.flag(forKey: $1.usage)?.rawValue ?? 0) }
            out.append(key.input.replacing(.key(hidUsage: key.usage, down: false, modifiers: flags)))
        }
        peer = nil; left = nil; right = nil; scroll = nil
        return out
    }
}
