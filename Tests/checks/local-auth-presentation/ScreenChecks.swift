import Foundation

struct NSDeviceDescriptionKey: Hashable { let rawValue: String; init(_ value: String) { rawValue = value } }
final class NSScreen {
    let deviceDescription: [NSDeviceDescriptionKey: Any]
    init(_ id: UInt32?) { deviceDescription = id.map { [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: $0)] } ?? [:] }
}
func CGDisplayIsBuiltin(_ id: UInt32) -> UInt32 { [2, 3, 4].contains(id) ? 1 : 0 }
func CGDisplayIsActive(_ id: UInt32) -> UInt32 { id == 3 ? 0 : 1 }
func CGDisplayIsAsleep(_ id: UInt32) -> UInt32 { id == 4 ? 1 : 0 }

@MainActor func screenChecks() {
    let external = NSScreen(1), builtin = NSScreen(2), inactive = NSScreen(3), asleep = NSScreen(4)
    let cases: [([NSScreen], NSScreen?, String)] = [
        ([external, builtin], builtin, "external main display cannot replace builtin screen"),
        ([builtin, external], builtin, "screen order does not change builtin selection"),
        ([external], nil, "external-only setup does not silently fall back"),
        ([inactive], nil, "inactive builtin is rejected"),
        ([asleep], nil, "sleeping builtin is rejected"),
        ([NSScreen(nil)], nil, "missing display identity is rejected"),
        ([builtin, NSScreen(2)], nil, "ambiguous builtin mapping is rejected"),
        ([], nil, "absent screens are rejected")
    ]
    for (screens, expected, name) in cases {
        let actual = LocalAuthenticationPresentation.builtinScreen(in: screens)
        guard actual === expected else { print("FAIL \(name)"); exit(1) }
        print("PASS \(name)")
    }
}
await screenChecks()
