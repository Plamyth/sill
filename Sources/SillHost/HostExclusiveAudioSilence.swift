import AudioSilence
import CoreAudio
import Foundation
import Darwin

/// A candidate holds only its own IOProc and hog transaction. Its evidence does not attest mixer routing.
@MainActor
final class HostExclusiveAudioSilence {
    struct Device: Equatable {
        let id: UInt32
        let uid: String
        let inputChannels: Int
        let outputChannels: Int
        let sampleRate: Double
        let hogPID: pid_t
        let running: Bool
        var formatSignature: String = ""
    }
    struct Operations {
        var read: () -> Device?
        var toggleHog: () -> Bool
        var create: (OpaquePointer) -> AudioDeviceIOProcID?
        var start: (AudioDeviceIOProcID) -> Bool
        var stop: (AudioDeviceIOProcID) -> Bool
        var destroy: (AudioDeviceIOProcID) -> Bool
        var now: () -> UInt64 = { mach_continuous_time() }
        var elapsedNanoseconds: (UInt64) -> UInt64 = { ticks in
            var timebase = mach_timebase_info_data_t()
            guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return .max }
            let (scaled, overflow) = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer))
            return overflow ? .max : scaled / UInt64(timebase.denom)
        }
    }
    struct Evidence {
        let uid: String
        let inputChannels: Int
        let outputChannels: Int
        let callbacks: UInt64
        let zeroedBytes: UInt64
        let lastTick: UInt64
        // A second process and the physical mixer must be checked before adding this mechanism to plan().
        var permitsRemoteAudio: Bool { false }
    }
    private let ops: Operations
    private var original: Device?
    private var context: OpaquePointer?
    private var ioProc: AudioDeviceIOProcID?
    private var ownsHog = false
    private var startAttempted = false
    private(set) var failure: String?

    init(ops: Operations) { self.ops = ops }

    func startCandidate() -> Bool {
        guard original == nil, context == nil, ioProc == nil, !ownsHog else { return false }
        guard let before = ops.read(), before.hogPID == -1, !before.running,
              !before.uid.isEmpty, (0...1024).contains(before.inputChannels),
              (0...1024).contains(before.outputChannels), before.inputChannels + before.outputChannels > 0,
              before.sampleRate.isFinite, (8_000...384_000).contains(before.sampleRate) else {
            failure = "장치가 사용 중이거나 배타 소유권·채널·형식을 확인할 수 없습니다."
            return false
        }
        original = before
        guard ops.toggleHog(), let after = ops.read(), sameDevice(after, before), after.hogPID == getpid() else {
            // A setter can report failure after taking the device. Resolve actual ownership before cleanup.
            ownsHog = ops.read().map { sameDevice($0, before) && $0.hogPID == getpid() } == true
            failure = "배타 소유권 취득을 readback하지 못했습니다."
            _ = retireAfterAuthenticatedReturn()
            return false
        }
        ownsHog = true
        guard let context = SillSilenceCreate(UInt32(before.inputChannels), UInt32(before.outputChannels)) else {
            failure = "무음 처리 상태를 만들지 못했습니다."; _ = retireAfterAuthenticatedReturn(); return false
        }
        self.context = context
        guard let proc = ops.create(context) else {
            failure = "배타 장치의 실제 IOProc를 만들지 못했습니다."; _ = retireAfterAuthenticatedReturn(); return false
        }
        ioProc = proc
        startAttempted = true
        guard let owned = ops.read(), sameDevice(owned, before), owned.hogPID == getpid(), ops.start(proc) else {
            failure = "실제 배타 IOProc를 시작하지 못했습니다."; _ = retireAfterAuthenticatedReturn(); return false
        }
        failure = "전체 채널 무음 callback과 별도 프로세스·믹서 검증을 기다립니다."
        return true
    }

    func inspectCandidate() -> Evidence? {
        guard ownsHog, startAttempted, ioProc != nil, let context, let original,
              let before = ops.read(), sameDevice(before, original), before.hogPID == getpid(), before.running else { return nil }
        var result = SillSilenceReadback()
        guard SillSilenceInspect(context, &result), !result.fault, result.callbacks >= 2,
              result.inputChannels == original.inputChannels, result.outputChannels == original.outputChannels,
              original.outputChannels == 0 || result.zeroedBytes > 0 else { return nil }
        let now = ops.now()
        guard now >= result.lastTick, ops.elapsedNanoseconds(now - result.lastTick) <= 250_000_000,
              let after = ops.read(), after == before else { return nil }
        return Evidence(uid: original.uid, inputChannels: original.inputChannels, outputChannels: original.outputChannels,
            callbacks: result.callbacks, zeroedBytes: result.zeroedBytes, lastTick: result.lastTick)
    }

    /// Invoke only after authentication and all native/relay participants are fenced and drained.
    @discardableResult
    func retireAfterAuthenticatedReturn() -> Bool {
        if let proc = ioProc {
            guard let original, let current = ops.read(), sameDevice(current, original), current.hogPID == getpid() else {
                failure = "장치 식별자나 소유자가 바뀌어 기존 IOProc를 보존했습니다."; return false
            }
            if startAttempted && !ops.stop(proc) { failure = "배타 IOProc 중지를 확인하지 못했습니다."; return false }
            startAttempted = false
            guard ops.destroy(proc) else { failure = "배타 IOProc 해제를 확인하지 못했습니다."; return false }
            ioProc = nil
        }
        if let context { SillSilenceDestroy(context); self.context = nil }
        if ownsHog {
            guard let original, let current = ops.read(), sameDevice(current, original), current.hogPID == getpid() else {
                failure = "장치 소유자가 바뀌어 배타 권한을 임의 해제하지 않았습니다."; return false
            }
            let released = ops.toggleHog()
            guard released, let after = ops.read(), sameDevice(after, original), after.hogPID == -1 else {
                failure = "배타 권한 해제를 readback하지 못했습니다."; return false
            }
            ownsHog = false
        }
        original = nil
        return true
    }

    private func sameDevice(_ a: Device, _ b: Device) -> Bool {
        a.id == b.id && a.uid == b.uid && a.inputChannels == b.inputChannels &&
        a.outputChannels == b.outputChannels && a.sampleRate == b.sampleRate && a.formatSignature == b.formatSignature
    }
}

extension HostExclusiveAudioSilence.Operations {
    @MainActor static func native(uid: String) -> Self {
        let registry = HALMicrophoneDeviceRegistry(ops: .native)
        func formatSignature(_ id: UInt32, scope: AudioObjectPropertyScope, channels: Int) -> String? {
            if channels == 0 { return "" }
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
                  size > 0, size <= 128 * 4, size % 4 == 0 else { return nil }
            let capacity = size
            var streams = [UInt32](repeating: 0, count: Int(size) / 4)
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &streams) == noErr,
                  size == capacity, Set(streams).count == streams.count else { return nil }
            var total = 0, signature = ""
            for stream in streams {
                var format = AudioStreamBasicDescription()
                guard (try? registry.read(stream, kAudioStreamPropertyVirtualFormat, into: &format)) != nil,
                      format.mFormatID == kAudioFormatLinearPCM,
                      format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger) != 0,
                      format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 1024,
                      format.mBytesPerFrame > 0, format.mBitsPerChannel > 0 else { return nil }
                total += Int(format.mChannelsPerFrame)
                signature += "\(scope):\(stream):\(format.mSampleRate.bitPattern):\(format.mFormatID):\(format.mFormatFlags):\(format.mBytesPerPacket):\(format.mFramesPerPacket):\(format.mBytesPerFrame):\(format.mChannelsPerFrame):\(format.mBitsPerChannel);"
            }
            return total == channels ? signature : nil
        }
        func read() -> HostExclusiveAudioSilence.Device? {
            guard let id = try? registry.resolve(uid),
                  let snapshot = try? CoreAudioPrivacyHAL(ops: .native).read(),
                  let device = snapshot.devices.first(where: { $0.id == id && $0.uid == uid }) else { return nil }
            var hog: pid_t = -2, running: UInt32 = 0, rate: Double = 0
            guard (try? registry.read(id, kAudioDevicePropertyHogMode, into: &hog)) != nil,
                  (try? registry.read(id, kAudioDevicePropertyDeviceIsRunningSomewhere, into: &running)) != nil,
                  (try? registry.read(id, kAudioDevicePropertyNominalSampleRate, into: &rate)) != nil,
                  let inputFormat = formatSignature(id, scope: kAudioObjectPropertyScopeInput, channels: device.inputChannels),
                  let outputFormat = formatSignature(id, scope: kAudioObjectPropertyScopeOutput, channels: device.outputChannels) else { return nil }
            return .init(id: id, uid: uid, inputChannels: device.inputChannels, outputChannels: device.outputChannels,
                         sampleRate: rate, hogPID: hog, running: running == 1, formatSignature: inputFormat + outputFormat)
        }
        return Self(read: read, toggleHog: {
            guard let id = try? registry.resolve(uid) else { return false }
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyHogMode,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var settable = DarwinBoolean(false)
            var value: pid_t = -1
            guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return false }
            return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<pid_t>.size), &value) == noErr
        }, create: { context in
            guard let id = try? registry.resolve(uid) else { return nil }
            var proc: AudioDeviceIOProcID?
            guard AudioDeviceCreateIOProcID(id, SillSilenceIOProc, UnsafeMutableRawPointer(context), &proc) == noErr else { return nil }
            return proc
        }, start: { proc in
            guard let id = try? registry.resolve(uid) else { return false }; return AudioDeviceStart(id, proc) == noErr
        }, stop: { proc in
            guard let id = try? registry.resolve(uid) else { return false }; return AudioDeviceStop(id, proc) == noErr
        }, destroy: { proc in
            guard let id = try? registry.resolve(uid) else { return false }; return AudioDeviceDestroyIOProcID(id, proc) == noErr
        })
    }
}
