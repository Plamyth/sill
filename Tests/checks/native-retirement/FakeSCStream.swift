import CoreMedia
import Foundation

public enum SCStreamOutputType { case audio }
public protocol SCStreamOutput: AnyObject {
    func stream(_ stream: SCStream, didOutputSampleBuffer: CMSampleBuffer, of: SCStreamOutputType)
}
public protocol SCStreamDelegate: AnyObject {
    func stream(_ stream: SCStream, didStopWithError: Error)
}
public final class SCDisplay { public init() {} }
public final class SCContentFilter {
    public init(display: SCDisplay, excludingWindows: [Int]) {}
}
public final class SCStreamConfiguration {
    public var width = 0, height = 0, sampleRate = 0, channelCount = 0
    public var minimumFrameInterval = CMTime.zero
    public var capturesAudio = false, excludesCurrentProcessAudio = false
    public init() {}
}

public final class SCStream: NSObject, @unchecked Sendable {
    public struct Failure: Error {}
    private static let inventoryLock = NSLock()
    private static var inventory: [SCStream] = []
    public static var instances: [SCStream] { inventoryLock.withLock { inventory } }
    public static var delayNextStart = false
    public static var failNextStart = false
    private weak var delegate: SCStreamDelegate?
    private let lock = NSLock()
    private var startGate: CheckedContinuation<Void, Never>?
    private var stopGate: CheckedContinuation<Void, Never>?
    private let delayedStart: Bool
    private let failedStart: Bool
    private var stopCount = 0
    private var startFinished = false
    private var stopsBeforeStart = 0
    public var failuresRemaining = 0
    public var delayStop = false
    public private(set) var sampleQueue: DispatchQueue!
    public var stopCalls: Int { lock.withLock { stopCount } }
    public var startIsWaiting: Bool { lock.withLock { startGate != nil } }
    public var stopIsWaiting: Bool { lock.withLock { stopGate != nil } }
    public var prematureStops: Int { lock.withLock { stopsBeforeStart } }

    public init(filter: SCContentFilter, configuration: SCStreamConfiguration, delegate: SCStreamDelegate?) {
        self.delegate = delegate
        delayedStart = Self.delayNextStart
        failedStart = Self.failNextStart
        Self.delayNextStart = false
        Self.failNextStart = false
        super.init()
        Self.inventoryLock.withLock { Self.inventory.append(self) }
    }
    public func addStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType,
                                sampleHandlerQueue: DispatchQueue) throws { sampleQueue = sampleHandlerQueue }
    public func startCapture() async throws {
        if delayedStart { await withCheckedContinuation { gate in lock.withLock { startGate = gate } } }
        lock.withLock { startFinished = true }
        if failedStart { throw Failure() }
    }
    public func stopCapture() async throws {
        lock.withLock {
            stopCount += 1
            if !startFinished { stopsBeforeStart += 1 }
        }
        if delayStop { await withCheckedContinuation { gate in lock.withLock { stopGate = gate } } }
        let fail = lock.withLock {
            if failuresRemaining > 0 { failuresRemaining -= 1; return true }
            return false
        }
        if fail { throw Failure() }
    }
    public func finishStart() {
        let gate = lock.withLock { let gate = startGate; startGate = nil; return gate }
        gate?.resume()
    }
    public func finishStop() {
        let gate = lock.withLock { let gate = stopGate; stopGate = nil; return gate }
        gate?.resume()
    }
    public func sendLateError() { delegate?.stream(self, didStopWithError: Failure()) }
}
