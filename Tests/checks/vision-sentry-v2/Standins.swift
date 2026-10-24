import Foundation
import Network
import StreamProtocol

final class StreamClient {
    let queue = DispatchQueue(label: "sentry.v2.inert.net")
    let link = SessionLink()
    var connected = true
    var visionSentryTrusted = true
    var sentryTestIdentity: VisionSentryStoredRequest.Binding?
    var visionSentrySnapshot = VisionSentryController.Snapshot()
    let visionSentry: VisionSentryController
    var visionSentryDeadline: DispatchWorkItem?
    var visionSentryLink: SessionLink { link }
    init(store: VisionSentryRequestStore) { visionSentry = VisionSentryController(store: store) }
    var connection: NWConnection? {
        get { link.connection }
        set { bindVisionSentry(to: newValue); link.connection = newValue }
    }
}
