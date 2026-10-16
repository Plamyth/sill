import Foundation

@main
enum Check {
    static func main() {
        let original = KeychainIdentityNamespace.forBundleIdentifier("me.saffer.sill.mac")
        let bare = KeychainIdentityNamespace.forBundleIdentifier(nil)
        let fork = KeychainIdentityNamespace.forBundleIdentifier("com.ambrion.sillcanvas.mac")
        precondition(original == bare)
        precondition(original.service == "me.saffer.sill.remote")
        precondition(original.keyTag == Data("me.saffer.sill.remote.host-key".utf8))
        precondition(original.label == "Sill Remote Access")
        precondition(fork.service == "com.ambrion.sillcanvas.mac.remote")
        precondition(fork.keyTag == Data("com.ambrion.sillcanvas.mac.remote.host-key".utf8))
        precondition(fork.service != original.service && fork.keyTag != original.keyTag)
        print("ccr-host-identity: original namespace preserved; fork namespace isolated")
    }
}
