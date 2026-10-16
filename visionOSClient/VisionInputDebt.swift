import Foundation
import Network
import StreamProtocol

// Accessed only while SessionLink holds its send lock. Queued inputs own no release debt.
final class VisionInputDebt {
    private var peer: NWConnection?
    private var keys: [UInt16] = []
    private var left: CGPoint?
    private var right: CGPoint?
    private var scroll: CGPoint?

    func record(_ event: InputEvent, on connection: NWConnection) {
        if peer !== connection {
            peer = connection
            keys = []; left = nil; right = nil; scroll = nil
        }
        switch event {
        case .key(let key, let down, let flags):
            keys.removeAll { usage in
                guard usage != key, let modifier = KeyModifiers.flag(forKey: usage) else { return false }
                return flags & modifier.rawValue == 0
            }
            keys.removeAll { $0 == key }
            if down { keys.append(key) }
        case .pointer(let action, let x, let y):
            let p = CGPoint(x: x, y: y)
            switch action {
            case .leftDown: left = p
            case .rightDown: right = p
            case .leftUp: left = nil
            case .rightUp: right = nil
            case .move:
                if left != nil { left = p }
                if right != nil { right = p }
            }
        case .scrollGesture(let phase, let x, let y):
            switch phase {
            case .began, .momentumBegan: scroll = CGPoint(x: x, y: y)
            case .ended, .momentumEnded: scroll = nil
            }
        case .text:
            keys.removeAll { KeyModifiers.flag(forKey: $0) != nil }
        case .scroll: break
        }
    }

    func release(on connection: NWConnection?) -> [InputEvent] {
        guard peer === connection else { return [] }
        var out: [InputEvent] = []
        if let left { out.append(.pointer(.leftUp, x: left.x, y: left.y)) }
        if let right { out.append(.pointer(.rightUp, x: right.x, y: right.y)) }
        if let scroll { out.append(.scrollGesture(.ended, x: scroll.x, y: scroll.y)) }
        while let key = keys.popLast() {
            let flags = keys.reduce(UInt64(0)) { $0 | (KeyModifiers.flag(forKey: $1)?.rawValue ?? 0) }
            out.append(.key(hidUsage: key, down: false, modifiers: flags))
        }
        peer = nil; left = nil; right = nil; scroll = nil
        return out
    }
}
