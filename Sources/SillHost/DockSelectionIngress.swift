import Foundation
import StreamProtocol

final class DockSelectionIngress: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UInt64 = 0
    private var latestPeer: ObjectIdentifier?
    private var peers: [ObjectIdentifier: Bool] = [:]
    private var dockVersion: UUID?
    private var dockItems: Set<Int> = []
    private var windows: Set<UInt32> = []
    private var displayInventory: UUID?
    private var displays: Set<UInt32> = []
    private var apps: Set<String> = []
    private struct Menu {
        let id: UUID
        let item: Int
        let version: UUID
        let choices: [String: String]
    }
    private var menus: [ObjectIdentifier: Menu] = [:]

    func setPeer(_ peer: ObjectIdentifier, dockAllowed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        peers[peer] = dockAllowed
    }

    func removePeer(_ peer: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        peers[peer] = nil
        menus[peer] = nil
    }

    func recordMenu(for peer: ObjectIdentifier, request: RemoteDockRequest, reply: RemoteDockReply) {
        lock.lock()
        defer { lock.unlock() }
        menus[peer] = nil
        guard request.action == .menu, reply.note == nil, let id = reply.menuID, let items = reply.menu else { return }
        var choices: [String: String] = [:]
        func collect(_ items: [RemoteDockMenuItem]) {
            for item in items {
                if item.enabled { choices[item.id] = item.title }
                collect(item.children)
            }
        }
        collect(items)
        menus[peer] = Menu(id: id, item: request.itemID, version: reply.catalog.version, choices: choices)
    }

    func discardMenu(for peer: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        menus[peer] = nil
    }

    func publish(dock: RemoteDockCatalog?, windowIDs: [UInt32], displayInventoryID: UUID?,
                 displayIDs: [UInt32], appBundleIDs: [String]) {
        lock.lock()
        defer { lock.unlock() }
        dockVersion = dock?.note == nil ? dock?.version : nil
        dockItems = Set(dock?.items.map(\.id) ?? [])
        windows = Set(windowIDs)
        displayInventory = displayInventoryID
        displays = Set(displayIDs)
        apps = Set(appBundleIDs)
    }

    func reserve(for message: StreamMessage, from peer: ObjectIdentifier) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let dockAllowed = peers[peer], message.payload.count <= 4096 else { return nil }
        switch message.kind {
        case .dockRequest:
            guard dockAllowed, message.payload.count <= StreamMessage.clientPayloadLimit(for: .dockRequest),
                  let request = Wire.decode(RemoteDockRequest.self, from: message.payload),
                  request.action == .press || request.action == .choose,
                  request.version == dockVersion, dockItems.contains(request.itemID) else { return nil }
            if request.action == .choose {
                guard let menu = menus[peer], menu.id == request.menuID, menu.item == request.itemID,
                      menu.version == request.version,
                      let item = request.menuItemID, menu.choices[item] == request.title,
                      request.title != nil else { return nil }
            }
        case .selectSource:
            guard let source = Wire.decode(StreamSource.self, from: message.payload) else { return nil }
            if case .window(let id) = source, !windows.contains(id) { return nil }
        case .selectDisplay:
            guard let selection = Wire.decode(DisplaySelection.self, from: message.payload),
                  selection.inventoryID == displayInventory, displays.contains(selection.displayID) else { return nil }
        case .launchApp:
            guard let request = Wire.decode(LaunchApp.self, from: message.payload), apps.contains(request.bundleID) else { return nil }
        default: return nil
        }
        guard latest < .max else { return nil }
        latest += 1
        latestPeer = peer
        return latest
    }

    func isCurrent(_ ticket: UInt64?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ticket != nil && ticket == latest && latestPeer.flatMap { peers[$0] } != nil
    }

    func performIfCurrent<Result>(_ ticket: UInt64?, refused: Result, _ action: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard ticket != nil, ticket == latest, latestPeer.flatMap({ peers[$0] }) != nil else { return refused }
        return action()
    }
}
