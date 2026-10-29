import Foundation
import CoreFoundation
import CoreGraphics

enum KeyStrokes {
    __DEVICE_TYPEALIAS__
}

struct ProtectedPointerScope {}

final class ClickHarness {
    var now: CFAbsoluteTime = 0
    private func clock() -> CFAbsoluteTime { now }

    __PRODUCTION_CLICK_STATE__

    enum Button { case left, right }
    private var left = ButtonState()
    private var right = ButtonState()

    func down(_ device: KeyStrokes.Device, button: Button = .left,
              at point: CGPoint = .zero) -> Int64 {
        switch button {
        case .left:
            precondition(left.owner == nil)
            beginClick(&left, at: point, from: device)
            return left.clicks
        case .right:
            precondition(right.owner == nil)
            beginClick(&right, at: point, from: device)
            return right.clicks
        }
    }

    func up(_ device: KeyStrokes.Device, button: Button = .left) -> Int64 {
        switch button {
        case .left:
            precondition(left.owner == device)
            let clicks = left.clicks
            left.owner = nil
            return clicks
        case .right:
            precondition(right.owner == device)
            let clicks = right.clicks
            right.owner = nil
            return clicks
        }
    }

    func released(_ button: Button = .left) -> Bool {
        switch button {
        case .left: return left.owner == nil
        case .right: return right.owner == nil
        }
    }
}

@main
struct Checks {
    static var checks = 0
    static var failures = 0

    static func expect(_ actual: Int64, _ expected: Int64, _ label: String) {
        checks += 1
        if actual != expected { failures += 1 }
        print("\(actual == expected ? "PASS" : "FAIL") \(label) expected\(expected) actual\(actual)")
    }

    static func tap(_ f: ClickHarness, _ device: KeyStrokes.Device, expected: Int64,
                    label: String, button: ClickHarness.Button = .left, at point: CGPoint = .zero) {
        expect(f.down(device, button: button, at: point), expected, label)
        expect(f.up(device, button: button), expected, label + " up")
        expect(f.released(button) ? 1 : 0, 1, label + " owner=nil")
    }

    static func main() {
        let deviceA = NSObject(), deviceB = NSObject()
        let a = ObjectIdentifier(deviceA), b = ObjectIdentifier(deviceB)
        for button in [ClickHarness.Button.left, .right] {
            let f = ClickHarness()
            tap(f, a, expected: 1, label: "A", button: button)
            f.now = 0.1
            tap(f, b, expected: 1, label: "B", button: button)
            f.now = 0.2
            tap(f, b, expected: 2, label: "B double", button: button)
            f.now = 0.3
            tap(f, b, expected: 3, label: "B triple", button: button)

            let alternating = ClickHarness()
            for (index, device) in [a, b, a, b, a].enumerated() {
                alternating.now = Double(index) * 0.05
                tap(alternating, device, expected: 1, label: "alternating \(index)", button: button)
            }
        }

        let split = ClickHarness()
        tap(split, a, expected: 1, label: "left A")
        split.now = 0.05
        tap(split, b, expected: 1, label: "right B", button: .right)
        split.now = 0.1
        tap(split, a, expected: 2, label: "left A double")
        split.now = 0.15
        tap(split, b, expected: 2, label: "right B double", button: .right)

        let same = ClickHarness()
        for index in 1...3 {
            same.now = Double(index) * 0.05
            tap(same, a, expected: Int64(index), label: "same device \(index)")
        }

        let bounds: [(CFAbsoluteTime, CGPoint, Int64, String)] = [
            (0.35, CGPoint(x: 12, y: 0), Int64(2), "inclusive time/slop"),
            (0.350001, .zero, 1, "outside time"),
            (0.1, CGPoint(x: 12.000001, y: 0), 1, "outside slop"),
            (0.1, CGPoint(x: 9, y: 9), 1, "Euclidean distance"),
            (0.1, CGPoint(x: 3, y: 4), 2, "within time/slop")
        ]
        for (time, point, expected, label) in bounds {
            let f = ClickHarness()
            tap(f, a, expected: 1, label: label + " first")
            f.now = time
            tap(f, a, expected: expected, label: label)
        }

        print("SUMMARY checks=\(checks) failures=\(failures); pure extracted Swift; CGEvent/Host/UI/HAL actions=0")
        exit(failures == 0 ? 0 : 1)
    }
}
