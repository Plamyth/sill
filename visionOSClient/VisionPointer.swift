import Foundation
import CoreGraphics
import StreamProtocol

struct VisionViewport: Equatable {
    private(set) var scale: CGFloat = 1
    private(set) var offset = CGSize.zero

    func point(_ point: CGPoint, in geometry: VisionPointer.Geometry, clamp: Bool = false) -> CGPoint? {
        guard let rect = geometry.fittedRect, point.x.isFinite, point.y.isFinite,
              clamp || geometry.bounds.contains(point) else { return nil }
        let x = geometry.bounds.midX + (point.x - geometry.bounds.midX - offset.width) / scale
        let y = geometry.bounds.midY + (point.y - geometry.bounds.midY - offset.height) / scale
        guard clamp || rect.contains(CGPoint(x: x, y: y)) else { return nil }
        return CGPoint(x: min(1, max(0, (x - rect.minX) / rect.width)),
                       y: min(1, max(0, (y - rect.minY) / rect.height)))
    }

    func magnified(by factor: CGFloat, at anchor: CGPoint, in geometry: VisionPointer.Geometry) -> Self? {
        guard factor.isFinite, factor > 0, point(anchor, in: geometry) != nil,
              let rect = geometry.fittedRect else { return nil }
        let next = min(4, max(1, scale * factor))
        let ratio = next / scale
        let dx = anchor.x - geometry.bounds.midX, dy = anchor.y - geometry.bounds.midY
        let limitX = max(0, (rect.width * next - geometry.bounds.width) / 2)
        let limitY = max(0, (rect.height * next - geometry.bounds.height) / 2)
        var result = self
        result.scale = next
        result.offset = CGSize(width: min(limitX, max(-limitX, dx - (dx - offset.width) * ratio)),
                               height: min(limitY, max(-limitY, dy - (dy - offset.height) * ratio)))
        return result
    }
}

struct VisionPointer {
    struct Geometry: Equatable {
        let bounds: CGRect
        let video: CGSize

        var fittedRect: CGRect? {
            guard [bounds.minX, bounds.minY, bounds.width, bounds.height, video.width, video.height].allSatisfy(\.isFinite),
                  bounds.width > 0, bounds.height > 0, video.width > 0, video.height > 0 else { return nil }
            let ratio = min(bounds.width / video.width, bounds.height / video.height)
            let width = video.width * ratio, height = video.height * ratio
            guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
            return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        }
    }

    struct Sample {
        enum Phase: Equatable { case active, ended, cancelled }
        let id: AnyHashable
        let timestamp: TimeInterval
        let location: CGPoint
        let phase: Phase
    }

    struct Flick {
        let anchor: CGPoint
        let velocity: CGPoint
    }

    private struct Contact {
        let id: AnyHashable
        let began: TimeInterval
        let origin: CGPoint
        let anchor: CGPoint
        let modifiers: KeyModifiers
        var last: CGPoint
        var lastRaw: CGPoint
        var lastTime: TimeInterval
        var motionTime: TimeInterval
        var velocity = CGPoint.zero

        mutating func track(_ sample: Sample) {
            let dt = sample.timestamp - lastTime
            if sample.location != lastRaw {
                let next = CGPoint(x: (sample.location.x - lastRaw.x) / dt,
                                   y: (sample.location.y - lastRaw.y) / dt)
                let speed = hypot(next.x, next.y)
                velocity = dt > 0 && dt <= 0.1 && speed.isFinite && speed <= 5000 ? next : .zero
                motionTime = sample.timestamp
            }
            lastTime = sample.timestamp
        }

        func scroll(to location: CGPoint, in rect: CGRect) -> InputEvent? {
            let dx = (location.x - lastRaw.x) / rect.width
            let dy = (location.y - lastRaw.y) / rect.height
            guard dx.isFinite, dy.isFinite else { return nil }
            return .scroll(x: anchor.x, y: anchor.y, dx: dx, dy: dy)
        }
    }
    private enum Stroke {
        case idle
        case pending(Contact)
        case scrolling(Contact)
        case dragging(Contact)
        case suppressed
    }
    private var stroke = Stroke.idle
    private var live: [AnyHashable: TimeInterval] = [:]
    private var retired: Set<AnyHashable> = []
    private(set) var flick: Flick?
    static let holdDuration: TimeInterval = 0.65
    static let movementThreshold: CGFloat = 8

    var isIdle: Bool { if case .idle = stroke { return true }; return false }

    static func isRelease(_ event: InputEvent) -> Bool {
        switch event {
        case .key(_, false, _), .pointer(.leftUp, _, _), .pointer(.rightUp, _, _),
             .scrollGesture(.ended, _, _), .scrollGesture(.momentumEnded, _, _): return true
        default: return false
        }
    }

    mutating func receive(_ samples: [Sample], geometry: Geometry, viewport: VisionViewport,
                          modifiers: KeyModifiers = []) -> [InputEvent] {
        if samples.contains(where: { !$0.timestamp.isFinite || !$0.location.x.isFinite || !$0.location.y.isFinite }) {
            let releases = cancel()
            stroke = .suppressed
            for sample in samples {
                if sample.phase == .active { live[sample.id] = live[sample.id] ?? -.infinity }
                else { live.removeValue(forKey: sample.id); retired.insert(sample.id) }
            }
            if live.isEmpty { stroke = .idle }
            return releases
        }
        var newest = live
        var finished = retired
        let fresh = samples.filter { sample in
            guard !finished.contains(sample.id), sample.timestamp >= (newest[sample.id] ?? -.infinity) else { return false }
            if sample.phase == .active { newest[sample.id] = sample.timestamp }
            else { newest.removeValue(forKey: sample.id); finished.insert(sample.id) }
            return true
        }.enumerated().sorted { left, right in
            left.element.timestamp == right.element.timestamp ? left.offset < right.offset
                : left.element.timestamp < right.element.timestamp
        }.map(\.element)
        var spans = Dictionary(uniqueKeysWithValues: live.keys.map { ($0, (start: -TimeInterval.infinity, end: TimeInterval.infinity)) })
        for sample in fresh {
            if sample.phase == .active, spans[sample.id] == nil {
                spans[sample.id] = (sample.timestamp, .infinity)
            } else if sample.phase != .active { spans[sample.id]?.end = sample.timestamp }
        }
        let intervals = Array(spans)
        var competing = Set<AnyHashable>()
        for (index, span) in intervals.enumerated() {
            for other in intervals.dropFirst(index + 1) where
                max(span.value.start, other.value.start) <= min(span.value.end, other.value.end) {
                competing.insert(span.key)
                competing.insert(other.key)
            }
        }
        var events: [InputEvent] = []
        for sample in fresh {
            guard !retired.contains(sample.id), sample.timestamp >= (live[sample.id] ?? -.infinity) else { continue }
            if competing.contains(sample.id) {
                events += cancel()
                stroke = .suppressed
            }
            let known = live[sample.id] != nil
            if sample.phase == .active { live[sample.id] = sample.timestamp }
            else { live.removeValue(forKey: sample.id); retired.insert(sample.id) }
            if case .suppressed = stroke {
                if live.isEmpty { stroke = .idle }
                continue
            }
            if sample.phase == .cancelled { events += cancel(); continue }
            if case .idle = stroke {
                guard sample.phase == .active, !known,
                      let p = viewport.point(sample.location, in: geometry) else { stroke = .suppressed; continue }
                stroke = .pending(Contact(id: sample.id, began: sample.timestamp, origin: sample.location,
                                          anchor: p, modifiers: modifiers, last: p, lastRaw: sample.location,
                                          lastTime: sample.timestamp, motionTime: sample.timestamp))
                flick = nil
                events.append(.pointer(.move, x: p.x, y: p.y))
                continue
            }
            guard let p = viewport.point(sample.location, in: geometry, clamp: true),
                  let rect = geometry.fittedRect else { events += cancel(); continue }
            switch stroke {
            case .pending(var contact):
                guard contact.id == sample.id else { events += cancel(); continue }
                let elapsed = sample.timestamp - contact.began
                let moved = hypot(sample.location.x - contact.origin.x, sample.location.y - contact.origin.y) >= Self.movementThreshold
                if moved {
                    if elapsed < Self.holdDuration || contact.modifiers.isEmpty {
                        guard let scroll = contact.scroll(to: sample.location, in: rect) else { events += cancel(); continue }
                        events += KeyChord.modifiersDown(contact.modifiers)
                            + [.scrollGesture(.began, x: contact.anchor.x, y: contact.anchor.y), scroll]
                        contact.track(sample)
                        contact.last = p
                        contact.lastRaw = sample.location
                        stroke = .scrolling(contact)
                    } else {
                        events += KeyChord.modifiersDown(contact.modifiers)
                            + [.pointer(.leftDown, x: contact.anchor.x, y: contact.anchor.y), .pointer(.move, x: p.x, y: p.y)]
                        contact.last = p
                        stroke = .dragging(contact)
                    }
                } else if sample.phase == .ended {
                    if viewport.point(sample.location, in: geometry) != nil {
                        let right = elapsed >= Self.holdDuration
                        events += KeyChord.modifiersDown(contact.modifiers)
                            + [.pointer(right ? .rightDown : .leftDown, x: contact.anchor.x, y: contact.anchor.y),
                               .pointer(right ? .rightUp : .leftUp, x: contact.anchor.x, y: contact.anchor.y)]
                            + KeyChord.modifiersUp(contact.modifiers)
                    }
                    stroke = .idle
                }
            case .scrolling(var contact):
                if sample.location != contact.lastRaw {
                    guard let scroll = contact.scroll(to: sample.location, in: rect) else { events += cancel(); continue }
                    events.append(scroll)
                }
                contact.track(sample)
                contact.last = p
                contact.lastRaw = sample.location
                stroke = .scrolling(contact)
            case .dragging(var contact):
                if p != contact.last { events.append(.pointer(.move, x: p.x, y: p.y)) }
                contact.last = p
                stroke = .dragging(contact)
            case .idle, .suppressed: break
            }
            if sample.phase == .ended {
                if case .scrolling(let contact) = stroke, contact.modifiers.isEmpty,
                   sample.timestamp - contact.motionTime <= 0.08 {
                    flick = Flick(anchor: contact.anchor, velocity: contact.velocity)
                }
                events += finishStroke()
            }
        }
        if live.isEmpty { stroke = .idle }
        return events
    }

    private mutating func finishStroke() -> [InputEvent] {
        defer { stroke = .idle }
        switch stroke {
        case .dragging(let contact):
            return [.pointer(.leftUp, x: contact.last.x, y: contact.last.y)] + KeyChord.modifiersUp(contact.modifiers)
        case .scrolling(let contact):
            return [.scrollGesture(.ended, x: contact.anchor.x, y: contact.anchor.y)] + KeyChord.modifiersUp(contact.modifiers)
        case .idle, .pending, .suppressed: return []
        }
    }

    mutating func cancel() -> [InputEvent] {
        flick = nil
        let releases = finishStroke()
        if !live.isEmpty { stroke = .suppressed }
        return releases
    }
}
