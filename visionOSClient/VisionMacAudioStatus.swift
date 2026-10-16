import Foundation

struct VisionMacAudioStatus: Codable, Equatable {
    enum Outcome: String, Codable {
        case inactive, awaitingCatalog, ready, waiting, invalidCatalog, localRefusal
        case applied, unchanged, stale, invalid, conflict, unavailable, failed, rollbackFailed
        case unverified, timedOut
    }
    let build: String
    let trustedCurrentPeer: Bool
    let owningWindow: Bool
    let foreground: Bool
    let catalogAvailable: Bool
    let catalogValid: Bool
    let catalogCount: Int
    let currentInputKnown: Bool
    let currentOutputKnown: Bool
    let pending: Bool
    let outcome: Outcome
    let selectionRequestCount: Int
}

final class VisionMacAudioStatusWriter {
    private var previous: VisionMacAudioStatus?

    func write(_ snapshot: VisionMacAudioStatus) {
        guard snapshot != previous else { return }
        #if os(visionOS)
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = documents.appendingPathComponent("CCRMacAudioStatus.json")
        let temporary = documents.appendingPathComponent("CCRMacAudioStatus.json.tmp")
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
            // A later changed state can retry after protected Documents becomes accessible.
        }
        #else
        // Inert Foundation fixtures never write the user's Documents directory.
        previous = snapshot
        #endif
    }
}
