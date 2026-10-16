import Foundation

public struct MicrophoneScope: Codable, Equatable, Hashable {
    public let peer: UUID
    public let source: StreamSource
    public let inputGeneration: UUID
    public let videoEpoch: UUID
    public let destination: UUID
    public let capability: UUID

    public init(peer: UUID, source: StreamSource, inputGeneration: UUID, videoEpoch: UUID,
                destination: UUID, capability: UUID) {
        self.peer = peer; self.source = source; self.inputGeneration = inputGeneration
        self.videoEpoch = videoEpoch; self.destination = destination; self.capability = capability
    }
}

public struct MicrophoneControl: Codable, Equatable {
    public enum Operation: String, Codable { case start, stop, receipt }
    public let operation: Operation
    public let requestID: UUID
    public let scope: MicrophoneScope
    public let grantID: UUID?

    public init(operation: Operation, requestID: UUID, scope: MicrophoneScope, grantID: UUID? = nil) {
        self.operation = operation; self.requestID = requestID; self.scope = scope; self.grantID = grantID
    }

    public static func decode(_ data: Data) -> Self? {
        guard data.count <= MicrophoneWire.controlLimit,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.scope.source != .none,
              (value.operation == .start ? value.grantID == nil : value.operation == .stop || value.grantID != nil) else { return nil }
        return value
    }
}

public struct MicrophoneState: Codable, Equatable {
    public enum Phase: String, Codable { case off, preparing, active, retiring, cleanupFailed, refused }
    public let requestID: UUID
    public let scope: MicrophoneScope
    public let phase: Phase
    public let grantID: UUID?
    public let reason: String?

    public init(requestID: UUID, scope: MicrophoneScope, phase: Phase, grantID: UUID?, reason: String? = nil) {
        self.requestID = requestID; self.scope = scope; self.phase = phase; self.grantID = grantID; self.reason = reason
    }
}

public struct MicrophoneReceipt: Codable, Equatable {
    public let scope: MicrophoneScope
    public let grantID: UUID
    public let admittedPackets: UInt64
    public let renderedFrames: UInt64
    public let applicationQueueAgeMilliseconds: Double

    public init(scope: MicrophoneScope, grantID: UUID, admittedPackets: UInt64,
                renderedFrames: UInt64, applicationQueueAgeMilliseconds: Double) {
        self.scope = scope; self.grantID = grantID; self.admittedPackets = admittedPackets
        self.renderedFrames = renderedFrames; self.applicationQueueAgeMilliseconds = applicationQueueAgeMilliseconds
    }
}

public enum MicrophoneWire {
    public static let sampleRate = 48_000
    public static let maxFrames = 960
    public static let controlLimit = 2048
    public static let frameHeaderLength = 113
    public static let frameLimit = frameHeaderLength + maxFrames * 2
    public static let replyLimit = 4096


}

public struct MicrophoneFrame: Equatable {
    public let scope: MicrophoneScope
    public let grantID: UUID
    public let sequence: UInt64
    public let frameCount: Int
    public let pcm: Data

    public init?(scope: MicrophoneScope, grantID: UUID, sequence: UInt64, frameCount: Int, pcm: Data) {
        guard scope.source != .none, scope.source != .window(0), sequence > 0, frameCount > 0, frameCount <= MicrophoneWire.maxFrames,
              pcm.count == frameCount * 2 else { return nil }
        self.scope = scope; self.grantID = grantID; self.sequence = sequence
        self.frameCount = frameCount; self.pcm = pcm
    }

    public func encoded() -> Data {
        var data = Data([1, 1])
        for id in [scope.peer, scope.inputGeneration, scope.videoEpoch, scope.destination, scope.capability, grantID] {
            var bytes = id.uuid
            withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
        }
        switch scope.source {
        case .desktop: data.append(1); data.appendBigEndian(UInt32(0))
        case .window(let id): data.append(2); data.appendBigEndian(id)
        case .none: preconditionFailure("unvalidated microphone source")
        }
        data.appendBigEndian(sequence)
        data.appendBigEndian(UInt16(frameCount))
        data.append(pcm)
        return data
    }

    public init?(encoded data: Data) {
        guard data.count >= MicrophoneWire.frameHeaderLength, data.count <= MicrophoneWire.frameLimit,
              data[data.startIndex] == 1, data[data.startIndex + 1] == 1 else { return nil }
        func uuid(_ offset: Int) -> UUID {
            let b = data[data.startIndex + offset..<data.startIndex + offset + 16]
            let a = Array(b)
            return UUID(uuid: (a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7],a[8],a[9],a[10],a[11],a[12],a[13],a[14],a[15]))
        }
        let count = Int(data.readBigEndian(UInt16.self, at: 111))
        guard count > 0, count <= MicrophoneWire.maxFrames,
              data.count == MicrophoneWire.frameHeaderLength + count * 2 else { return nil }
        let source: StreamSource
        let window = data.readBigEndian(UInt32.self, at: 99)
        switch data[data.startIndex + 98] {
        case 1 where window == 0: source = .desktop
        case 2 where window != 0: source = .window(window)
        default: return nil
        }
        self.init(scope: MicrophoneScope(peer: uuid(2), source: source, inputGeneration: uuid(18),
                                        videoEpoch: uuid(34), destination: uuid(50), capability: uuid(66)),
                  grantID: uuid(82), sequence: data.readBigEndian(UInt64.self, at: 103), frameCount: count,
                  pcm: Data(data.dropFirst(MicrophoneWire.frameHeaderLength)))
    }
}
