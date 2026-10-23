import Foundation
import Security

enum ProviderCallRecovery {
    static let application = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CCR Sill/Recovery/CCR Sill.app", isDirectory: true)

    static func ready() async -> Bool {
        await Task.detached(priority: .utility) {
            do {
                let url = application.standardizedFileURL
                guard url == url.resolvingSymlinksInPath(), url != LocalAudioRelayLaunch.canonicalApp,
                      let bundle = Bundle(url: url), bundle.bundleIdentifier == "com.ambrion.sillcanvas.mac" else { return false }
                var requirement: SecRequirement?
                var code: SecStaticCode?
                guard SecRequirementCreateWithString(LocalAudioRelayLaunch.designatedRequirement as CFString, [], &requirement) == errSecSuccess,
                      let requirement, SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                      let code else { return false }
                let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
                guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { return false }
                let inventory = try LocalAudioRelayInventory.capture(package: url.appendingPathComponent("Contents/Resources/LocalAudioRelay"))
                try LocalAudioRelayClosure.validate(inventory)
                try inventory.recheck()
                return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
            } catch { return false }
        }.value
    }
}
