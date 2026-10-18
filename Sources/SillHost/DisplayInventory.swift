import Foundation
import CoreGraphics
import StreamProtocol

struct DisplayInventory {
    private(set) var infos: [DisplayInfo] = []
    private(set) var revision: UUID?
    private(set) var selectedID: UInt32?
    private(set) var requiresSelection = false
    private var signatures: [String] = []
    private var frames: [CGRect] = []
    private var suspendedSelectionID: UInt32?
    var isRefreshingSelection: Bool { suspendedSelectionID != nil }

    mutating func invalidate(preservingDisplay id: UInt32? = nil) {
        let candidate = current?.displayID ?? suspendedSelectionID
        suspendedSelectionID = candidate == id ? candidate : nil
        revision = nil
        selectedID = nil
        requiresSelection = true
    }

    @discardableResult
    mutating func update(_ infos: [DisplayInfo], signatures: [String], frames: [CGRect] = [],
                         preservingDisplay id: UInt32? = nil) -> Bool {
        guard revision == nil || self.infos != infos || self.signatures != signatures || self.frames != frames else { return false }
        let candidate = current?.displayID ?? suspendedSelectionID
        let retained = candidate != nil && candidate == id && self.infos == infos &&
            !signatures.isEmpty && !signatures.contains("") && self.signatures == signatures
        if revision != nil { invalidate() }
        self.infos = infos
        self.signatures = signatures
        self.frames = frames
        revision = UUID()
        suspendedSelectionID = nil
        if retained {
            selectedID = candidate
            requiresSelection = false
        }
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

    static func scope(_ selection: DisplaySelection?) -> String? {
        selection.map { "\($0.inventoryID.uuidString)/\($0.displayID)" }
    }
}
