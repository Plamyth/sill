import Foundation
import StreamProtocol

final class DockSelectionIngress: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UInt64 = 0

    func reserve(for message: StreamMessage) -> UInt64? {
        switch message.kind {
        case .dockRequest:
            guard message.payload.count <= StreamMessage.clientPayloadLimit(for: .dockRequest),
                  let request = Wire.decode(RemoteDockRequest.self, from: message.payload),
                  request.action == .press || request.action == .choose else { return nil }
        case .selectSource:
            guard Wire.decode(StreamSource.self, from: message.payload) != nil else { return nil }
        case .selectDisplay:
            guard Wire.decode(DisplaySelection.self, from: message.payload) != nil else { return nil }
        case .launchApp:
            guard Wire.decode(LaunchApp.self, from: message.payload) != nil else { return nil }
        default: return nil
        }
        lock.lock()
        defer { lock.unlock() }
        guard latest < .max else { return nil }
        latest += 1
        return latest
    }

    func isCurrent(_ ticket: UInt64?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ticket != nil && ticket == latest
    }
}
