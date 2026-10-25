import CoreAudio
import Foundation
import Network
import StreamProtocol

@MainActor
final class Fixture {
    let hal = PrivacyFakeHAL()
    let startup = NativeAudioStartup()
    var privacy: HostAudioPrivacy!
    var owner: SillVirtualMicrophoneOwner!
    let peer = UUID(), input = UUID(), video = UUID(), fingerprint = Data([1, 2, 3])
    var registry: LocalAudioParticipantRegistry { startup.participants }
    let facts = LocalAudioParticipantFacts(admissionFenced: true, startsSettled: true, mediaDetached: true,
                                         callbacksDrained: true, buffersEmpty: true, workersExited: true)
    var relayRequest: LocalAudioParticipantRequest?
    var auth: (() async -> Bool)?
    init() {
        hal.safe()
        startup.construct { () }
        privacy = HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: hal.operations),
            authenticateLocal: { [unowned self] _ in await auth?() ?? false }, nativeStartup: startup)
        privacy.revokeForLocalReturn = { true }
        privacy.inspectForLocalReturn = { [unowned self] in facts }
        registerRelay()
        precondition(privacy.armAndVerify() && privacy.verify() && hal.writes.isEmpty)
        owner = SillVirtualMicrophoneOwner(ops: hal.microphoneOperations, privacy: privacy)
    }
    func registerRelay() {
        registry.register(.relay, bootId: UUID(), control: .init(fenceAndQuiesce: { [unowned self] request in
            relayRequest = request; return .init(request, state: .quiescent, facts: facts)
        }, inspect: { [unowned self] id in
            guard let request = relayRequest, request.operationId == id else { return nil }
            return .init(request, state: .quiescent, facts: facts)
        }, supportsForwarding: true, forwardingPrepare: { [unowned self] preparation in
            relayRequest = preparation.request; return .init(preparation.request, state: .quiescent, facts: facts)
        }))
    }
    func forward() async {
        let membership = registry.snapshot, generation = privacy.forwardingPrivacyGeneration, operation = UUID()
        let ticket = registry.beginForwarding(epoch: UUID(), intentGeneration: input, operationId: operation,
            privacyGeneration: generation, membership: membership,
            identity: [peer.uuidString, input.uuidString, video.uuidString, "native"])!
        for id in LocalAudioParticipantID.allCases {
            let request = LocalAudioParticipantRequest(schemaVersion: 1, operationId: operation,
                privacyGeneration: generation, registryRevision: String(membership.revision),
                participantId: id, bootId: membership.boots[id]!, budgetMilliseconds: 1000)
            let receipt = await registry.prepareForwarding(ticket, request: request,
                until: ContinuousClock.now.advanced(by: .seconds(1)))
            precondition(receipt?.proves(request) == true)
        }
        precondition(registry.isFenced && !privacy.verify() && privacy.forwardingHealth())
    }
    func grant() -> HostLocalOwnerGrant? {
        owner.microphoneGrant(peer: peer, source: .desktop, inputGeneration: input, videoEpoch: video, fingerprint: fingerprint)
    }
    func close() { owner.restoreMicrophoneForExit(); privacy.stop() }
}

final class PrepareGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false, released = false
    var isEntered: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func wait() {
        condition.lock(); entered = true; condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

@main
struct Main {
    static func callback(_ render: MicrophoneRenderBuffer) -> [Int16] {
        let samples = UnsafeMutablePointer<Int16>.allocate(capacity: 4)
        samples.initialize(repeating: 123, count: 4)
        defer { samples.deinitialize(count: 4); samples.deallocate() }
        var buffers = AudioBufferList(mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 8, mData: samples))
        _ = HALMicrophoneContext(render: render, channels: 2, channel: 0).fill(frames: 2, buffers: &buffers)
        return Array(UnsafeBufferPointer(start: samples, count: 4))
    }
    @MainActor static func main() async {
        var failures = 0, assertions = 0
        func check(_ condition: Bool, _ label: String) {
            assertions += 1
            print((condition ? "PASS " : "FAIL ") + label)
            if !condition { failures += 1 }
        }
        let f = Fixture()
        check(f.grant() != nil, "정상 local 보호에서는 grant 발급")
        await f.forward()
        let proof = f.privacy.forwardingProof()!
        check(f.privacy.forwardingProofCurrent(proof), "실제 모델의 forwarding proof가 현재 세대·멤버와 일치")
        let forwarded = f.grant()
        check(forwarded != nil, "fenced-forwarding은 정상 proof인데 native microphone grant가 nil이면 충돌")
        if let forwarded {
            let prepared = await f.owner.prepareMicrophone(grant: forwarded, render: MicrophoneRenderBuffer(grant: forwarded))
            check(prepared.error == nil && prepared.resource?.runtimeValid() == true, "동일 forwarding proof로 prepare·lease 통과")
            _ = await prepared.resource?.close()
        }
        check(f.registry.isFenced && !f.privacy.verify(), "native 마이크 허용이 일반 admission fence를 열지 않음")
        check(f.hal.writes.isEmpty, "inert HAL에서도 기본값 추가 변경 0")
        f.close()
        // The actual caller guard still owns transport authentication and native binding.
        let boundary = BindingBoundary(), connection = NWConnection()
        boundary.routes[ObjectIdentifier(connection)] = .init(fingerprint: Data([1]))
        boundary.nativeAudioBindingAuthorized = { fingerprint, direction in fingerprint == Data([1]) && direction == .input }
        check(boundary.nativeAudioBindingReady(connection, direction: .input), "생산 caller guard의 인증된 native input 허용")
        check(!boundary.nativeAudioBindingReady(connection), "input binding으로 output을 허용하지 않음")
        boundary.authenticated = false
        check(!boundary.nativeAudioBindingReady(connection, direction: .input), "인증 실패 거절")
        boundary.authenticated = true
        boundary.routes[ObjectIdentifier(connection)] = .init(fingerprint: Data([2]))
        check(!boundary.nativeAudioBindingReady(connection, direction: .input), "다른 fingerprint 거절")
        boundary.routes.removeAll()
        check(!boundary.nativeAudioBindingReady(connection, direction: .input), "없는 route 거절")

        for change in ["membership", "generation", "HAL default", "UID", "plugin", "physical transport", "auth"] {
            let f = Fixture(); await f.forward()
            guard let grant = f.grant() else { check(false, "회귀 fixture forwarding grant"); f.close(); continue }
            let render = MicrophoneRenderBuffer(grant: grant)
            let prepared = await f.owner.prepareMicrophone(grant: grant, render: render)
            check(prepared.error == nil && prepared.resource?.runtimeValid() == true, change + " 전 lease 유효")
            let frame = MicrophoneFrame(scope: grant.scope, grantID: UUID(), sequence: 1, frameCount: 2, pcm: Data([7, 0, 8, 0]))!
            let now = DispatchTime.now().uptimeNanoseconds
            check(render.sendEnabled(Data(), to: NWConnection()) && render.offer(frame, arrived: now, now: now), change + " 전 inert PCM 적재")
            var authTask: Task<Bool, Never>?
            var authContinuation: CheckedContinuation<Bool, Never>?
            switch change {
            case "membership": f.registerRelay()
            case "generation": _ = f.privacy.armAndVerify()
            case "HAL default": f.hal.snapshot.input = 10
            case "UID": f.hal.wrongResolution = true
            case "plugin": f.hal.wrongPlugin = true
            case "physical transport":
                let old = f.hal.snapshot.devices[1]
                f.hal.snapshot.devices[1] = .init(id: old.id, uid: old.uid, transport: .builtIn, plugin: old.plugin,
                    inputChannels: 2, outputChannels: 2, inputMuted: true, outputMuted: true)
            default:
                f.auth = { await withCheckedContinuation { authContinuation = $0 } }
                authTask = Task { await f.privacy.requestLocalReturn() }
                while authContinuation == nil { await Task.yield() }
            }
            check(prepared.resource?.runtimeValid() == false && !grant.valid(at: DispatchTime.now().uptimeNanoseconds), change + " 뒤 proof·grant 취소")
            var writes = 0
            render.render(frames: 2, now: DispatchTime.now().uptimeNanoseconds) { _, _ in writes += 1 }
            check(writes == 0, change + " 뒤 늦은 render가 PCM을 쓰지 않음")
            check(callback(render) == [0, 0, 0, 0], change + " 뒤 생산 HAL callback은 silence만 기록")
            let stale = await f.owner.prepareMicrophone(grant: grant, render: render)
            check(stale.resource == nil && stale.error != nil, change + " 뒤 오래된 grant 재사용 거절")
            authContinuation?.resume(returning: false)
            if let authTask { let returned = await authTask.value; check(!returned, "인증 거절로 복귀 수용하지 않음") }
            _ = await prepared.resource?.close()
            check(f.hal.writes.isEmpty, change + " 검사에서 물리 fallback setter 0")
            f.close()
        }
        for change in ["native binding", "fingerprint", "source", "input", "video"] {
            let f = Fixture(); await f.forward()
            let boundary = BindingBoundary(), connection = NWConnection()
            boundary.routes[ObjectIdentifier(connection)] = .init(fingerprint: f.fingerprint)
            var binding = true, source = StreamSource.desktop, input = f.input, video = f.video
            var fingerprint = f.fingerprint
            boundary.nativeAudioBindingAuthorized = { _, direction in binding && direction == .input }
            let receiver = HostMicrophoneReceiver(provider: f.owner, automaticWatchdog: false)
            receiver.current = { scope, observed in
                boundary.nativeAudioBindingReady(connection, direction: .input) && observed == fingerprint &&
                scope.peer == f.peer && scope.source == source && scope.inputGeneration == input && scope.videoEpoch == video
            }
            var render: MicrophoneRenderBuffer?
            receiver.onRenderGate = { _, _, buffer in render = buffer }
            receiver.sendState = { state, buffer in
                if state.phase == .active { _ = buffer?.sendEnabled(Data(), to: connection) }
            }
            let capability = receiver.capability(peer: f.peer, source: .desktop, inputGeneration: f.input,
                videoEpoch: f.video, fingerprint: f.fingerprint)
            check(capability != nil, change + " 前 caller·생산 receiver capability 발급")
            if let grant = receiver.advertisedGrant(peer: f.peer) {
                receiver.control(.init(operation: .start, requestID: UUID(), scope: grant.scope), fingerprint: f.fingerprint)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while receiver.phase == .preparing && ContinuousClock.now < deadline { await Task.yield() }
                check(receiver.phase == .active && render?.isAdmitted == true, change + " 前 inert receiver active")
                switch change {
                case "native binding": binding = false
                case "fingerprint": fingerprint = Data([9])
                case "source": source = .window(18)
                case "input": input = UUID()
                default: video = UUID()
                }
                receiver.checkWatchdog()
                check(render?.isOpen == false && render.map { callback($0) == [0, 0, 0, 0] } == true,
                      change + " 뒤 현재 caller guard·receiver가 late callback 차단")
                let retired = await receiver.waitForRetirement()
                check(retired, change + " 뒤 실제 receiver 정리 완료")
            }
            receiver.forgetCapabilities(); f.close()
        }
        // Proof changes across the worker await must reject the late prepared resource.
        do {
            let f = Fixture(); await f.forward()
            let gate = PrepareGate(), base = f.hal.microphoneOperations
            var ops = base
            ops.create = { gate.wait(); return try base.create() }
            let owner = SillVirtualMicrophoneOwner(ops: ops, privacy: f.privacy)
            if let grant = owner.microphoneGrant(peer: f.peer, source: .desktop, inputGeneration: f.input,
                                                  videoEpoch: f.video, fingerprint: f.fingerprint) {
                let render = MicrophoneRenderBuffer(grant: grant)
                let preparation = Task { await owner.prepareMicrophone(grant: grant, render: render) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while !gate.isEntered && ContinuousClock.now < deadline { await Task.yield() }
                check(gate.isEntered, "생산 HAL prepare의 await 중간 경계 도달")
                f.registerRelay(); gate.release()
                let result = await preparation.value
                check(result.error != nil && result.resource?.runtimeValid() == false && !render.isOpen,
                      "await 중 membership 교체 후 late prepare 수용 거절")
                _ = await result.resource?.close()
            } else { gate.release(); check(false, "late prepare fixture grant") }
            owner.restoreMicrophoneForExit(); f.close()
        }
        // Exact grant identity retains source/input/video/fingerprint ownership.
        for field in ["source", "input", "video", "fingerprint"] {
            let f = Fixture(); await f.forward()
            if let old = f.grant() {
                let next = f.owner.microphoneGrant(peer: f.peer, source: field == "source" ? .window(17) : .desktop,
                    inputGeneration: field == "input" ? UUID() : f.input,
                    videoEpoch: field == "video" ? UUID() : f.video,
                    fingerprint: field == "fingerprint" ? Data([4]) : f.fingerprint)
                check(next != nil && next !== old && !old.valid(at: DispatchTime.now().uptimeNanoseconds), field + " 교체는 이전 scope grant 취소")
                let stale = await f.owner.prepareMicrophone(grant: old, render: MicrophoneRenderBuffer(grant: old))
                check(stale.resource == nil, field + " 교체 뒤 이전 prepare 거절")
            } else { check(false, field + " fixture grant") }
            f.close()
        }
        do {
            let f = Fixture(); await f.forward()
            check(f.owner.microphoneGrant(peer: f.peer, source: .none, inputGeneration: f.input, videoEpoch: f.video, fingerprint: f.fingerprint) == nil,
                  "source 없음 거절")
            check(f.owner.microphoneGrant(peer: f.peer, source: .desktop, inputGeneration: f.input, videoEpoch: f.video, fingerprint: Data()) == nil,
                  "빈 fingerprint 거절")
            if let grant = f.grant() {
                let first = await f.owner.prepareMicrophone(grant: grant, render: MicrophoneRenderBuffer(grant: grant))
                let busy = await f.owner.prepareMicrophone(grant: grant, render: MicrophoneRenderBuffer(grant: grant))
                check(first.error == nil && busy.resource == nil, "활성 lease의 중복 취득 거절")
                f.owner.restoreMicrophoneForExit()
                if let next = f.grant() {
                    let second = await f.owner.prepareMicrophone(grant: next, render: MicrophoneRenderBuffer(grant: next))
                    _ = await first.resource?.close()
                    check(second.resource?.runtimeValid() == true, "이전 lease 늦은 close가 새 lease를 해제하지 않음")
                    _ = await second.resource?.close()
                } else { check(false, "exit 뒤 새 grant") }
            }
            f.close()
        }
        print("RESULT_ASSERTIONS \(assertions)")
        print("RESULT_FAILURES \(failures)")
        if failures != 0 { exit(1) }
    }
}
