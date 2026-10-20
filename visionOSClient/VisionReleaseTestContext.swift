import SwiftUI

enum VisionReleaseTestContext {
    static let bundleID = "dev.ambrion.SillVision.ReleaseTest"
    static var isTestBundle: Bool { Bundle.main.bundleIdentifier == bundleID }

    struct Context: Codable {
        let commit: String
        let tree: String
        let runID: String
    }

    static let current: Context? = {
        #if DEBUG && targetEnvironment(simulator)
        let args = CommandLine.arguments
        guard isTestBundle, let index = args.firstIndex(of: "--ccr-release-context"),
              index + 1 < args.count, let data = args[index + 1].data(using: .utf8),
              let value = try? JSONDecoder().decode(Context.self, from: data),
              value.commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              value.tree.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              UUID(uuidString: value.runID) != nil,
              Bundle.main.object(forInfoDictionaryKey: "BTSourceCommit") as? String == value.commit,
              Bundle.main.object(forInfoDictionaryKey: "BTSourceTree") as? String == value.tree else { return nil }
        return value
        #else
        return nil
        #endif
    }()
}

#if DEBUG && targetEnvironment(simulator)
final class VisionReleaseFixture: ObservableObject {
    static let current = VisionReleaseTestContext.current.map(VisionReleaseFixture.init)
    @Published private(set) var displayedText = "시뮬레이터의 결정적 Mac 입력 대상입니다."
    private let context: VisionReleaseTestContext.Context
    private let directory: URL
    private var events: [String] = []
    private var requests: Set<UUID> = []

    private init(context: VisionReleaseTestContext.Context) {
        self.context = context
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCRReleaseFixture", isDirectory: true)
    }

    func submit(_ text: String, request: UUID, isolated: Bool) -> Bool {
        guard isolated, VisionDraftText.accepts(text), requests.insert(request).inserted else { return false }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("draft.json")
            try JSONEncoder().encode(["text": text, "providerMode": "deterministic-stub"])
                .write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            events.append("written")
            let stored = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
            guard let observed = stored["text"], observed == text,
                  stored["providerMode"] == "deterministic-stub" else { return false }
            displayedText = observed
            events.append("read-verified")
            try record(isolated: isolated, absent: false)
            return true
        } catch { return false }
    }

    func reset(isolated: Bool) -> Bool {
        guard isolated else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("draft.json")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            guard !FileManager.default.fileExists(atPath: file.path) else { return false }
            displayedText = "시뮬레이터 입력 대상을 초기화했습니다."
            events.append("reset-verified")
            try record(isolated: isolated, absent: true)
            return true
        } catch { return false }
    }

    private func record(isolated: Bool, absent: Bool) throws {
        VisionReleaseRuntimeWriter.write()
        let runtimeURL = directory.deletingLastPathComponent().appendingPathComponent("CCRReleaseRuntime.json")
        let runtime = try JSONSerialization.jsonObject(with: Data(contentsOf: runtimeURL)) as? [String: Any]
        guard let boot = runtime?["bootUUID"] as? String else { throw Failure.invalid }
        let receipt: [String: Any] = ["schema": "ccr.vision.simulator-fixture/v1",
            "commit": context.commit, "tree": context.tree, "runID": context.runID,
            "bootUUID": boot, "bundleId": VisionReleaseTestContext.bundleID,
            "storageIdentity": directory.path, "providerMode": "deterministic-stub",
            "externalEffects": "zero", "sessionIsolated": isolated, "events": events,
            "fixtureAbsent": absent]
        try JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys)
            .write(to: directory.appendingPathComponent("receipt.json"), options: .atomic)
    }

    private enum Failure: Error { case invalid }
}

struct VisionReleaseProviderDisplay: View {
    @ObservedObject var provider: VisionReleaseFixture
    var body: some View {
        VStack {
            Text("시뮬레이터 · 결정적 테스트 Mac · 실제 원격 연결 아님")
            Text(provider.displayedText).accessibilityIdentifier("release.provider-output")
        }.padding().background(.black)
    }
}
#endif
