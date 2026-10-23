import Foundation
import Darwin

@MainActor func socketChecks(_ check: (String, Bool) -> Void) async {
    for (path, deadline) in [("relative", ProcessInfo.processInfo.systemUptime + 1),
        ("/tmp/../tmp/fixture", ProcessInfo.processInfo.systemUptime + 1),
        ("/tmp/fixture", Double.nan), ("/tmp/fixture", ProcessInfo.processInfo.systemUptime - 1)] {
        do { let socket = try await ProviderCallSocket.open(path: path, until: deadline)
            socket.invalidate(); check("actual socket rejects path/deadline", false)
        } catch { check("actual socket rejects path/deadline", true) }
    }
    var descriptors: [Int32] = [-1, -1]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    defer { descriptors.forEach { Darwin.close($0) } }
    do { _ = try ProviderPeerAnchor.verify(descriptors[0], policy: .core)
        check("ad hoc signed inert peer cannot attest installed Core", false)
    } catch { check("ad hoc signed inert peer cannot attest installed Core", true) }
    do { _ = try ProviderPeerAnchor.verify(-1, policy: .installed)
        check("invalid fd cannot attest installed Sill", false)
    } catch { check("invalid fd cannot attest installed Sill", true) }
    check("Recovery exact path differs from active canonical app", ProviderCallRecovery.application != LocalAudioRelayLaunch.canonicalApp)
    check("unstaged actual Recovery fails closed", !(await ProviderCallRecovery.ready()))
}
