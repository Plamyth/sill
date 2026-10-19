import Foundation
import Network
import StreamProtocol

final class StreamClient {
    let queue = DispatchQueue(label: "sentry.inert.net")
    let link = SessionLink()
    var connected = true
    var visionSentryTrusted = true
    var connection: NWConnection? {
        get { link.connection }
        set { bindVisionSentry(to: newValue); link.connection = newValue }
    }
    // PRODUCTION_SENTRY_STORAGE
}
