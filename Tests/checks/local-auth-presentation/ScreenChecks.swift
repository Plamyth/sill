import Foundation
import struct CoreGraphics.CGRect

struct NSDeviceDescriptionKey: Hashable { let rawValue: String; init(_ value: String) { rawValue = value } }
final class NSScreen {
    static var screens: [NSScreen] = []
    let frame = CGRect(x: 0,y: 0,width: 1000,height: 1000)
    let deviceDescription: [NSDeviceDescriptionKey: Any]
    init(_ id: UInt32?) { deviceDescription = id.map { [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: $0)] } ?? [:] }
}
func CGDisplayIsBuiltin(_ id: UInt32) -> UInt32 { [2, 3, 4].contains(id) ? 1 : 0 }
func CGDisplayIsActive(_ id: UInt32) -> UInt32 { id == 3 ? 0 : 1 }
func CGDisplayIsAsleep(_ id: UInt32) -> UInt32 { id == 4 ? 1 : 0 }

enum WindowLevelKey { case screenSaverWindow }
func CGWindowLevelForKey(_ key: WindowLevelKey) -> Int32 { 1000 }
final class NSWindow {
    struct Identifier { var rawValue: String }
    struct Level { var rawValue: Int }
    enum Sharing { case none, readWrite }
    var identifier: Identifier? = Identifier(rawValue: "CCR.LocalAuthentication")
    var isVisible = true, isOnActiveSpace = true, isOpaque = true, ignoresMouseEvents = false
    var windowNumber = 91
    var alphaValue = 1.0
    var sharingType = Sharing.none
    var level = Level(rawValue: 1002)
    var frame = CGRect(x: 40,y: 300,width: 480,height: 240)
    var screen: NSScreen? = NSScreen.screens.first
    var attachedSheet: NSWindow?
    weak var sheetParent: NSWindow?
}

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

@MainActor func windowChecks() {
    NSScreen.screens = [NSScreen(2)]
    func expect(_ value: Bool, _ name: String) {
        guard value else { print("FAIL \(name)"); exit(1) }
        print("PASS \(name)")
    }
    let id = UUID(), root = NSWindow()
    let owner = LocalAuthenticationPresentation(window: root, operationID: id)
    expect(owner.matches(operationID: id), "현재 UUID의 유효한 커튼 위 인증 창 수용")
    expect(!owner.matches(operationID: UUID()), "다른 인증 UUID 거부")
    let mutations: [(String, (NSWindow) -> Void)] = [
        ("alpha", { $0.alphaValue = 0 }), ("opacity", { $0.isOpaque = false }),
        ("sharing", { $0.sharingType = .readWrite }), ("space", { $0.isOnActiveSpace = false }),
        ("visible", { $0.isVisible = false }), ("mouse", { $0.ignoresMouseEvents = true }),
        ("window-id", { $0.windowNumber = 0 }), ("private-id", { $0.identifier = nil }),
        ("level", { $0.level.rawValue = 1001 }), ("display", { $0.screen = NSScreen(1) }),
        ("frame", { $0.frame.origin.x = 3000 })
    ]
    for (name, mutate) in mutations {
        let w = NSWindow(), request = UUID()
        let presenter = LocalAuthenticationPresentation(window: w, operationID: request)
        mutate(w)
        expect(!presenter.matches(operationID: request), "완료 직전 \(name) 변경 거부")
    }
    let parent = NSWindow(), request = UUID(), sheet = NSWindow()
    let presenter = LocalAuthenticationPresentation(window: parent, operationID: request)
    sheet.windowNumber = 92; sheet.level.rawValue = 1003; sheet.sheetParent = parent; parent.attachedSheet = sheet
    expect(presenter.matches(operationID: request), "정확한 공식 부모 관계의 시트 수용")
    sheet.sheetParent = nil
    expect(!presenter.matches(operationID: request), "부모 관계가 사라진 시트는 완료로 수용하지 않음")
    sheet.sheetParent = parent; sheet.alphaValue = 0
    expect(!presenter.matches(operationID: request), "투명해진 인증 시트는 완료로 수용하지 않음")
    sheet.alphaValue = 1; sheet.isOnActiveSpace = false
    expect(!presenter.matches(operationID: request), "다른 space의 인증 시트 거부")
    sheet.isOnActiveSpace = true; sheet.level.rawValue = 1001
    expect(!presenter.matches(operationID: request), "커튼 아래 시트 거부")
    let replacement = LocalAuthenticationPresentation(window: NSWindow(), operationID: request)
    expect(!presenter.matches(operationID: request) && replacement.matches(operationID: request),
           "같은 UUID라도 이전 소유 객체는 완료 판정을 하지 못함")
}
await windowChecks()
