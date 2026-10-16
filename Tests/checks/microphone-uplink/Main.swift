import Foundation
import Network
import CoreAudio
import AudioToolbox
import StreamProtocol

@MainActor var assertions = 0
@MainActor func expect(_ value: @autoclosure () -> Bool, _ name: String) {
    assertions += 1
    if !value() { print("FAIL \(name)"); exit(1) }
}
@MainActor func settle() async { for _ in 0..<100 { await Task.yield() } }
@MainActor func until(_ predicate: () -> Bool, _ name: String) async {
    for _ in 0..<1000 {
        if predicate() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    expect(false, name)
}
func scope(peer: UUID = UUID(), source: StreamSource = .desktop, generation: UUID = UUID(),
           epoch: UUID = UUID(), destination: UUID = UUID(), capability: UUID = UUID()) -> MicrophoneScope {
    MicrophoneScope(peer: peer, source: source, inputGeneration: generation, videoEpoch: epoch,
                    destination: destination, capability: capability)
}
func ownerGrant(_ scope: MicrophoneScope, fingerprint: Data = Data([1]), expiry: UInt64? = nil) -> HostLocalOwnerGrant {
    HostLocalOwnerGrant(owner: UUID(), callGeneration: UUID(), scope: scope, fingerprint: fingerprint,
        destination: HostMicrophoneDestination(outputUID: "test.output", inputUID: "test.input", pluginBundleID: "test.plugin",
            outputChannels: 2, inputChannels: 2, outputChannel: 1, inputChannel: 0)!,
        expiresAt: expiry ?? DispatchTime.now().uptimeNanoseconds + 30_000_000_000)
}
func packet(_ scope: MicrophoneScope, grant: UUID, sequence: UInt64 = 1) -> MicrophoneFrame {
    MicrophoneFrame(scope: scope, grantID: grant, sequence: sequence, frameCount: 2, pcm: Data([1, 0, 255, 127]))!
}
@MainActor final class FakeOwner: HostMicrophoneOriginalOwner {
    var grant: HostLocalOwnerGrant?
    init(_ grant: HostLocalOwnerGrant?) { self.grant = grant }
    func microphoneGrant(peer: UUID, source: StreamSource, inputGeneration: UUID, videoEpoch: UUID, fingerprint: Data) -> HostLocalOwnerGrant? { grant }
}
@MainActor final class FakeSink: HostMicrophoneSink {
    var closes = 0
    var closeError: String?
    var running = true
    func close() async -> String? { closes += 1; return closeError }
    func runtimeValid() -> Bool { running }
}
@MainActor final class Fixture {
    let binding: MicrophoneScope
    let owner: FakeOwner
    let sink = FakeSink()
    var receiver: HostMicrophoneReceiver!
    var states: [MicrophoneState] = []
    var render: MicrophoneRenderBuffer?
    var continuation: CheckedContinuation<HostMicrophonePreparation, Never>?
    var prepares = 0
    var allow = true
    var heldReplies = false
    var now = DispatchTime.now().uptimeNanoseconds
    init(delayed: Bool = false, capacity: Int = 128, serialLimit: UInt64 = .max, withOwner: Bool = true) {
        binding = scope()
        owner = FakeOwner(withOwner ? ownerGrant(binding) : nil)
        receiver = HostMicrophoneReceiver(provider: withOwner ? owner : nil, capacity: capacity, serialLimit: serialLimit,
            automaticWatchdog: false, backendAvailable: true, now: { [unowned self] in self.now }, prepare: { [unowned self] _, render in
                self.prepares += 1; self.render = render
                if delayed { return await withCheckedContinuation { self.continuation = $0 } }
                return HostMicrophonePreparation(resource: self.sink, error: nil)
            })
        receiver.current = { [unowned self] binding, fingerprint in self.allow && binding == self.binding && fingerprint == Data([1]) }
        receiver.sendState = { [unowned self] state, render in
            self.states.append(state)
            if !self.heldReplies { render?.sendEnabled(Data(), to: NWConnection()) }
        }
        advertise()
    }
    @discardableResult func advertise() -> MicrophoneCapability? {
        receiver.capability(peer: binding.peer, source: binding.source, inputGeneration: binding.inputGeneration,
                            videoEpoch: binding.videoEpoch, fingerprint: Data([1]))
    }
    func start(id: UUID = UUID()) -> MicrophoneControl {
        let request = MicrophoneControl(operation: .start, requestID: id, scope: binding)
        receiver.control(request, fingerprint: Data([1]))
        return request
    }
    func stop() -> MicrophoneControl {
        let id = states.first(where: { $0.grantID != nil })!.grantID!
        let request = MicrophoneControl(operation: .stop, requestID: UUID(), scope: binding, grantID: id)
        receiver.control(request, fingerprint: Data([1]))
        return request
    }
    var grantID: UUID { states.first(where: { $0.grantID != nil })!.grantID! }
    func finishPrepare() { continuation!.resume(returning: HostMicrophonePreparation(resource: sink, error: nil)); continuation = nil }
}

@main struct Check {
    @MainActor static func main() async {
        let wireScope = scope()
        let frame = packet(wireScope, grant: UUID())
        expect(frame.encoded().count == 117, "wire-size")
        expect(MicrophoneFrame(encoded: frame.encoded()) == frame, "wire-roundtrip")
        var slice = Data([90]); slice.append(frame.encoded())
        expect(MicrophoneFrame(encoded: slice.dropFirst()) == frame, "wire-sliced-data")
        expect(MicrophoneFrame(encoded: frame.encoded() + Data([0])) == nil, "wire-trailing")
        for count in 0..<MicrophoneWire.frameHeaderLength {
            expect(MicrophoneFrame(encoded: Data(frame.encoded().prefix(count))) == nil, "wire-truncated")
        }
        var countWrong = frame.encoded(); countWrong[111] = 3; countWrong[112] = 193
        expect(MicrophoneFrame(encoded: countWrong) == nil, "wire-count-cap")
        countWrong = frame.encoded(); countWrong[112] = 3
        expect(MicrophoneFrame(encoded: countWrong) == nil, "wire-exact-count")
        var versionWrong = frame.encoded(); versionWrong[1] = 2
        expect(MicrophoneFrame(encoded: versionWrong) == nil, "wire-format")
        expect(MicrophoneFrame(scope: wireScope, grantID: UUID(), sequence: 1, frameCount: 961, pcm: Data(count: 1922)) == nil, "wire-frame-cap")
        expect(MicrophoneFrame(scope: wireScope, grantID: UUID(), sequence: 0, frameCount: 1, pcm: Data(count: 2)) == nil, "wire-zero-sequence")
        let legacyData = Data("{\"macName\":\"old\",\"windows\":[],\"active\":{\"desktop\":{}}}".utf8)
        expect(Wire.decode(WindowList.self, from: legacyData)?.microphone == nil, "old-peer-decode")
        let catalog = WindowList(macName: "test", windows: [], active: .desktop)
        let catalogJSON = try! JSONSerialization.jsonObject(with: Wire.encode(catalog)) as! [String: Any]
        expect(catalog.microphone == nil && catalogJSON["microphone"] == nil, "nil-capability")
        var unknown = StreamMessage(kind: .microphoneFrame, timestamp: 0, isKeyframe: false, payload: Data()).serialized()
        unknown[0] = 208
        expect(StreamMessage.parseHeader(unknown)?.kind == .unknown, "unknown-kind")
        expect(StreamMessage.clientPayloadLimit(for: .microphoneFrame) == MicrophoneWire.frameLimit, "reader-frame-cap")
        expect(StreamMessage.clientPayloadLimit(for: .microphoneControl) == MicrophoneWire.controlLimit, "reader-control-cap")
        expect(StreamMessage.hostPayloadLimit(for: .microphoneState) == MicrophoneWire.replyLimit, "reader-reply-cap")

        let absent = Fixture(withOwner: false)
        expect(absent.advertise() == nil, "absent-owner-cap")
        _ = absent.start(); await settle()
        expect(absent.prepares == 0 && absent.receiver.phase == .off, "absent-owner-no-io")
        absent.receiver.revoke(reason: "disconnect")
        expect(absent.prepares == 0, "absent-disconnect-no-io")

        let f = Fixture()
        let start = f.start(); f.receiver.control(start, fingerprint: Data([1])); await settle()
        expect(f.prepares == 1 && f.receiver.phase == .active, "duplicate-one-prepare")
        let conflict = MicrophoneControl(operation: .start, requestID: start.requestID, scope: scope())
        f.receiver.control(conflict, fingerprint: Data([1]))
        expect(f.states.last?.reason == "request conflict", "request-conflict")
        f.receiver.control(start, fingerprint: Data([2]))
        expect(f.states.last?.phase == .refused, "duplicate-owner-binding")
        let p = packet(f.binding, grant: f.grantID)
        expect(f.receiver.frame(p, fingerprint: Data([1]), arrived: f.now), "frame-admission")
        expect(!f.receiver.frame(p, fingerprint: Data([1]), arrived: f.now), "frame-replay")
        expect(!f.receiver.frame(packet(f.binding, grant: f.grantID, sequence: 9000), fingerprint: Data([1]), arrived: f.now), "frame-gap")
        expect(!f.receiver.frame(packet(f.binding, grant: f.grantID, sequence: 2), fingerprint: Data([2]), arrived: f.now), "frame-wrong-peer")
        let stale = scope(peer: f.binding.peer, generation: f.binding.inputGeneration, epoch: UUID(), destination: f.binding.destination, capability: f.binding.capability)
        expect(!f.receiver.frame(packet(stale, grant: f.grantID, sequence: 2), fingerprint: Data([1]), arrived: f.now), "frame-wrong-epoch")
        expect(!f.receiver.frame(packet(f.binding, grant: UUID(), sequence: 2), fingerprint: Data([1]), arrived: f.now), "frame-wrong-grant")
        expect(!f.receiver.frame(packet(f.binding, grant: f.grantID, sequence: 2), fingerprint: Data([1]), arrived: f.now - 61_000_000), "frame-stale-queue")
        var rendered = [Int16](repeating: 0, count: 2)
        f.render!.render(frames: 2, now: f.now) { rendered[$0] = $1 }
        expect(rendered == [1, 32767], "render-pcm")
        var receipt: MicrophoneReceipt?
        f.receiver.sendReceipt = { receipt = $0 }
        f.receiver.control(MicrophoneControl(operation: .receipt, requestID: UUID(), scope: f.binding, grantID: f.grantID), fingerprint: Data([1]))
        expect(receipt?.admittedPackets == 1 && receipt?.renderedFrames == 2 && receipt?.applicationQueueAgeMilliseconds == 0, "receipt-admission-render-counts")
        for wrong in [scope(peer: f.binding.peer, source: .window(9), generation: f.binding.inputGeneration, epoch: f.binding.videoEpoch, destination: f.binding.destination, capability: f.binding.capability),
                      scope(peer: f.binding.peer, generation: UUID(), epoch: f.binding.videoEpoch, destination: f.binding.destination, capability: f.binding.capability),
                      scope(peer: f.binding.peer, generation: f.binding.inputGeneration, epoch: f.binding.videoEpoch, destination: UUID(), capability: f.binding.capability)] {
            expect(!f.receiver.frame(packet(wrong, grant: f.grantID, sequence: 2), fingerprint: Data([1]), arrived: f.now), "frame-exact-scope")
        }
        let oldStop = f.stop()
        rendered = [0, 0]
        f.render!.render(frames: 2, now: f.now) { rendered[$0] = $1 }
        expect(rendered == [0, 0], "revoke-silence")
        expect(!f.receiver.frame(packet(f.binding, grant: f.grantID, sequence: 2), fingerprint: Data([1]), arrived: f.now), "revoke-frame")
        await settle()
        f.receiver.control(oldStop, fingerprint: Data([1])); await settle()
        expect(f.receiver.phase == .off && f.sink.closes == 1, "duplicate-stop-one-close")
        expect(f.states.last?.phase == .off, "duplicate-stop-terminal")
        f.advertise(); _ = f.start(); await settle()
        f.receiver.control(oldStop, fingerprint: Data([1]))
        expect(f.receiver.phase == .active && f.prepares == 2, "old-stop-exact-resource")
        f.receiver.revoke(reason: "test ends"); await settle()

        let delayed = Fixture(delayed: true)
        _ = delayed.start(); await settle()
        _ = delayed.stop()
        expect(delayed.receiver.phase == .retiring, "stop-before-prepare")
        _ = delayed.start()
        delayed.finishPrepare(); await settle()
        expect(delayed.sink.closes == 1 && delayed.receiver.phase == .off, "late-prepare-owned-cleanup")
        expect(!delayed.states.contains(where: { $0.phase == .active }), "late-prepare-no-enabled")

        let failure = Fixture()
        failure.sink.closeError = "uncertain stop"
        _ = failure.start(); await settle(); _ = failure.stop(); await settle()
        _ = failure.start(); failure.receiver.revoke(reason: "duplicate"); await settle()
        expect(failure.receiver.phase == .cleanupFailed && failure.prepares == 1 && failure.sink.closes == 1, "cleanup-quarantine")
        expect(failure.advertise() == nil, "cleanup-no-capability")

        let held = Fixture(); held.heldReplies = true
        _ = held.start(); await settle()
        expect(!held.receiver.frame(packet(held.binding, grant: held.grantID), fingerprint: Data([1]), arrived: held.now), "no-frame-before-enabled-send")
        _ = held.stop()
        let sent = held.render!.sendEnabled(Data(), to: NWConnection())
        expect(!sent, "held-enabled-recheck")
        await settle()

        let revoke = Fixture(); _ = revoke.start(); await settle()
        revoke.owner.grant!.revoke()
        expect(!revoke.receiver.frame(packet(revoke.binding, grant: revoke.grantID), fingerprint: Data([1]), arrived: revoke.now), "owner-revoke-frame")
        revoke.receiver.checkWatchdog(); await settle()
        expect(revoke.receiver.phase == .off, "owner-watchdog-cleanup")
        let expiry = Fixture(); _ = expiry.start(); await settle()
        expiry.now = expiry.owner.grant!.expiresAt
        expiry.receiver.checkWatchdog(); await settle()
        expect(expiry.receiver.phase == .off, "expiry-watchdog")
        let idle = Fixture(); _ = idle.start(); await settle(); idle.now += 2_000_000_001
        idle.receiver.checkWatchdog(); await settle()
        expect(idle.receiver.phase == .off, "idle-watchdog")
        let runtime = Fixture(); _ = runtime.start(); await settle(); runtime.sink.running = false
        runtime.receiver.checkWatchdog(); await settle()
        expect(runtime.receiver.phase == .off, "runtime-watchdog")
        let exhausted = Fixture(serialLimit: 1); _ = exhausted.start(); await settle(); _ = exhausted.stop(); await settle()
        _ = exhausted.start(); await settle()
        expect(exhausted.prepares == 1 && exhausted.advertise() == nil, "finite-lease-ids")
        let bounded = Fixture(capacity: 3); let stable = bounded.start(); await settle()
        _ = bounded.start(); let stop = bounded.stop(); await settle()
        _ = bounded.start(); bounded.receiver.control(stable, fingerprint: Data([1])); bounded.receiver.control(stop, fingerprint: Data([1]))
        expect(bounded.prepares == 1 && bounded.states.last?.phase == .off, "finite-actions-no-eviction")

        await cancellationTests()
        await nativeTests()
        await integrationTests()
        print("RESULT_ASSERTIONS \(assertions)")
    }

    @MainActor static func cancellationTests() async {
        let before = Fixture()
        let id = UUID()
        let cancel = MicrophoneControl(operation: .stop, requestID: id, scope: before.binding)
        expect(MicrophoneControl.decode(Wire.encode(cancel)) == cancel, "cancel-without-grant-decodes")
        before.receiver.control(cancel, fingerprint: Data([1]))
        _ = before.start(id: id); await settle()
        expect(before.prepares == 0 && before.receiver.phase == .off, "cancellation-before-start")
        before.receiver.control(cancel, fingerprint: Data([2]))
        expect(before.states.last?.phase == .refused, "cancel-wrong-fingerprint")

        let paused = Fixture(delayed: true)
        let pending = paused.start(); await settle()
        paused.receiver.control(MicrophoneControl(operation: .stop, requestID: pending.requestID, scope: pending.scope), fingerprint: Data([1]))
        paused.finishPrepare(); await settle()
        _ = paused.start(id: pending.requestID); await settle()
        expect(paused.prepares == 1 && paused.sink.closes == 1 && paused.receiver.phase == .off, "cancellation-paused-prepare")

        let lost = Fixture(); let original = lost.start(); await settle()
        lost.receiver.control(MicrophoneControl(operation: .stop, requestID: original.requestID, scope: original.scope), fingerprint: Data([1]))
        await settle(); _ = lost.start(id: original.requestID); await settle()
        expect(lost.prepares == 1 && lost.sink.closes == 1 && lost.receiver.phase == .off, "cancellation-lost-ack")

        let bounded = Fixture(capacity: 3)
        for _ in 0..<6 {
            bounded.receiver.control(MicrophoneControl(operation: .stop, requestID: UUID(), scope: bounded.binding), fingerprint: Data([1]))
        }
        _ = bounded.start(); await settle()
        expect(bounded.prepares == 0 && bounded.advertise() == nil, "cancellation-tombstone-capacity")

        let failed = Fixture(); failed.sink.closeError = "uncertain stop"
        _ = failed.start(); await settle(); _ = failed.stop(); await settle()
        failed.receiver.retryCleanup(grantID: UUID()); await settle()
        expect(failed.sink.closes == 1, "cleanup-retry-exact-id")
        failed.sink.closeError = nil
        failed.receiver.retryCleanup(grantID: failed.grantID); await settle()
        expect(failed.sink.closes == 2 && failed.receiver.phase == .off && failed.prepares == 1, "cleanup-explicit-retry")

        let partial = Fixture(delayed: true)
        partial.sink.closeError = "uncertain partial stop"
        _ = partial.start(); await settle()
        partial.continuation!.resume(returning: HostMicrophonePreparation(resource: partial.sink, error: "partial prepare"))
        partial.continuation = nil
        await settle()
        expect(partial.sink.closes == 1 && partial.receiver.phase == .cleanupFailed, "partial-prepare-single-close")
    }

    @MainActor static func nativeTests() async {
        let grant = ownerGrant(scope())
        var unsupportedPrepares = 0
        let disabled = HostMicrophoneReceiver(provider: FakeOwner(grant), automaticWatchdog: false, backendAvailable: false, prepare: { _, _ in
            unsupportedPrepares += 1
            return HostMicrophonePreparation(resource: nil, error: "must not prepare")
        })
        disabled.current = { binding, fingerprint in binding == grant.scope && fingerprint == grant.fingerprint }
        let unavailableCap = disabled.capability(peer: grant.scope.peer, source: grant.scope.source,
            inputGeneration: grant.scope.inputGeneration, videoEpoch: grant.scope.videoEpoch, fingerprint: grant.fingerprint)
        disabled.control(MicrophoneControl(operation: .start, requestID: UUID(), scope: grant.scope), fingerprint: grant.fingerprint)
        await settle()
        expect(unavailableCap == nil && unsupportedPrepares == 0 && disabled.phase == .off, "disabled-backend-valid-owner-nil-cap")

        let render = MicrophoneRenderBuffer(grant: grant)
        render.sendEnabled(Data(), to: NWConnection())
        let fake = FakeHAL()
        let prepared = await HALMicrophoneSink.prepare(grant: grant, render: render, ops: fake.operations)
        expect(prepared.error == nil && fake.selected == 41, "hal-explicit-device")
        expect(fake.offMain, "hal-hardware-off-main")
        expect(fake.trace.firstIndex(of: "input")! < fake.trace.firstIndex(of: "start")!, "hal-input-disabled-first")
        expect(fake.trace.firstIndex(of: "device")! < fake.trace.firstIndex(of: "start")!, "hal-device-readback-first")
        let now = DispatchTime.now().uptimeNanoseconds
        expect(render.offer(packet(grant.scope, grant: UUID()), arrived: now, now: now), "hal-offer")
        expect(fake.render() == [0, 1, 0, 32767], "hal-mapped-callback")
        expect(fake.render() == [0, 0, 0, 0], "hal-underrun-zeros")
        let late = fake.callback
        let closed = await prepared.resource!.close()
        expect(closed == nil && !fake.running && !fake.allocated && fake.callback == nil, "hal-owned-cleanup")
        expect(FakeHAL.render(late) == [0, 0, 0, 0], "hal-late-owned-block-silent")
        expect(fake.trace.firstIndex(of: "stop")! < fake.trace.firstIndex(of: "deallocate")!, "hal-stop-before-deallocate")
        expect(fake.trace.firstIndex(of: "deallocate")! < fake.trace.firstIndex(of: "release-provider")!, "hal-release-after-deallocate")

        for name in ["create", "input", "output", "device", "format", "provider", "maximum", "allocate", "start"] {
            let ops = FakeHAL(); ops.failAt = name
            let result = await HALMicrophoneSink.prepare(grant: grant, render: MicrophoneRenderBuffer(grant: grant), ops: ops.operations)
            expect(result.error != nil, "hal-partial-error")
            let error = await result.resource!.close()
            expect(error == nil && !ops.running && !ops.allocated && ops.callback == nil, "hal-partial-owned-cleanup")
            expect(name == "start" || !ops.trace.contains("start"), "hal-no-partial-start")
        }
        for bad in 0..<6 {
            let ops = FakeHAL()
            if bad == 0 { ops.readbackMismatch = true }
            if bad == 1 { ops.unsupportedFormat = true }
            if bad == 2 { ops.physicalTransport = true }
            if bad == 3 { ops.wrongPlugin = true }
            if bad == 4 { ops.wrongChannels = true }
            if bad == 5 { ops.wrongUID = true }
            let result = await HALMicrophoneSink.prepare(grant: grant, render: MicrophoneRenderBuffer(grant: grant), ops: ops.operations)
            expect(result.error != nil && !ops.trace.contains("start"), bad == 0 ? "hal-no-default-fallback" : "hal-identity-format-refusal")
            _ = await result.resource!.close()
        }
        for boundary in ["stop", "deallocate", "release-provider"] {
            let ops = FakeHAL()
            let buffer = MicrophoneRenderBuffer(grant: grant); buffer.sendEnabled(Data(), to: NWConnection())
            let result = await HALMicrophoneSink.prepare(grant: grant, render: buffer, ops: ops.operations)
            ops.failAt = boundary
            let error = await result.resource!.close()
            let trace = ops.trace
            expect(error != nil && ops.callback != nil, "hal-cleanup-error-retained")
            expect(ops.render() == [0, 0, 0, 0], "hal-failed-cleanup-retained-silent")
            let repeated = await result.resource!.close()
            expect(repeated == error && trace == ops.trace, "hal-no-cleanup-retry")
            ops.failAt = nil
            let retried = await result.resource!.retryClose()
            expect(retried == nil && !ops.running && !ops.allocated && ops.callback == nil && ops.trace.filter { $0 == "start" }.count == 1, "hal-explicit-same-resource-retry")
        }
        await retainedBlockLifetime(grant)

        let checked = FakeHAL()
        let checkedBuffer = MicrophoneRenderBuffer(grant: grant)
        let checkedResult = await HALMicrophoneSink.prepare(grant: grant, render: checkedBuffer, ops: checked.operations)
        let readsBefore = checked.trace.filter { $0 == "read:\(kAudioDevicePropertyDeviceUID)" }.count
        for _ in 0..<16 { expect(checkedResult.resource!.runtimeValid(), "hal-cached-validation") }
        await settle()
        let readsAfter = checked.trace.filter { $0 == "read:\(kAudioDevicePropertyDeviceUID)" }.count
        expect(readsAfter - readsBefore == 2 && checked.offMain, "hal-one-inflight-validation")
        checked.wrongPlugin = true
        for _ in 0..<1000 {
            if !checkedResult.resource!.runtimeValid() { break }
            await Task.yield()
        }
        expect(!checkedResult.resource!.runtimeValid() && !checkedBuffer.isOpen, "hal-runtime-destination-revoked")
        _ = await checkedResult.resource!.close()
        await pausedValidation(grant)

        let refused = Fixture(delayed: true)
        let original = refused.start()
        await until({ refused.continuation != nil }, "prepare-error-entered")
        refused.continuation!.resume(returning: HostMicrophonePreparation(resource: refused.sink, error: "unit unsupported"))
        refused.continuation = nil
        await until({ refused.receiver.phase == .off }, "prepare-error-cleaned")
        expect(refused.states.last?.reason == "unit unsupported", "prepare-error-terminal-reason")
        refused.receiver.control(original, fingerprint: Data([1]))
        expect(refused.prepares == 1 && refused.states.last?.reason == "unit unsupported", "prepare-error-replay-reason")
    }

    @MainActor static func pausedValidation(_ grant: HostLocalOwnerGrant) async {
        let fake = FakeHAL()
        let render = MicrophoneRenderBuffer(grant: grant)
        render.sendEnabled(Data(), to: NWConnection())
        let result = await HALMicrophoneSink.prepare(grant: grant, render: render, ops: fake.operations)
        let held = fake.callback
        let pause = HALTestPause()
        fake.pauseNextRead = pause
        expect(result.resource!.runtimeValid(), "hal-paused-validation-start")
        let entered = await pause.waitForEntry()
        expect(entered, "hal-paused-validation-entered")
        for _ in 0..<16 { expect(result.resource!.runtimeValid(), "hal-paused-cached-validation") }
        var completed = false
        let close = Task { let error = await result.resource!.close(); completed = true; return error }
        await until({ !render.isOpen }, "hal-paused-close-admission")
        expect(!completed && fake.running, "hal-paused-worker-serial-close")
        expect(FakeHAL.render(held) == [0, 0, 0, 0], "hal-paused-close-silent")
        pause.release()
        let error = await close.value
        expect(error == nil && !result.resource!.runtimeValid() && !render.isOpen && !fake.running, "hal-late-validation-no-reopen")
    }

    @MainActor static func retainedBlockLifetime(_ grant: HostLocalOwnerGrant) async {
        let ops = FakeHAL()
        var buffer: MicrophoneRenderBuffer? = MicrophoneRenderBuffer(grant: grant)
        weak var observed = buffer
        var result: HostMicrophonePreparation? = await HALMicrophoneSink.prepare(grant: grant, render: buffer!, ops: ops.operations)
        expect(result?.error == nil, "hal-owned-block-prepared")
        var held = ops.callback
        _ = await result?.resource?.close()
        result = nil; buffer = nil
        await settle()
        expect(observed != nil, "hal-block-retains-render-storage")
        expect(FakeHAL.render(held) == [0, 0, 0, 0], "hal-retained-block-after-owner-release")
        held = nil
        await settle()
        expect(observed == nil, "hal-block-storage-released")
    }

    @MainActor static func integrationTests() async {
        let f = Fixture()
        let h = CoordinatorHarness(f.receiver)
        let connection = NWConnection()
        let paired = PairHarness(); h.remote = paired
        h.installTrustHook()
        paired.paired = [PairedFixture(fingerprint: "one", fingerprintData: Data([1]))]
        let peer = h.microphoneIngress.authorize(connection, fingerprint: Data([1]))!
        h.connections[ObjectIdentifier(connection)] = connection
        h.routes[ObjectIdentifier(connection)] = .home(.loopback, peer: ClientRoute.Peer(fingerprint: Data([1]), name: nil, cableDevice: nil))
        h.inputGeneration = f.binding.inputGeneration.uuidString
        h.videoEpoch = VideoEpoch(id: f.binding.videoEpoch, generation: h.inputGeneration, source: .desktop,
            geometry: .init(x: 0, y: 0, width: 2, height: 2), width: 2, height: 2)
        let binding = scope(peer: peer.id, generation: f.binding.inputGeneration, epoch: f.binding.videoEpoch,
                            destination: f.binding.destination, capability: f.binding.capability)
        f.owner.grant = ownerGrant(binding)
        expect(h.microphoneScopeIsCurrent(binding, fingerprint: Data([1])), "paired-principal-current")
        h.routes[ObjectIdentifier(connection)] = .home(.loopback, peer: nil)
        expect(!h.microphoneScopeIsCurrent(binding, fingerprint: Data([1])), "plain-peer-refused")
        h.routes[ObjectIdentifier(connection)] = .home(.loopback, peer: ClientRoute.Peer(fingerprint: Data([1]), name: "untrusted name", cableDevice: nil))
        paired.paired = []
        expect(!h.microphoneScopeIsCurrent(binding, fingerprint: Data([1])), "unpaired-tls-refused")
        paired.paired = [PairedFixture(fingerprint: "one", fingerprintData: Data([1]))]
        h.synthetic = true
        expect(!h.microphoneScopeIsCurrent(binding, fingerprint: Data([1])), "synthetic-refused")
        h.synthetic = false
        let cap = Wire.decode(WindowList.self, from: h.microphoneCatalog(to: connection).payload)?.microphone
        expect(cap?.peer == peer.id, "paired-capability-actual-path")
        let request = MicrophoneControl(operation: .start, requestID: UUID(), scope: binding)
        let reader = ReaderHarness(), client = ReaderHarness.Client(connection)
        client.route = h.routes[ObjectIdentifier(connection)]!
        reader.clients[ObjectIdentifier(connection)] = client
        var ordinary = 0, wakes = 0
        reader.onMessage = { _, _ in ordinary += 1 }
        h.microphoneIngress.schedule = { wakes += 1 }
        reader.onMicrophoneMessage = { message, connection in h.microphoneIngress.offer(message, from: connection, now: DispatchTime.now().uptimeNanoseconds) }
        let start = StreamMessage(kind: .microphoneControl, timestamp: 0, isKeyframe: false, payload: Wire.encode(request))
        for _ in 0..<8 {
            h.microphoneIngress.offer(start, from: connection, now: f.now)
        }
        let cancel = MicrophoneControl(operation: .stop, requestID: request.requestID, scope: binding)
        h.microphoneIngress.offer(StreamMessage(kind: .microphoneControl, timestamp: 0, isKeyframe: false, payload: Wire.encode(cancel)), from: connection, now: f.now)
        h.drainMicrophoneIngress(); await settle()
        h.microphoneIngress.offer(start, from: connection, now: f.now)
        h.drainMicrophoneIngress(); await settle()
        expect(f.prepares == 0, "full-ingress-cancel-pending-start")
        let liveRequest = MicrophoneControl(operation: .start, requestID: UUID(), scope: binding)
        let liveStart = StreamMessage(kind: .microphoneControl, timestamp: 0, isKeyframe: false, payload: Wire.encode(liveRequest))
        wakes = 0
        connection.inbound = [Data(liveStart.serialized().prefix(14)), liveStart.payload]
        reader.receiveLoop(client)
        h.drainMicrophoneIngress(); await settle()
        expect(f.prepares == 1 && ordinary == 0, "dispatch-bounded-before-task")
        let grantID = f.states.first(where: { $0.phase == .active })!.grantID!
        for seq in 1...4000 {
            h.microphoneIngress.offer(StreamMessage(kind: .microphoneFrame, timestamp: 0, isKeyframe: false,
                payload: packet(binding, grant: grantID, sequence: UInt64(seq)).encoded()), from: connection, now: f.now)
        }
        expect(wakes == 2, "ingress-one-wake")
        let batch = h.microphoneIngress.take()
        expect(batch.0.isEmpty && batch.1?.frame.sequence == 4000, "ingress-latest-only")
        expect(f.receiver.frame(batch.1!.frame, fingerprint: Data([1]), arrived: f.now), "actual-dispatch-frame")
        h.videoEpoch = VideoEpoch(generation: h.inputGeneration, source: .desktop,
            geometry: .init(x: 0, y: 0, width: 2, height: 2), width: 2, height: 2)
        expect(f.render?.isOpen == false, "same-source-epoch-revoke")
        await settle()
        expect(f.receiver.phase == .off, "epoch-cleanup")
        for _ in 0..<8 {
            let item = MicrophoneControl(operation: .stop, requestID: UUID(), scope: binding)
            h.microphoneIngress.offer(StreamMessage(kind: .microphoneControl, timestamp: 0, isKeyframe: false, payload: Wire.encode(item)), from: connection, now: f.now)
        }
        let overflow = MicrophoneControl(operation: .stop, requestID: UUID(), scope: binding)
        h.microphoneIngress.offer(StreamMessage(kind: .microphoneControl, timestamp: 0, isKeyframe: false, payload: Wire.encode(overflow)), from: connection, now: f.now)
        expect(h.microphoneIngress.peer(connection) == nil && connection.state == .cancelled, "full-cancel-quarantines-peer")
        h.drainMicrophoneIngress(); await settle()
        h.microphoneIngress.offer(liveStart, from: connection, now: f.now)
        h.drainMicrophoneIngress(); await settle()
        expect(f.prepares == 1, "quarantined-late-on-refused")
        let replacement = NWConnection()
        _ = h.microphoneIngress.authorize(replacement, fingerprint: Data([1]))
        let replacementPeer = h.microphoneIngress.peer(replacement)!
        let replacementScope = scope(peer: replacementPeer.id)
        let replacementRequest = MicrophoneControl(operation: .start, requestID: UUID(), scope: replacementScope)
        let removedBuffer = MicrophoneRenderBuffer(grant: ownerGrant(replacementScope))
        h.microphoneIngress.attach(replacementRequest, grantID: grantID, render: removedBuffer)
        let close = CloseHarness(); paired.server = close
        _ = paired.remove(fingerprint: "one")
        expect(!removedBuffer.isOpen && close.closes == 1, "pair-removal-immediate-named-revoke")
        expect(!paired.isPaired(Data([1])), "pair-removal-trust-updated")
        let disconnected = NWConnection()
        let disconnectedPeer = h.microphoneIngress.authorize(disconnected, fingerprint: Data([1]))!
        let disconnectedScope = scope(peer: disconnectedPeer.id)
        let disconnectBuffer = MicrophoneRenderBuffer(grant: ownerGrant(disconnectedScope))
        h.microphoneIngress.attach(MicrophoneControl(operation: .start, requestID: UUID(), scope: disconnectedScope), grantID: UUID(), render: disconnectBuffer)
        h.disconnect(disconnected)
        expect(!disconnectBuffer.isOpen && h.microphoneIngress.peer(disconnected) == nil, "original-disconnect-hook")
        let header = StreamMessage(kind: .microphoneFrame, timestamp: 0, isKeyframe: false, payload: Data(count: MicrophoneWire.frameLimit + 1))
        let tooBig = NWConnection(); tooBig.inbound = [Data(header.serialized().prefix(14))]
        reader.receiveLoop(ReaderHarness.Client(tooBig))
        expect(tooBig.state == .cancelled && tooBig.requests == [14], "reader-reject-before-allocation")
        let legacy = NWConnection(), legacyClient = ReaderHarness.Client(legacy)
        let ping = StreamMessage(kind: .ping, timestamp: 0, isKeyframe: false, payload: Data(count: 8))
        legacy.inbound = [Data(ping.serialized().prefix(14)), ping.payload]
        reader.receiveLoop(legacyClient)
        expect(legacy.sent.count == 1 && StreamMessage.parseHeader(legacy.sent[0])?.kind == .pong, "old-peer-ping-unchanged")
    }
}
