import Foundation

struct VisionAutoConnectStatus: Codable, Equatable {
    enum StartupMode: String, Codable { case coldLaunch, cableBootstrap, invalidBootstrap }
    enum Phase: String, Codable {
        case waiting, bootstrapDialing, bootstrapAsking, paired, connecting, connected, stopped
    }

    let schema = 1
    let build: String
    let startupMode: StartupMode
    let phase: Phase
    let savedMacCount: Int
    let expectedMacMatched: Bool
    let connected: Bool
    let catalogReceived: Bool
    let presentationReady: Bool
    let inputReady: Bool
    let reasonFixed: VisionCableBootstrapReason?
}

final class VisionAutoConnectStatusWriter {
    private var previous: VisionAutoConnectStatus?
    private let filename: String

    init(identifier: UUID? = nil) {
        filename = identifier.map { "CCRAutoConnectStatus-\($0.uuidString).json" } ?? "CCRAutoConnectStatus.json"
    }

    func write(_ snapshot: VisionAutoConnectStatus) {
        guard snapshot != previous,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = documents.appendingPathComponent(filename)
        let temporary = documents.appendingPathComponent(filename + ".tmp")
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: temporary.path) { try manager.removeItem(at: temporary) }
            guard manager.createFile(atPath: temporary.path, contents: data,
                                     attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]) else { return }
            var privateURL = temporary
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try privateURL.setResourceValues(values)
            if manager.fileExists(atPath: url.path) { _ = try manager.replaceItemAt(url, withItemAt: temporary) }
            else { try manager.moveItem(at: temporary, to: url) }
            previous = snapshot
        } catch {
            // A locked device may deny protected Documents I/O. A later state event can retry.
        }
    }
}
