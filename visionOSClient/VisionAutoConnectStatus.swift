import Foundation
import CryptoKit

enum VisionReleaseRuntimeWriter {
    private static let foundation: Runtime? = {
        let bundle = Bundle.main
        guard let commit = bundle.object(forInfoDictionaryKey: "BTSourceCommit") as? String,
              let tree = bundle.object(forInfoDictionaryKey: "BTSourceTree") as? String,
              let bundleId = bundle.bundleIdentifier,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let executable = bundle.executableURL,
              let executableSHA256 = hash(executable),
              let infoPlistSHA256 = hash(bundle.bundleURL.appendingPathComponent("Info.plist")),
              let codeResourcesSHA256 = hash(bundle.bundleURL.appendingPathComponent("_CodeSignature/CodeResources")) else { return nil }
        return Runtime(commit: commit, tree: tree, bundleId: bundleId, build: build,
                       pid: ProcessInfo.processInfo.processIdentifier, bootUUID: UUID().uuidString.lowercased(),
                       observedAt: "", executableSHA256: executableSHA256,
                       infoPlistSHA256: infoPlistSHA256, codeResourcesSHA256: codeResourcesSHA256)
    }()
    private static var lastWrittenAt: String?

    static func write() {
        guard var snapshot = foundation,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        snapshot.observedAt = ISO8601DateFormatter().string(from: Date())
        guard snapshot.observedAt != lastWrittenAt else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        if VisionAutoConnectStatusWriter.writeProtected(data, filename: "CCRReleaseRuntime.json", documents: documents) {
            lastWrittenAt = snapshot.observedAt
        }
    }

    private static func hash(_ url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        var hash = SHA256()
        do {
            while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        } catch { return nil }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Runtime: Encodable {
        let schema = "ccr.vision.runtime/v1"
        let commit: String
        let tree: String
        let bundleId: String
        let build: String
        let pid: Int32
        let bootUUID: String
        var observedAt: String
        let executableSHA256: String
        let infoPlistSHA256: String
        let codeResourcesSHA256: String
    }
}

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
        VisionReleaseRuntimeWriter.write()
        guard snapshot != previous,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        if Self.writeProtected(data, filename: filename, documents: documents) { previous = snapshot }
    }

    @discardableResult
    fileprivate static func writeProtected(_ data: Data, filename: String, documents: URL) -> Bool {
        let url = documents.appendingPathComponent(filename)
        let temporary = documents.appendingPathComponent(filename + ".tmp")
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: temporary.path) { try manager.removeItem(at: temporary) }
            guard manager.createFile(atPath: temporary.path, contents: data,
                                     attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]) else { return false }
            var privateURL = temporary
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try privateURL.setResourceValues(values)
            if manager.fileExists(atPath: url.path) { _ = try manager.replaceItemAt(url, withItemAt: temporary) }
            else { try manager.moveItem(at: temporary, to: url) }
            return true
        } catch {
            // A locked device may deny protected Documents I/O. A later state event can retry.
        }
        return false
    }
}
