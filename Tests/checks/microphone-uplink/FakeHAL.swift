import Foundation
import CoreAudio
import AudioToolbox
import StreamProtocol

final class HALTestPause: @unchecked Sendable {
    private let began = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    func hold() { began.signal(); _ = released.wait(timeout: .now() + 3) }
    func waitForEntry() async -> Bool {
        await Task.detached { self.began.wait(timeout: .now() + 3) == .success }.value
    }
    func release() { released.signal() }
}

final class FakeHAL: @unchecked Sendable {
    private struct Storage {
        var trace: [String] = []
        var failAt: String?
        var readbackMismatch = false
        var unsupportedFormat = false
        var physicalTransport = false
        var wrongPlugin = false
        var wrongUID = false
        var wrongChannels = false
        var missingMembership = false
        var blackHole = false
        var wrongRate = false
        var input = true
        var output = false
        var selected = AudioDeviceID(0)
        var format = AudioStreamBasicDescription()
        var maximum: UInt32 = 512
        var provider: AURenderPullInputBlock?
        var running = false
        var allocated = false
        var offMain = true
        var pause: HALTestPause?
    }
    private let lock = NSRecursiveLock()
    private var storage = Storage()
    private func access<T>(_ body: (inout Storage) -> T) -> T { lock.withLock { body(&storage) } }
    var trace: [String] { access { $0.trace } }
    var offMain: Bool { access { $0.offMain } }
    var failAt: String? { get { access { $0.failAt } } set { access { $0.failAt = newValue } } }
    var readbackMismatch: Bool { get { access { $0.readbackMismatch } } set { access { $0.readbackMismatch = newValue } } }
    var unsupportedFormat: Bool { get { access { $0.unsupportedFormat } } set { access { $0.unsupportedFormat = newValue } } }
    var physicalTransport: Bool { get { access { $0.physicalTransport } } set { access { $0.physicalTransport = newValue } } }
    var wrongPlugin: Bool { get { access { $0.wrongPlugin } } set { access { $0.wrongPlugin = newValue } } }
    var wrongUID: Bool { get { access { $0.wrongUID } } set { access { $0.wrongUID = newValue } } }
    var wrongChannels: Bool { get { access { $0.wrongChannels } } set { access { $0.wrongChannels = newValue } } }
    var missingMembership: Bool { get { access { $0.missingMembership } } set { access { $0.missingMembership = newValue } } }
    var blackHole: Bool { get { access { $0.blackHole } } set { access { $0.blackHole = newValue } } }
    var wrongRate: Bool { get { access { $0.wrongRate } } set { access { $0.wrongRate = newValue } } }
    var callback: AURenderPullInputBlock? { access { $0.provider } }
    var selected: AudioDeviceID { access { $0.selected } }
    var running: Bool { access { $0.running } }
    var allocated: Bool { access { $0.allocated } }
    var pauseNextRead: HALTestPause? { get { access { $0.pause } } set { access { $0.pause = newValue } } }
    struct Failure: Error {}
    func status(_ name: String) -> OSStatus {
        access {
            $0.trace.append(name); $0.offMain = $0.offMain && !Thread.isMainThread
            return $0.failAt == name ? -77 : noErr
        }
    }
    private final class Unit: HALMicrophoneOutputUnit {
        let owner: FakeHAL
        init(_ owner: FakeHAL) { self.owner = owner }
        var inputEnabled: Bool {
            get { owner.access { $0.input } }
            set { if owner.status("input") == noErr { owner.access { $0.input = newValue } } }
        }
        var outputEnabled: Bool {
            get { owner.access { $0.output } }
            set { if owner.status("output") == noErr { owner.access { $0.output = newValue } } }
        }
        var deviceID: AudioDeviceID { owner.access { $0.readbackMismatch ? 999 : $0.selected } }
        var format: AudioStreamBasicDescription? {
            owner.access { var value = $0.format; if $0.unsupportedFormat { value.mSampleRate = 44_100 }; return value }
        }
        var maximumFrames: UInt32 {
            get { owner.access { $0.maximum } }
            set { if owner.status("maximum") == noErr { owner.access { $0.maximum = newValue } } }
        }
        var provider: AURenderPullInputBlock? {
            get { owner.callback }
            set { if owner.status(newValue == nil ? "release-provider" : "provider") == noErr { owner.access { $0.provider = newValue } } }
        }
        var isRunning: Bool { owner.running }
        var resourcesAllocated: Bool { owner.allocated }
        func selectDevice(_ id: AudioDeviceID) throws {
            guard owner.status("device") == noErr else { throw Failure() }
            owner.access { $0.selected = id }
        }
        func setFormat(_ value: AudioStreamBasicDescription) throws {
            guard owner.status("format") == noErr else { throw Failure() }
            owner.access { $0.format = value }
        }
        func allocate() throws {
            owner.access { $0.allocated = true }
            guard owner.status("allocate") == noErr else { throw Failure() }
        }
        func start() throws {
            owner.access { $0.running = true }
            guard owner.status("start") == noErr else { throw Failure() }
        }
        func stop() { if owner.status("stop") == noErr { owner.access { $0.running = false } } }
        func deallocate() { if owner.status("deallocate") == noErr { owner.access { $0.allocated = false } } }
    }
    var operations: HALMicrophoneOperations {
        HALMicrophoneOperations(objectGet: { [self] object, address, _, qualifier, size, output in
            let selector = address.pointee.mSelector
            let result = status("read:\(selector)")
            guard result == noErr else { return result }
            let pause = access { state in let value = state.pause; state.pause = nil; return value }
            pause?.hold()
            switch selector {
            case kAudioHardwarePropertyTranslateUIDToDevice:
                let uid = qualifier!.assumingMemoryBound(to: CFString.self).pointee as String
                output.assumingMemoryBound(to: AudioDeviceID.self).pointee = blackHole ? (uid == "test.blackhole" ? 96 : 0) : uid == "test.output" ? 41 : 42
                size.pointee = 4
            case kAudioHardwarePropertyTranslateBundleIDToPlugIn:
                guard object == kAudioObjectSystemObject else { return -78 }
                let bundle = qualifier!.assumingMemoryBound(to: CFString.self).pointee as String
                guard bundle == (blackHole ? "audio.existential.BlackHole2ch" : "test.plugin") else { return -78 }
                output.assumingMemoryBound(to: AudioObjectID.self).pointee = blackHole ? 34 : 70
                size.pointee = 4
            case kAudioPlugInPropertyDeviceList:
                guard object == (blackHole ? 34 : 70) else { return -78 }
                let ids: [AudioDeviceID] = missingMembership ? [999] : blackHole ? [96] : [41, 42]
                ids.withUnsafeBufferPointer { output.copyMemory(from: $0.baseAddress!, byteCount: ids.count * 4) }
                size.pointee = UInt32(ids.count * 4)
            case kAudioDevicePropertyDeviceUID:
                output.assumingMemoryBound(to: CFString?.self).pointee = (wrongUID ? "wrong" : blackHole ? "test.blackhole" : object == 41 ? "test.output" : "test.input") as CFString
            case kAudioDevicePropertyTransportType:
                output.assumingMemoryBound(to: UInt32.self).pointee = physicalTransport ? 0 : kAudioDeviceTransportTypeVirtual
            case kAudioObjectPropertyOwner:
                output.assumingMemoryBound(to: AudioObjectID.self).pointee = AudioObjectID(kAudioObjectSystemObject)
            case kAudioDevicePropertyDeviceIsAlive:
                output.assumingMemoryBound(to: UInt32.self).pointee = 1
            case kAudioDevicePropertyNominalSampleRate:
                output.assumingMemoryBound(to: Float64.self).pointee = wrongRate ? 44_100 : 48_000
            case kAudioPlugInPropertyBundleID:
                guard object == (blackHole ? 34 : 70) else { return -78 }
                output.assumingMemoryBound(to: CFString?.self).pointee = (wrongPlugin ? "wrong" : blackHole ? "audio.existential.BlackHole2ch" : "test.plugin") as CFString
            case kAudioDevicePropertyStreamConfiguration:
                output.assumingMemoryBound(to: AudioBufferList.self).pointee = AudioBufferList(mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: wrongChannels ? 3 : 2, mDataByteSize: 0, mData: nil))
            default: return -78
            }
            return noErr
        }, objectSize: { [self] _, address, size in
            let result = status("streamSize")
            size.pointee = address.pointee.mSelector == kAudioPlugInPropertyDeviceList
                ? UInt32((missingMembership || blackHole ? 1 : 2) * 4) : UInt32(MemoryLayout<AudioBufferList>.size)
            return result
        }, create: { [self] in
            guard status("create") == noErr else { throw Failure() }
            return Unit(self)
        })
    }
    func render(frames: Int = 2) -> [Int16] { Self.render(callback, frames: frames) }
    static func render(_ callback: AURenderPullInputBlock?, frames: Int = 2) -> [Int16] {
        let pcm = UnsafeMutablePointer<Int16>.allocate(capacity: frames * 2)
        pcm.initialize(repeating: 123, count: frames * 2)
        defer { pcm.deinitialize(count: frames * 2); pcm.deallocate() }
        var buffers = AudioBufferList(mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 4), mData: pcm))
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        if let callback { _ = callback(&flags, &time, UInt32(frames), 0, &buffers) }
        return Array(UnsafeBufferPointer(start: pcm, count: frames * 2))
    }
}
