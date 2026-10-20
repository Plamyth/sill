import AppKit
import ApplicationServices
import StreamProtocol

@MainActor
final class RemoteDockReader {
    private struct Tile {
        let element: AXUIElement
        let identity: String
        let item: RemoteDockItem
    }
    private struct MenuSession {
        let id: UUID
        let owner: ObjectIdentifier
        let version: UUID
        let tileID: Int
        let root: AXUIElement
        let elements: [String: AXUIElement]
        let created: TimeInterval
    }

    private var tiles: [Tile] = []
    private var current = RemoteDockCatalog(version: UUID(), items: [])
    private var checkedAt: TimeInterval = -.infinity
    private var menuSession: MenuSession?
    private var icons: [String: Data] = [:]
    private var pendingIcons: Set<String> = []

    func catalog(force: Bool = false) -> RemoteDockCatalog {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - checkedAt >= 1 else { return current }
        checkedAt = now
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return unavailable("Mac Dock을 읽을 수 없습니다. Mac의 기존 접근성 권한을 확인하세요.")
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let list = children(app).first(where: { string($0, kAXRoleAttribute) == kAXListRole as String }),
              let source = value(list, kAXChildrenAttribute) as? [AXUIElement], source.count <= 200 else {
            return unavailable("Mac Dock 목록을 읽지 못했습니다.")
        }
        var next: [Tile] = []
        for (index, element) in source.enumerated() {
            guard ProcessInfo.processInfo.systemUptime - now < 0.4 else {
                return unavailable("Mac Dock 응답을 기다리는 중입니다.")
            }
            guard string(element, kAXRoleAttribute) == "AXDockItem" else { continue }
            let title = string(element, kAXTitleAttribute) ?? ""
            let subrole = string(element, kAXSubroleAttribute) ?? "AXDockItem"
            let url = value(element, kAXURLAttribute) as? URL
            let running = (value(element, "AXIsApplicationRunning") as? NSNumber)?.boolValue ?? false
            let identity = "\(dock.processIdentifier)|\(index)|\(subrole)|\(title)|\(url?.absoluteString ?? "")"
            let item = RemoteDockItem(id: index, title: title, subrole: subrole, running: running,
                                      icon: icon(url: url, subrole: subrole))
            next.append(Tile(element: element, identity: identity, item: item))
        }
        if next.map(\.identity) != tiles.map(\.identity) || next.map(\.item) != current.items || current.note != nil {
            current = RemoteDockCatalog(version: UUID(), items: next.map(\.item))
        }
        tiles = next
        return current
    }

    func perform(_ request: RemoteDockRequest, owner: ObjectIdentifier) -> RemoteDockReply {
        func reply(_ note: String? = nil, id: UUID? = nil,
                   items: [RemoteDockMenuItem]? = nil) -> RemoteDockReply {
            RemoteDockReply(requestID: request.requestID, catalog: current, menuID: id, menu: items, note: note)
        }
        if request.action == .cancel {
            if let session = menuSession, session.owner == owner,
               request.menuID == nil || request.menuID == session.id {
                _ = AXUIElementPerformAction(session.root, kAXCancelAction as CFString)
                menuSession = nil
            }
            return reply()
        }
        _ = catalog(force: true)
        if let session = menuSession, ProcessInfo.processInfo.systemUptime - session.created >= 30 {
            _ = AXUIElementPerformAction(session.root, kAXCancelAction as CFString)
            menuSession = nil
        }
        if let session = menuSession, session.owner != owner {
            return reply("다른 기기에서 Dock 메뉴를 사용 중입니다.")
        }
        guard current.note == nil, request.version == current.version,
              let tile = tiles.first(where: { $0.item.id == request.itemID }) else {
            return reply("Dock 내용이 바뀌었습니다. 최신 항목에서 다시 선택하세요.")
        }
        switch request.action {
        case .press:
            guard AXUIElementPerformAction(tile.element, kAXPressAction as CFString) == .success else {
                return reply("Mac Dock에서 항목을 열지 못했습니다.")
            }
            menuSession = nil
            return reply()
        case .menu:
            if let session = menuSession {
                guard session.owner == owner else { return reply("다른 기기에서 Dock 메뉴를 사용 중입니다.") }
                _ = AXUIElementPerformAction(session.root, kAXCancelAction as CFString)
                menuSession = nil
            }
            guard AXUIElementPerformAction(tile.element, kAXShowMenuAction as CFString) == .success,
                  let root = children(tile.element).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole as String }) else {
                return reply("이 Dock 항목의 메뉴를 읽지 못했습니다.")
            }
            var elements: [String: AXUIElement] = [:]
            var remaining = 300
            let items = menu(root, prefix: "", depth: 0, remaining: &remaining, elements: &elements)
            let id = UUID()
            menuSession = MenuSession(id: id, owner: owner, version: current.version, tileID: request.itemID,
                                      root: root, elements: elements, created: ProcessInfo.processInfo.systemUptime)
            return reply(id: id, items: items)
        case .choose:
            guard let session = menuSession, session.owner == owner, session.version == request.version,
                  session.tileID == request.itemID, session.id == request.menuID,
                  ProcessInfo.processInfo.systemUptime - session.created < 30,
                  let id = request.menuItemID, let element = session.elements[id], let title = request.title,
                  string(element, kAXTitleAttribute) == title,
                  (value(element, kAXEnabledAttribute) as? NSNumber)?.boolValue != false else {
                return reply("Dock 메뉴가 바뀌었습니다. 다시 열어 주세요.")
            }
            guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
                return reply("Mac Dock 메뉴를 실행하지 못했습니다.")
            }
            menuSession = nil
            return reply()
        case .cancel:
            return reply()
        }
    }

    func disconnected(_ owner: ObjectIdentifier) {
        guard let session = menuSession, session.owner == owner else { return }
        _ = AXUIElementPerformAction(session.root, kAXCancelAction as CFString)
        menuSession = nil
    }

    func applicationBundleID(for request: RemoteDockRequest) -> String? {
        guard request.version == current.version,
              let tile = tiles.first(where: { $0.item.id == request.itemID }),
              tile.item.subrole == "AXApplicationDockItem",
              let url = value(tile.element, kAXURLAttribute) as? URL, url.isFileURL else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    private func unavailable(_ note: String) -> RemoteDockCatalog {
        if current.note != note || !current.items.isEmpty {
            current = RemoteDockCatalog(version: UUID(), items: [], note: note)
        }
        tiles = []
        return current
    }

    private func value(_ element: AXUIElement, _ name: String) -> Any? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? { value(element, name) as? String }
    private func children(_ element: AXUIElement) -> [AXUIElement] { value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    private func icon(url: URL?, subrole: String) -> Data? {
        let resolved = url ?? (subrole == "AXTrashDockItem"
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") : nil)
        guard let resolved, resolved.isFileURL else { return nil }
        let key = resolved.absoluteString
        if let data = icons[key] { return data }
        guard pendingIcons.insert(key).inserted else { return nil }
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { Self.renderIcon(resolved) }.value
            guard let self else { return }
            self.pendingIcons.remove(key)
            if let data {
                if self.icons.count >= 200 { self.icons.removeAll() }
                self.icons[key] = data
            }
            self.checkedAt = -.infinity
        }
        return nil
    }

    nonisolated private static func renderIcon(_ url: URL) -> Data? {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 88, pixelsHigh: 88, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)
        guard let bitmap, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 88, height: 88))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count <= 65536 else { return nil }
        return data
    }

    private func menu(_ root: AXUIElement, prefix: String, depth: Int, remaining: inout Int,
                      elements: inout [String: AXUIElement]) -> [RemoteDockMenuItem] {
        guard depth < 5 else { return [] }
        var result: [RemoteDockMenuItem] = []
        for (index, element) in children(root).enumerated() {
            guard remaining > 0 else { break }
            remaining -= 1
            let id = prefix.isEmpty ? "\(index)" : "\(prefix).\(index)"
            let title = string(element, kAXTitleAttribute) ?? ""
            let enabled = (value(element, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? true
            elements[id] = element
            var nested: [RemoteDockMenuItem] = []
            if let child = children(element).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole as String }) {
                nested = menu(child, prefix: id, depth: depth + 1, remaining: &remaining, elements: &elements)
            }
            result.append(RemoteDockMenuItem(id: id, title: title, enabled: enabled,
                                             mark: string(element, "AXMenuItemMarkChar"), children: nested))
        }
        return result
    }
}
