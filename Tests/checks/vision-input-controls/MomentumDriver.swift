import Foundation

struct CAFrameRateRange {
    let minimum: Float
    let maximum: Float
    let preferred: Float
}

enum MomentumClock {
    static var now = 100.0
    static func advance(_ dt: Double = 1.0 / 60) {
        now += dt
        for link in CADisplayLink.active { link.tick(now) }
    }
}

func CACurrentMediaTime() -> Double { MomentumClock.now }

final class CADisplayLink: NSObject {
    static var active: [CADisplayLink] = []
    private let target: NSObject
    private let selector: Selector
    var targetTimestamp = 0.0
    var preferredFrameRateRange = CAFrameRateRange(minimum: 0, maximum: 0, preferred: 0)

    init(target: NSObject, selector: Selector) {
        self.target = target
        self.selector = selector
    }

    func add(to: RunLoop, forMode: RunLoop.Mode) { Self.active.append(self) }
    func invalidate() { Self.active.removeAll { $0 === self } }
    func tick(_ time: Double) {
        guard Self.active.contains(where: { $0 === self }) else { return }
        targetTimestamp = time
        _ = target.perform(selector, with: self)
    }
}
