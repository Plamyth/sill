import Darwin

var checks = 0
var failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !value() { failures += 1; print("FAIL \(name)") }
}

var toolbar = IPadToolbarVisibility(now: 10)
toolbar.update(now: 13.9, lastActivity: nil, touchesDown: false, enabled: true, foreground: true, pinned: false)
check(toolbar.visible, "fresh toolbar allows four seconds to discover controls")
toolbar.update(now: 14, lastActivity: nil, touchesDown: false, enabled: true, foreground: true, pinned: false)
check(!toolbar.visible && !toolbar.needsPolling, "idle hides and stops polling")
toolbar.toggle(now: 20, touchesDown: false, pinned: false)
check(toolbar.visible, "small reveal button restores controls")
toolbar.update(now: 24, lastActivity: 23, touchesDown: false, enabled: true, foreground: true, pinned: false)
check(toolbar.visible, "remote input or local action extends idle")
toolbar.update(now: 30, lastActivity: 23, touchesDown: true, enabled: true, foreground: true, pinned: false)
check(toolbar.visible, "stationary held drag blocks automatic resize")
toolbar.toggle(now: 30, touchesDown: true, pinned: false)
check(toolbar.visible, "manual hide also waits for the held remote touch")
toolbar.update(now: 31, lastActivity: 31, touchesDown: false, enabled: true, foreground: true, pinned: false)
check(!toolbar.visible, "manual hide completes after release")
toolbar.toggle(now: 32, touchesDown: true, pinned: false)
check(!toolbar.visible && toolbar.needsPolling, "second-finger reveal waits for existing drag and schedules follow-up")
toolbar.update(now: 33, lastActivity: 32, touchesDown: true, enabled: true, foreground: true, pinned: false)
check(!toolbar.visible, "reveal does not move the input geometry during drag")
toolbar.update(now: 34, lastActivity: 34, touchesDown: false, enabled: true, foreground: true, pinned: false)
check(toolbar.visible, "reveal completes after last finger or Pencil lifts")

for initiallyVisible in [false, true] {
    for held in [false, true] {
        var pinned = IPadToolbarVisibility(now: 0)
        if !initiallyVisible { pinned.toggle(now: 0, touchesDown: false, pinned: false) }
        pinned.update(now: 50, lastActivity: nil, touchesDown: held, enabled: true, foreground: true, pinned: true)
        check(pinned.visible == (initiallyVisible || !held), "open panel pins without resizing an active touch")
        pinned.update(now: 51, lastActivity: nil, touchesDown: false, enabled: true, foreground: true, pinned: true)
        check(pinned.visible, "pin reveals after held touch ends")
        pinned.toggle(now: 52, touchesDown: false, pinned: true)
        check(pinned.visible, "manual hide cannot remove open panel anchor")
        check(pinned.visible && !pinned.needsPolling, "panel or VoiceOver remains visible without a running timer")
        pinned.update(now: 101, lastActivity: nil, touchesDown: false, enabled: true, foreground: true, pinned: false)
        check(pinned.visible, "closing panel starts a fresh idle interval")
        pinned.update(now: 105, lastActivity: nil, touchesDown: false, enabled: true, foreground: true, pinned: false)
        check(!pinned.visible, "idle resumes after panel closes")
    }
}
var inactive = IPadToolbarVisibility(now: 0)
inactive.update(now: 100, lastActivity: nil, touchesDown: false, enabled: true, foreground: false, pinned: false)
check(inactive.visible, "scene inactivity produces no hidden layout mutation")
var phone = IPadToolbarVisibility(now: 0)
phone.update(now: 100, lastActivity: nil, touchesDown: false, enabled: false, foreground: true, pinned: false)
check(phone.visible, "disabled iPhone policy keeps its existing bar")

print("\(checks - failures)/\(checks) toolbar visibility checks passed; \(failures) failed")
exit(failures == 0 ? 0 : 1)
