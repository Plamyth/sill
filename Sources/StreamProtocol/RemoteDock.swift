import Foundation

public struct RemoteDockItem: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var title: String
    public var subrole: String
    public var running: Bool
    public var icon: Data?

    public init(id: Int, title: String, subrole: String, running: Bool, icon: Data? = nil) {
        self.id = id; self.title = title; self.subrole = subrole
        self.running = running; self.icon = icon
    }

    public var separator: Bool { subrole == "AXSeparatorDockItem" }
}

public struct RemoteDockCatalog: Codable, Hashable, Sendable {
    public var version: UUID
    public var items: [RemoteDockItem]
    public var note: String?

    public init(version: UUID, items: [RemoteDockItem], note: String? = nil) {
        self.version = version; self.items = items; self.note = note
    }
}

public struct RemoteDockMenuItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var enabled: Bool
    public var mark: String?
    public var children: [RemoteDockMenuItem]

    public init(id: String, title: String, enabled: Bool, mark: String? = nil,
                children: [RemoteDockMenuItem] = []) {
        self.id = id; self.title = title; self.enabled = enabled
        self.mark = mark; self.children = children
    }
}

public struct RemoteDockRequest: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable { case press, menu, choose, cancel }
    public var requestID: UUID
    public var version: UUID
    public var itemID: Int
    public var action: Action
    public var menuID: UUID?
    public var menuItemID: String?
    public var title: String?

    public init(requestID: UUID = UUID(), version: UUID, itemID: Int, action: Action,
                menuID: UUID? = nil, menuItemID: String? = nil, title: String? = nil) {
        self.requestID = requestID; self.version = version; self.itemID = itemID
        self.action = action; self.menuID = menuID; self.menuItemID = menuItemID; self.title = title
    }
}

public struct RemoteDockReply: Codable, Sendable {
    public var requestID: UUID
    public var catalog: RemoteDockCatalog
    public var menuID: UUID?
    public var menu: [RemoteDockMenuItem]?
    public var note: String?
    public var selectedSource: StreamSource?
    public var selectionRevision: String?
    public var videoEpochID: UUID?

    public init(requestID: UUID, catalog: RemoteDockCatalog, menuID: UUID? = nil,
                menu: [RemoteDockMenuItem]? = nil, note: String? = nil) {
        self.requestID = requestID; self.catalog = catalog
        self.menuID = menuID; self.menu = menu; self.note = note
    }
}
