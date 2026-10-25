import Foundation

@main struct InkUndoCheck {
    @MainActor static func main() async throws {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/"))
#if os(macOS)
        precondition(FileManager.default.homeDirectoryForCurrentUser.path == home)
#endif
        print("ISOLATION support=\(support.path)")
        _ = try await InkUndoChecks.run(isolatedSupport: support)
    }
}
