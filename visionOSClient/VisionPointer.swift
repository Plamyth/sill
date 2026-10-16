import Foundation
import CoreGraphics
import StreamProtocol

struct VisionPointer {
    enum Mode: String, CaseIterable { case pointer = "포인터", right = "오른쪽 클릭", scroll = "스크롤" }
    private enum Stroke {
        case idle
        case dragging(CGPoint)
        case scrolling(anchor: CGPoint, last: CGPoint)
        case cancelled
    }
    private var stroke = Stroke.idle
    private var modifiers: KeyModifiers = []

    var isIdle: Bool { if case .idle = stroke { return true }; return false }

    static func isRelease(_ event: InputEvent) -> Bool {
        switch event {
        case .key(_, false, _), .pointer(.leftUp, _, _), .pointer(.rightUp, _, _),
             .scrollGesture(.ended, _, _), .scrollGesture(.momentumEnded, _, _): return true
        default: return false
        }
    }

    static func point(_ point: CGPoint, bounds: CGRect, video: CGSize, clamp: Bool = false) -> CGPoint? {
        guard [point.x, point.y, bounds.minX, bounds.minY, bounds.width, bounds.height, video.width, video.height].allSatisfy(\.isFinite) else { return nil }
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let ratio = min(bounds.width / video.width, bounds.height / video.height)
        let width = video.width * ratio, height = video.height * ratio
        let rect = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        guard clamp || rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / width)),
                       y: min(1, max(0, (point.y - rect.minY) / height)))
    }

    mutating func tap(_ p: CGPoint, mode: Mode, modifiers: KeyModifiers = []) -> [InputEvent] {
        guard case .idle = stroke, mode != .scroll else { return [] }
        let down: PointerAction = mode == .right ? .rightDown : .leftDown
        let up: PointerAction = mode == .right ? .rightUp : .leftUp
        return KeyChord.modifiersDown(modifiers)
            + [.pointer(down, x: p.x, y: p.y), .pointer(up, x: p.x, y: p.y)]
            + KeyChord.modifiersUp(modifiers)
    }

    mutating func drag(from start: CGPoint, to p: CGPoint, mode: Mode, modifiers: KeyModifiers = []) -> [InputEvent] {
        switch stroke {
        case .idle:
            if mode == .scroll {
                self.modifiers = modifiers
                stroke = .scrolling(anchor: start, last: p)
                return KeyChord.modifiersDown(modifiers) + [.scrollGesture(.began, x: start.x, y: start.y),
                        .scroll(x: start.x, y: start.y, dx: p.x - start.x, dy: p.y - start.y)]
            }
            guard mode == .pointer else { return [] }
            self.modifiers = modifiers
            stroke = .dragging(p)
            return KeyChord.modifiersDown(modifiers) + [.pointer(.leftDown, x: start.x, y: start.y), .pointer(.move, x: p.x, y: p.y)]
        case .dragging:
            stroke = .dragging(p)
            return [.pointer(.move, x: p.x, y: p.y)]
        case .scrolling(let anchor, let last):
            stroke = .scrolling(anchor: anchor, last: p)
            return [.scroll(x: anchor.x, y: anchor.y, dx: p.x - last.x, dy: p.y - last.y)]
        case .cancelled: return []
        }
    }

    mutating func end() -> [InputEvent] {
        defer { stroke = .idle; modifiers = [] }
        switch stroke {
        case .idle, .cancelled: return []
        case .dragging(let p): return [.pointer(.leftUp, x: p.x, y: p.y)] + KeyChord.modifiersUp(modifiers)
        case .scrolling(let anchor, _): return [.scrollGesture(.ended, x: anchor.x, y: anchor.y)] + KeyChord.modifiersUp(modifiers)
        }
    }

    mutating func cancel() -> [InputEvent] {
        guard !isIdle else { return [] }
        let releases = end()
        stroke = .cancelled
        return releases
    }
}
