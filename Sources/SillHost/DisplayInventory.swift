import Foundation
import StreamProtocol

struct DisplayInventory {
    private(set) var infos: [DisplayInfo] = []
    private(set) var revision: UUID?
    private(set) var selectedID: UInt32?
    private(set) var requiresSelection = false
    private var signatures: [String] = []

    mutating func invalidate() {
        revision = nil
        selectedID = nil
        requiresSelection = true
    }

    @discardableResult
    mutating func update(_ infos: [DisplayInfo], signatures: [String]) -> Bool {
        guard revision == nil || self.infos != infos || self.signatures != signatures else { return false }
        if revision != nil { invalidate() }
        self.infos = infos
        self.signatures = signatures
        revision = UUID()
        return true
    }

    var current: DisplaySelection? {
        guard let revision, !requiresSelection,
              let id = selectedID ?? infos.first(where: \.isMain)?.id ?? infos.first?.id else { return nil }
        return DisplaySelection(displayID: id, inventoryID: revision)
    }

    func contains(_ selection: DisplaySelection) -> Bool {
        selection.inventoryID == revision && infos.contains { $0.id == selection.displayID }
    }

    @discardableResult
    mutating func select(_ selection: DisplaySelection) -> Bool {
        guard contains(selection) else { return false }
        selectedID = selection.displayID
        requiresSelection = false
        return true
    }

    func identity(of displayID: UInt32) -> String? {
        guard revision != nil, let index = infos.firstIndex(where: { $0.id == displayID }),
              signatures.indices.contains(index),
              let physical = signatures[index].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first,
              !physical.isEmpty else { return nil }
        return "\(displayID)/\(physical)"
    }

    static func scope(_ selection: DisplaySelection?) -> String? {
        selection.map { "\($0.inventoryID.uuidString)/\($0.displayID)" }
    }
}
