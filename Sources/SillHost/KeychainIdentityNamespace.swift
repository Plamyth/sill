import Foundation

/// A separately packaged CCR host must not read or create the original Sill identity items.
/// The stock bundle keeps its historic names; other bundle IDs get their own names.
package struct KeychainIdentityNamespace: Equatable {
    package let keyTag: Data
    package let service: String
    package let label: String

    package static func forBundleIdentifier(_ bundleIdentifier: String?) -> Self {
        let original = bundleIdentifier == nil || bundleIdentifier == "me.saffer.sill.mac" || bundleIdentifier?.isEmpty == true
        let root: String
        if let bundleIdentifier, !bundleIdentifier.isEmpty, !original {
            root = "\(bundleIdentifier).remote"
        } else {
            root = "me.saffer.sill.remote"
        }
        return Self(keyTag: Data("\(root).host-key".utf8), service: root,
                    label: original ? "Sill Remote Access" : "CCR Sill Remote Access")
    }
}
