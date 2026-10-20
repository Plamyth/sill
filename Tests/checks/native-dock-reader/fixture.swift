import AppKit
import ApplicationServices
import StreamProtocol

// PRODUCTION_POLICY

typealias FixtureElement = Int
enum FixtureRunningApplication {
    struct App { let processIdentifier: Int32 = 42 }
    static func runningApplications(withBundleIdentifier: String) -> [App] { [App()] }
}
struct FixtureBundle {
    let bundleIdentifier: String?
    init?(url: URL) {
        Fixture.bundleReads += 1
        bundleIdentifier = Fixture.unresolved ? nil : Fixture.privateApp || Fixture.bundleReads == Fixture.privateAtRead
            ? "com.openai.sky.CUAService" : "fixture.app"
    }
}
struct FixtureWorkspace {
    static let shared = FixtureWorkspace()
    func icon(forFile: String) -> NSImage {
        fatalError("격리 검사는 OS 아이콘을 조회하지 않습니다.")
    }
}
enum Fixture {
    static var now: TimeInterval = 100
    static var count = 1
    static var privateApp = false, unresolved = false
    static var bundleReads = 0, privateAtRead = -1
    static var menuOpen = false, rootMissing = false, trusted = true, enabled = true
    static var menuCount = 1, levels = 1
    static var actions: [(Int, String)] = []
    static var timeouts: [Int: Float] = [:]
    static var menuCost: TimeInterval = 0
    static var menuReads = 0
    static var failCancel = false, failPress = false
    static var longTitle = false, missingMenuTitle = false

    static func reset() {
        now = 100; count = 1; privateApp = false; unresolved = false
        bundleReads = 0; privateAtRead = -1
        menuOpen = false; rootMissing = false; trusted = true; enabled = true
        menuCount = 1; levels = 1; actions = []; timeouts = [:]; menuCost = 0; menuReads = 0
        failCancel = false; failPress = false; longTitle = false; missingMenuTitle = false
    }
    static func url(_ i: Int) -> URL { URL(fileURLWithPath: "/fixture/App\(i).app") }
}
func FixtureAXIsProcessTrusted() -> Bool { Fixture.trusted }
func FixtureFixtureElementCreateApplication(_ pid: Int32) -> Int { 0 }
func FixtureFixtureElementSetMessagingTimeout(_ element: Int, _ timeout: Float) -> AXError {
    Fixture.timeouts[element] = timeout
    return .success
}
func FixtureFixtureElementPerformAction(_ element: Int, _ action: CFString) -> AXError {
    let name = action as String
    Fixture.actions.append((element, name))
    if name == kAXShowMenuAction as String { Fixture.menuOpen = true }
    if name == kAXCancelAction as String {
        if Fixture.failCancel { return .cannotComplete }
        Fixture.menuOpen = false
    }
    if name == kAXPressAction as String {
        if Fixture.failPress { return .cannotComplete }
        Fixture.menuOpen = false
    }
    return .success
}
func FixtureFixtureElementCopyAttributeValue(_ element: Int, _ name: CFString, _ result: inout CFTypeRef?) -> AXError {
    let key = name as String
    if Fixture.menuOpen {
        Fixture.menuReads += 1
        let timeout = TimeInterval(Fixture.timeouts[element] ?? 1)
        Fixture.now += min(Fixture.menuCost, timeout)
        if Fixture.menuCost > timeout { return .cannotComplete }
    }
    let tile = element >= 10 && element < 210
    let menu = element >= 1000 && element % 1000 == 0
    let leaf = element >= 1000 && element % 1000 != 0
    var value: Any?
    if key == kAXRoleAttribute as String {
        value = element == 0 ? "AXApplication" : element == 1 ? "AXList" : tile ? "AXDockItem" : menu ? "AXMenu" : "AXMenuItem"
    } else if key == kAXChildrenAttribute as String {
        if element == 0 { value = [1] }
        else if element == 1 { value = Array(10..<(10 + Fixture.count)) }
        else if tile { value = Fixture.menuOpen && !Fixture.rootMissing ? [1000] : [] }
        else if menu { value = Array((element + 1)...(element + Fixture.menuCount)) }
        else if leaf { value = element / 1000 < Fixture.levels ? [(element / 1000 + 1) * 1000] : [] }
    } else if key == kAXTitleAttribute as String {
        value = Fixture.longTitle ? String(repeating: "\u{01}", count: 50000) : tile ? "App \(element)" : "열기 \(element)"
        if leaf && Fixture.missingMenuTitle { value = nil }
    } else if key == kAXSubroleAttribute as String, tile {
        value = "AXApplicationDockItem"
    } else if key == kAXURLAttribute as String, tile {
        value = Fixture.url(element - 10)
    } else if key == "AXIsApplicationRunning", tile {
        value = true
    } else if key == kAXEnabledAttribute as String { value = Fixture.enabled }
    guard let value else { return .noValue }
    result = value as CFTypeRef
    return .success
}

@main struct Checks {
    @MainActor static func main() {
        var failures: [String] = []
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL") \(name)")
            if !value { failures.append(name) }
        }
        let ownerObject = NSObject(), otherObject = NSObject()
        let owner = ObjectIdentifier(ownerObject), other = ObjectIdentifier(otherObject)
        func request(_ catalog: RemoteDockCatalog, _ action: RemoteDockRequest.Action) -> RemoteDockRequest {
            RemoteDockRequest(version: catalog.version, itemID: 0, action: action)
        }
        func seededReader() -> RemoteDockReader {
            let reader = RemoteDockReader()
            for i in 0..<Fixture.count { reader.icons[Fixture.url(i).absoluteString] = Data(repeating: 255, count: 65536) }
            return reader
        }

        Fixture.reset(); Fixture.privateApp = true
        do {
            let reader = seededReader(), catalog = reader.catalog(force: true)
            check(catalog.items.isEmpty, "비공개 앱은 목록에서 제외됩니다")
            check(reader.perform(request(catalog, .press), owner: owner).note != nil && Fixture.actions.isEmpty,
                  "비공개 앱 액션이 거부됩니다")
        }
        Fixture.reset(); Fixture.unresolved = true
        check(seededReader().catalog(force: true).items.isEmpty, "앱 bundle 미확인 항목은 제외됩니다")
        for action in [RemoteDockRequest.Action.press, .menu] {
            Fixture.reset()
            let reader = seededReader(), catalog = reader.catalog(force: true)
            Fixture.bundleReads = 0; Fixture.privateAtRead = 2
            let reply = reader.perform(request(catalog, action), owner: owner)
            check(reply.note != nil && Fixture.actions.isEmpty,
                  "\(action) 직전 bundle 정책 변경이 차단됩니다")
            Fixture.privateApp = true
            check(reader.applicationBundleID(for: request(catalog, action)) == nil, "부모 전달 bundle도 비공개 정책을 적용합니다")
        }
        Fixture.reset(); Fixture.count = 200
        do {
            let reader = seededReader(), catalog = reader.catalog(force: true)
            let list = WindowList(macName: "fixture", windows: [], active: .none, dock: catalog)
            let reply = reader.perform(request(catalog, .press), owner: owner)
            let bytes = Wire.encode(list).count, replyBytes = Wire.encode(reply).count
            print("목록 \(bytes) bytes, 응답 \(replyBytes) bytes, 한도 \(StreamMessage.maxOtherHostPayload) bytes")
            check(catalog.items.count == 200 && catalog.items.contains(where: { $0.icon != nil }), "200개 Dock 항목과 일부 아이콘이 보존됩니다")
            check(bytes <= StreamMessage.maxOtherHostPayload && replyBytes <= StreamMessage.maxOtherHostPayload,
                  "200개 64KiB 아이콘의 실제 전송 크기가 4MiB 이내입니다")
        }
        Fixture.reset(); Fixture.longTitle = true; Fixture.count = 2
        do {
            let reader = seededReader(), catalog = reader.catalog(force: true)
            check(Wire.encode(catalog).count <= 512 * 1024, "과대한 문자열도 Dock 전송 예산을 넘지 않습니다")
        }
        Fixture.reset()
        do {
            let reader = seededReader(), catalog = reader.catalog(force: true)
            Fixture.menuCount = 80; Fixture.levels = 5; Fixture.menuCost = 0.005
            let start = Fixture.now
            let reply = reader.perform(request(catalog, .menu), owner: owner)
            print("메뉴 가상 경과 \(Fixture.now - start)s, 읽기 \(Fixture.menuReads)회")
            check(Fixture.now - start <= 0.35 && reply.note != nil && reply.menuID == nil,
                  "깊은 메뉴는 전체 deadline에서 실패합니다")
            check(!Fixture.menuOpen, "deadline 실패 메뉴가 정리됩니다")
        }
        Fixture.reset(); Fixture.rootMissing = true
        do {
            let reader = seededReader(), catalog = reader.catalog(force: true)
            let reply = reader.perform(request(catalog, .menu), owner: owner)
            check(reply.note != nil && !Fixture.menuOpen && Fixture.actions.last?.1 == kAXCancelAction as String,
                  "AXShowMenu 성공 후 root 실패 시 tile로 정리합니다")
        }
        Fixture.reset(); Fixture.rootMissing = true; Fixture.failCancel = true
        do {
            let reader = seededReader(), catalog = reader.catalog(force: true)
            _ = reader.perform(request(catalog, .menu), owner: owner)
            let before = Fixture.actions.count
            reader.disconnected(other)
            check(Fixture.actions.count == before, "다른 소유자의 disconnect는 메뉴를 건드리지 않습니다")
            Fixture.failCancel = false
            reader.disconnected(owner)
            check(!Fixture.menuOpen && Fixture.actions.count > before, "정리 실패 책임이 유지되어 owner disconnect에서 재시도합니다")
        }
        Fixture.reset()
        do {
            let reader = seededReader(), catalog = reader.catalog(force: true)
            let reply = reader.perform(request(catalog, .menu), owner: owner)
            check(reply.menu?.count == 1 && reply.menuID != nil, "정상 메뉴가 읽힙니다")
            let choose = RemoteDockRequest(version: catalog.version, itemID: 0, action: .choose,
                menuID: reply.menuID, menuItemID: "0", title: "열기 1001")
            let before = Fixture.actions.count
            check(reader.perform(choose, owner: other).note != nil && Fixture.actions.count == before,
                  "다른 소유자는 메뉴를 선택하거나 닫을 수 없습니다")
            Fixture.failPress = true
            check(reader.perform(choose, owner: owner).note != nil && !Fixture.menuOpen, "메뉴 실행 실패 시 정리합니다")
        }
        Fixture.reset()
        do {
            let reader = seededReader(), catalog = reader.catalog(force: true)
            _ = reader.perform(request(catalog, .menu), owner: owner)
            reader.disconnected(owner)
            let before = Fixture.actions.count
            reader.disconnected(owner)
            check(!Fixture.menuOpen && Fixture.actions.count == before, "정상 disconnect 정리는 멱등적입니다")
        }
        print("실제 AX·앱·기기·오디오·HAL·서비스 호출 없음, 실패 \(failures.count)개")
        if !failures.isEmpty { exit(1) }
    }
}
