import Foundation
import CoreGraphics
import SwiftUI

struct UIDevice {
    enum Idiom { case pad, phone }
    static var current = UIDevice(userInterfaceIdiom: .pad)
    var userInterfaceIdiom: Idiom
}

// PRODUCTION_TYPES
// PRODUCTION_PORTRAIT

struct KeyboardGeometry {
    struct Insets { let bottom: CGFloat }
    let size: CGSize
    let safeAreaInsets: Insets
}
func classifiedLayout(width: CGFloat, height: CGFloat, bottom: CGFloat) -> DuoLayout {
    let geo = KeyboardGeometry(size: CGSize(width: width, height: height), safeAreaInsets: .init(bottom: bottom))
    // PRODUCTION_LAYOUT
    return duo
}

struct Proposal {
    let window: CGRect
    let keyboard: CGRect?
    func ignoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all) -> CGRect {
        guard !regions.contains(.keyboard), edges.contains(.bottom), let keyboard,
              keyboard.minX <= window.minX, keyboard.maxX >= window.maxX,
              keyboard.maxY >= window.maxY, keyboard.minY < window.maxY else { return window }
        return CGRect(x: window.minX, y: window.minY, width: window.width,
                      height: max(0, keyboard.minY - window.minY))
    }
    var proposed: CGRect { self/*PRODUCTION_SAFE_AREA*/ }
}

struct HEVCDisplayView {
    // PRODUCTION_VIDEO_RECT
}
struct InputProbe {
    let bounds: CGRect
    let videoSize: CGSize
    private var videoRect: CGRect { HEVCDisplayView.videoRect(in: bounds, videoSize: videoSize) }
    // PRODUCTION_NORMALIZED
    func point(_ point: CGPoint, clamped: Bool) -> (x: Double, y: Double)? { normalized(point, clamped: clamped) }
}

var checks = 0
var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL \(name)") }
}
func near(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 0.000001 }
let window = CGRect(x: 0, y: 24, width: 1194, height: 810)
for (width, fullHeight, visibleHeight, keyboardHeight) in [
    (1366.0, 992.0, 532.0, 460.0),
    (1024.0, 1334.0, 874.0, 460.0),
    (500.0, 710.0, 400.0, 310.0)
] {
    expect(classifiedLayout(width: width, height: fullHeight, bottom: 0) ==
           classifiedLayout(width: width, height: visibleHeight, bottom: keyboardHeight),
           "keyboard preserves view branch and responder at \(width)x\(fullHeight)")
}
expect(classifiedLayout(width: 1366, height: 500, bottom: 0) == .outerLandscape,
       "actual window resize still changes compact layout")
for (width, height) in [(500.0, 400.0), (320.0, 350.0), (600.0, 350.0)] {
    let metrics = width < DuoLayout.outerMaxWidth ? PortraitMetrics.compact : .regular
    let split = DuoPosture.portraitSplit(CGSize(width: width, height: height), .inferred,
                                       aspect: 1.6, controls: metrics.controlsHeight)
    for toolbarShown in [true, false] {
        let reclaimed = toolbarShown ? 0 : metrics.barHeight + metrics.rowGap
        let available = height - split.controls - reclaimed
        let required = metrics.controlsHeight - reclaimed
        expect(available >= required,
               "portrait controls fit above keyboard at \(width)x\(height), toolbar=\(toolbarShown), available=\(available), required=\(required)")
    }
}
for metrics in [PortraitMetrics.compact, .regular] {
    let required = metrics.controlsHeight
    for height in [required - 1, required, required + 1, 2 * required - 1, 2 * required, 2 * required + 1, 1000] {
        let size = CGSize(width: 500, height: height)
        let split = DuoPosture.portraitSplit(size, .inferred, aspect: 1.6, controls: required)
        expect(split.picture == split.controls && split.picture >= 0,
               "small portrait panes stay adjacent with a nonnegative picture")
        if height < required {
            expect(split.picture == 0, "an impossibly short window gives all available room to controls")
        } else if height - (height / 2).rounded() >= required {
            expect(split.picture == (height / 2).rounded(), "normal portrait retains its midpoint after keyboard dismissal")
        } else {
            expect(height - split.controls == required, "small portrait gives controls only their missing room")
        }
    }
}
let docked = CGRect(x: 0, y: 482, width: 1194, height: 352)
let baseline = Proposal(window: window, keyboard: nil).proposed
expect(baseline == window, "no keyboard preserves container-bottom extent")
expect(SafeAreaRegions.all.contains(.keyboard), "default all region includes keyboard")

for keyboard in [docked, CGRect(x: 0, y: 510, width: 1194, height: 324),
                 CGRect(x: 0, y: 790, width: 1194, height: 44)] {
    let visible = Proposal(window: window, keyboard: keyboard).proposed
    let layout = DuoLayout.of(visible.size)
    let bar = layout == .outerLandscape ? BarMetrics.compact : BarMetrics.regular
    let panel = CGRect(x: visible.minX + 8, y: visible.minY + bar.height + 8,
                       width: visible.width - 16, height: visible.height - bar.height - 16)
    for video in [CGSize(width: 1920, height: 1080), CGSize(width: 1600, height: 1000), CGSize(width: 900, height: 1600)] {
        let bounds = CGRect(origin: .zero, size: panel.size)
        let rect = HEVCDisplayView.videoRect(in: bounds, videoSize: video)
        let screenVideo = rect.offsetBy(dx: panel.minX, dy: panel.minY)
        expect(screenVideo.maxY <= keyboard.minY, "entire video remains above docked keyboard top \(keyboard.minY)")
        expect(panel.maxY <= keyboard.minY, "shared panel/viewport ends above docked keyboard")
        let input = InputProbe(bounds: bounds, videoSize: video)
        for (x, y) in [(0.0, 0.0), (0.5, 0.5), (0.95, 0.9), (0.999, 0.999)] {
            let point = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
            let mapped = input.point(point, clamped: false)
            expect(mapped.map { near($0.x, x) && near($0.y, y) } == true,
                   "resized video and input normalize the same visible point")
        }
        if rect.minX > 0 {
            expect(input.point(CGPoint(x: rect.minX / 2, y: rect.midY), clamped: false) == nil,
                   "letterbox tap remains rejected after keyboard resize")
        }
    }
    print("synthetic keyboardTop=\(keyboard.minY), proposedHeight=\(visible.height), panel=\(panel)")
}
for keyboard: CGRect? in [nil, CGRect(x: 740, y: 510, width: 320, height: 250),
                         CGRect(x: 740, y: 584, width: 320, height: 250),
                         CGRect(x: 0, y: 834, width: 1194, height: 352)] {
    expect(Proposal(window: window, keyboard: keyboard).proposed == baseline,
           "hardware, floating, bottom-adjacent floating, or hidden keyboard does not reserve full-width space")
}
UIDevice.current.userInterfaceIdiom = .phone
expect(Proposal(window: window, keyboard: docked).proposed == window,
       "phone retains intentional keyboard-over-trackpad behavior")
print("\(checks - failures)/\(checks) synthetic keyboard geometry checks passed; \(failures) failed")
exit(failures == 0 ? 0 : 1)
