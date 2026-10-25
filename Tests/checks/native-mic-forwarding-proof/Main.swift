import CoreAudio
import Foundation
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
    init() {
        hal.safe()
        startup.construct { () }
        privacy = HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: hal.operations), nativeStartup: startup)
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

@main
struct Main {
    @MainActor static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
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
        print("RESULT_FAILURES \(failures)")
        if failures != 0 { exit(1) }
    }
}
