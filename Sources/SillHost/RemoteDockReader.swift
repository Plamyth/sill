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
        let tile: AXUIElement
        var root: AXUIElement?
        var elements: [String: AXUIElement]
        let created: TimeInterval
    }

    private var tiles: [Tile] = []
    private var current = RemoteDockCatalog(version: UUID(), items: [])
    private var checkedAt: TimeInterval = -.infinity
    private var menuSession: MenuSession?
    private var icons: [String: Data] = [:]
    private var pendingIcons: Set<String> = []
    private var deadline: TimeInterval = -.infinity
    private var readDeadline: TimeInterval = -.infinity
    private var readFailed = false

    func catalog(force: Bool = false) -> RemoteDockCatalog {
        deadline = ProcessInfo.processInfo.systemUptime + 0.2
        readDeadline = deadline - 0.04
        readFailed = false
        return readCatalog(force: force)
    }

    private func readCatalog(force: Bool) -> RemoteDockCatalog {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - checkedAt >= 1 else { return current }
        checkedAt = now
        guard ProcessInfo.processInfo.systemUptime < readDeadline, AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              ProcessInfo.processInfo.systemUptime < readDeadline else {
            return unavailable("Mac Dock을 읽을 수 없습니다. Mac의 기존 접근성 권한을 확인하세요.")
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let list = children(app).first(where: { string($0, kAXRoleAttribute) == kAXListRole as String }),
              let source = value(list, kAXChildrenAttribute) as? [AXUIElement], source.count <= 200 else {
            return unavailable("Mac Dock 목록을 읽지 못했습니다.")
        }
        var next: [Tile] = []
        var iconBytes = 128 * 1024
        for (index, element) in source.enumerated() {
            guard ProcessInfo.processInfo.systemUptime < readDeadline else {
                return unavailable("Mac Dock 응답을 기다리는 중입니다.")
            }
            guard string(element, kAXRoleAttribute) == "AXDockItem" else { continue }
            let title = string(element, kAXTitleAttribute) ?? ""
            guard let subrole = string(element, kAXSubroleAttribute) else { continue }
            let url = value(element, kAXURLAttribute) as? URL
            guard allowed(url: url, subrole: subrole) else { continue }
            let running = (value(element, "AXIsApplicationRunning") as? NSNumber)?.boolValue ?? false
            let identity = "\(dock.processIdentifier)|\(index)|\(subrole)|\(title)|\(url?.absoluteString ?? "")"
            let data = icon(url: url, subrole: subrole).flatMap { data -> Data? in
                guard data.count <= 65536, data.count <= iconBytes else { return nil }
                iconBytes -= data.count
                return data
            }
            let item = RemoteDockItem(id: index, title: title, subrole: subrole, running: running,
                                      icon: data)
            next.append(Tile(element: element, identity: identity, item: item))
        }
        let candidate = RemoteDockCatalog(version: current.version, items: next.map(\.item))
        guard !readFailed, Wire.encode(candidate).count <= 512 * 1024,
              ProcessInfo.processInfo.systemUptime < readDeadline else {
            return unavailable("Mac Dock 목록의 읽기 또는 전송 예산을 초과했습니다.")
        }
        if next.map(\.identity) != tiles.map(\.identity) || next.map(\.item) != current.items || current.note != nil {
            current = RemoteDockCatalog(version: UUID(), items: next.map(\.item))
        }
        tiles = next
        return current
    }

    func perform(_ request: RemoteDockRequest, owner: ObjectIdentifier,
                 actionAdmission: ((() -> AXError) -> AXError) = { $0() }) -> RemoteDockReply {
        deadline = ProcessInfo.processInfo.systemUptime + 0.3
        readDeadline = deadline - 0.04
        readFailed = false
        func reply(_ note: String? = nil, id: UUID? = nil,
                   items: [RemoteDockMenuItem]? = nil) -> RemoteDockReply {
            if note != nil, menuSession?.owner == owner { _ = dismissMenu() }
            let response = RemoteDockReply(requestID: request.requestID, catalog: current, menuID: id, menu: items, note: note)
            guard Wire.encode(response).count <= 1024 * 1024 else {
                if menuSession?.owner == owner { _ = dismissMenu() }
                return RemoteDockReply(requestID: request.requestID, catalog: current,
                                       note: "Mac Dock 메뉴의 전송 예산을 초과했습니다. 다시 열어 주세요.")
            }
            return response
        }
        if request.action == .cancel {
            if let session = menuSession, session.owner == owner,
               request.menuID == nil || request.menuID == session.id {
                guard dismissMenu() else { return reply("Mac Dock 메뉴를 닫지 못했습니다. 다시 시도해 주세요.") }
            }
            return reply()
        }
        if let session = menuSession, ProcessInfo.processInfo.systemUptime - session.created >= 30 {
            guard dismissMenu() else { return reply("Mac Dock 메뉴를 닫지 못했습니다. 다시 시도해 주세요.") }
        }
        _ = readCatalog(force: true)
        if let session = menuSession, session.owner != owner {
            return reply("다른 기기에서 Dock 메뉴를 사용 중입니다.")
        }
        guard current.note == nil, request.version == current.version,
              let tile = tiles.first(where: { $0.item.id == request.itemID }) else {
            return reply("Dock 내용이 바뀌었습니다. 최신 항목에서 다시 선택하세요.")
        }
        switch request.action {
        case .press:
            guard dismissMenu(), allowed(tile.element),
                  action(tile.element, kAXPressAction, actionAdmission: actionAdmission) == .success else {
                return reply("Mac Dock에서 항목을 열지 못했습니다.")
            }
            return reply()
        case .menu:
            guard dismissMenu(), allowed(tile.element) else {
                return reply("이 Dock 항목의 메뉴를 읽지 못했습니다.")
            }
            let id = UUID()
            let session = MenuSession(id: id, owner: owner, version: current.version, tileID: request.itemID,
                                      tile: tile.element, root: nil, elements: [:],
                                      created: ProcessInfo.processInfo.systemUptime)
            guard action(tile.element, kAXShowMenuAction, actionAdmission: actionAdmission, openingMenu: session) == .success else {
                return reply("이 Dock 항목의 메뉴를 읽지 못했습니다.")
            }
            guard let root = children(tile.element).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole as String }) else {
                return reply("이 Dock 항목의 메뉴를 읽지 못했습니다.")
            }
            menuSession?.root = root
            var elements: [String: AXUIElement] = [:]
            var remaining = 300
            guard let items = menu(root, prefix: "", depth: 0, remaining: &remaining, elements: &elements),
                  ProcessInfo.processInfo.systemUptime < readDeadline else {
                return reply("Mac Dock 메뉴의 읽기 시간을 초과했습니다. 다시 열어 주세요.")
            }
            menuSession?.elements = elements
            return reply(id: id, items: items)
        case .choose:
            guard let session = menuSession, session.owner == owner, session.version == request.version,
                  session.tileID == request.itemID, session.id == request.menuID,
                  ProcessInfo.processInfo.systemUptime - session.created < 30,
                  let id = request.menuItemID, let element = session.elements[id], let title = request.title,
                  string(element, kAXTitleAttribute) == title,
                  (value(element, kAXEnabledAttribute) as? NSNumber)?.boolValue == true else {
                return reply("Dock 메뉴가 바뀌었습니다. 다시 열어 주세요.")
            }
            guard allowed(tile.element), action(element, kAXPressAction, actionAdmission: actionAdmission) == .success else {
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
        deadline = ProcessInfo.processInfo.systemUptime + 0.04
        _ = dismissMenu()
    }

    func applicationBundleID(for request: RemoteDockRequest) -> String? {
        deadline = ProcessInfo.processInfo.systemUptime + 0.03
        readDeadline = deadline
        readFailed = false
        guard request.version == current.version,
              let tile = tiles.first(where: { $0.item.id == request.itemID }),
              tile.item.subrole == "AXApplicationDockItem",
              let url = value(tile.element, kAXURLAttribute) as? URL, url.isFileURL,
              url.absoluteString.utf8.count <= 4096 else { return nil }
        guard let id = Bundle(url: url)?.bundleIdentifier, !WindowCatalog.isPrivateApplication(id),
              ProcessInfo.processInfo.systemUptime < readDeadline else { return nil }
        return id
    }

    private func unavailable(_ note: String) -> RemoteDockCatalog {
        _ = dismissMenu()
        if current.note != note || !current.items.isEmpty {
            current = RemoteDockCatalog(version: UUID(), items: [], note: note)
        }
        tiles = []
        return current
    }

    private func value(_ element: AXUIElement, _ name: String) -> Any? {
        let remaining = readDeadline - ProcessInfo.processInfo.systemUptime
        guard !readFailed, remaining > 0,
              AXUIElementSetMessagingTimeout(element, Float(min(0.01, remaining))) == .success,
              ProcessInfo.processInfo.systemUptime < readDeadline else {
            readFailed = true
            return nil
        }
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
        guard error == .success else {
            if error != .noValue && error != .attributeUnsupported { readFailed = true }
            return nil
        }
        guard ProcessInfo.processInfo.systemUptime < readDeadline else {
            readFailed = true
            return nil
        }
        return result
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let text = value(element, name) as? String, text.utf8.count <= 512 else { return nil }
        return text
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let items = value(element, kAXChildrenAttribute) as? [AXUIElement], items.count <= 300 else { return [] }
        return items
    }

    private func allowed(url: URL?, subrole: String) -> Bool {
        guard !readFailed else { return false }
        if let url {
            guard url.absoluteString.utf8.count <= 4096 else { return false }
            if url.isFileURL, let id = Bundle(url: url)?.bundleIdentifier {
                return !WindowCatalog.isPrivateApplication(id) && ProcessInfo.processInfo.systemUptime < readDeadline
            }
        }
        return subrole != "AXApplicationDockItem" && url?.pathExtension.lowercased() != "app"
            && ProcessInfo.processInfo.systemUptime < readDeadline
    }

    private func allowed(_ element: AXUIElement) -> Bool {
        guard let subrole = string(element, kAXSubroleAttribute) else { return false }
        let url = value(element, kAXURLAttribute) as? URL
        return allowed(url: url, subrole: subrole)
    }

    private func action(_ element: AXUIElement, _ name: String,
                        actionAdmission: ((() -> AXError) -> AXError), openingMenu: MenuSession? = nil) -> AXError {
        let remaining = readDeadline - ProcessInfo.processInfo.systemUptime
        guard !readFailed, remaining > 0,
              AXUIElementSetMessagingTimeout(element, Float(min(0.01, remaining))) == .success,
              ProcessInfo.processInfo.systemUptime < readDeadline else { return .cannotComplete }
        return actionAdmission {
            guard ProcessInfo.processInfo.systemUptime < readDeadline else { return .cannotComplete }
            if let openingMenu { menuSession = openingMenu }
            return AXUIElementPerformAction(element, name as CFString)
        }
    }

    private func dismissMenu() -> Bool {
        guard let session = menuSession else { return true }
        for element in [session.root, session.tile].compactMap({ $0 }) {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            guard AXUIElementSetMessagingTimeout(element, Float(min(0.01, remaining))) == .success,
                  ProcessInfo.processInfo.systemUptime < deadline else { continue }
            if AXUIElementPerformAction(element, kAXCancelAction as CFString) == .success {
                menuSession = nil
                return true
            }
        }
        return false
    }

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
                      elements: inout [String: AXUIElement]) -> [RemoteDockMenuItem]? {
        guard !readFailed, ProcessInfo.processInfo.systemUptime < readDeadline else { return nil }
        guard depth < 5 else { return [] }
        guard let source = value(root, kAXChildrenAttribute) as? [AXUIElement], source.count <= 300 else { return nil }
        var result: [RemoteDockMenuItem] = []
        for (index, element) in source.enumerated() {
            guard !readFailed, ProcessInfo.processInfo.systemUptime < readDeadline else { return nil }
            guard remaining > 0 else { break }
            remaining -= 1
            let id = prefix.isEmpty ? "\(index)" : "\(prefix).\(index)"
            let title = string(element, kAXTitleAttribute) ?? ""
            let enabled = (value(element, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? false
            elements[id] = element
            var nested: [RemoteDockMenuItem] = []
            if let child = children(element).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole as String }) {
                guard let items = menu(child, prefix: id, depth: depth + 1, remaining: &remaining, elements: &elements) else { return nil }
                nested = items
            }
            result.append(RemoteDockMenuItem(id: id, title: title, enabled: enabled,
                                             mark: string(element, "AXMenuItemMarkChar"), children: nested))
        }
        return !readFailed && ProcessInfo.processInfo.systemUptime < readDeadline ? result : nil
    }
}
