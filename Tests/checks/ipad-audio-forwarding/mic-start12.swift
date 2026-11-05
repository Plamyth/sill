import Foundation
import StreamProtocol

@main struct MicrophoneTimerChecks {
    static var checks = 0
    static func check(_ value: Bool, _ reason: String) {
        checks += 1
        precondition(value, reason)
    }
    @MainActor static func flush() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }
    @MainActor static func wait(until target: Double, since start: UInt64) async throws {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        if elapsed < target { try await Task.sleep(nanoseconds: UInt64((target - elapsed) * 1_000_000_000)) }
        await flush()
    }
    @MainActor static func arm(playback: Bool = false) throws -> (StreamClient, MicrophoneControl, WindowList) {
        let client = StreamClient(), peer = client.connection!
        client.desiredAudioSetConnection(peer)
        client.remoteAudioControl.setConnection(ObjectIdentifier(peer))
        client.applyMicrophone(client.microphonePolicy.setConnection(ObjectIdentifier(peer)))
        let generation = UUID()
        let epoch = VideoEpoch(generation:generation.uuidString,source:.desktop,
            geometry:.init(x:0,y:0,width:800,height:600),width:800,height:600)
        let list = WindowList(macName:"fixture",windows:[],active:.desktop,remoteAudio:1,
            inputGeneration:generation.uuidString,videoEpoch:epoch,
            microphone:.init(peer:UUID(),destination:UUID(),generation:UUID()),
            audioPrivacy:.init(version:2,protected:true))
        client.fixtureObserve(list)
        let observe = client.command()
        let device = AudioForwardingDeviceID(fingerprint:DeviceIdentity.existing()!.fingerprint)!
        let credential = try AudioForwardingCredential(pairedDeviceId:device,pairingGeneration:UUID(),credential:String(repeating:"A",count:43))
        let empty = try AudioForwardingSnapshot(revision:.init(1),intent:nil,binding:nil)
        let catalog = try AudioForwardingCatalog(principal:.init(kind:.cable,id:device,authorizationGeneration:credential.pairingGeneration),role:.viewer,
            bootstrap:.init(credential:credential,ownCursor:.init(intentRevision:.init(0),bindingRevision:.init(0)),snapshot:empty))
        client.receive(try .init(requestID:observe.requestID,operation:.observe,catalog:catalog,result:nil))
        client.setDesiredAudioSelection(.init(microphone:true,playback:playback))
        let request = client.command(), intent = request.intent!
        let snapshotIntent = try AudioForwardingSnapshot.Intent(pairedDeviceId:device,intentId:intent.intentId,intentRevision:intent.intentRevision,
            intentGeneration:UUID(),inputDesired:true,outputDesired:playback)
        let config = try AudioForwardingConfiguration(controllerBootId:UUID(),privacyGeneration:UUID(),registryRevision:.init(1),
            members:[.init(participantId:"native.sill",bootId:UUID()),.init(participantId:"s23.audio.relay",bootId:UUID())])
        let binding = AudioForwardingBinding(pairedDeviceId:device,intentGeneration:snapshotIntent.intentGeneration,bindingEpoch:UUID(),
            transportId:intent.transportId,transportKind:.native,operationId:request.requestID,phase:.active,configuration:config)
        client.receive(try .init(requestID:request.requestID,operation:.submit,catalog:nil,
            result:.accepted(.init(revision:.init(2),intent:snapshotIntent,binding:binding))))
        let start = peer.messages.filter { $0.first == 204 }.compactMap {
            Wire.decode(MicrophoneControl.self,from:Data($0.dropFirst(StreamMessage.headerLength)))
        }.first { $0.operation == .start }!
        check(client.microphonePolicy.phase == .requesting,"fixture reaches actual204 requesting without capture")
        return (client,start,list)
    }
    @MainActor static func answer(_ client: StreamClient, _ request: MicrophoneControl,
                                 phase: MicrophoneState.Phase, grant: UUID? = nil,
                                 from peer: NWConnection? = nil) async {
        let state = MicrophoneState(requestID:request.requestID,scope:request.scope,phase:phase,grantID:grant)
        let message = StreamMessage(kind:.microphoneState,timestamp:0,isKeyframe:false,payload:Wire.encode(state))
        _ = client.receiveMicrophone(StreamMessage.parseHeader(message.serialized().prefix(StreamMessage.headerLength))!,message.payload,from:peer ?? client.connection!)
        await flush()
    }
    @MainActor static func main() async throws {
        let began = DispatchTime.now().uptimeNanoseconds
        let (late,start,_) = try arm(playback:true)
        let (expired,expiredStart,_) = try arm()
        let (cancelled,cancelStart,_) = try arm()
        let (changed,changedStart,oldList) = try arm()
        let (replaced,replacedStart,_) = try arm()
        let booking = expired.microphoneTimers.first { $0.operation == .start }!
        check(booking.request == expiredStart.requestID && abs(booking.seconds - (CommandLine.arguments.contains("--expect-six") ? 6 : 12)) < 0.05,
              "actual send branch reserves the initial exact budget for its request")
        await answer(late,start,phase:.preparing)
        await answer(expired,expiredStart,phase:.preparing)
        try await wait(until:6.15,since:began)
        if CommandLine.arguments.contains("--expect-six") {
            check(late.microphonePolicy.phase == .failed("Mac 마이크가 응답하지 않았습니다."),"exact6 timer has fired")
            try await wait(until:7.524,since:began)
            await answer(late,start,phase:.active,grant:UUID())
            check(late.microphonePolicy.grantID == nil,"old6 rejects otherwise matching 7.524s grant")
            print("RED original6: actual timer expires before valid 7.524s grant")
            return
        }
        check(late.microphonePolicy.phase == .requesting,"microphone survives original6 deadline")
        check(expired.microphonePolicy.phase == .requesting,"repeated-preparing request survives original6 deadline")
        if case .failed = late.remoteAudioStatus { check(true,"playback6 expired") }
        else { preconditionFailure("playback6 must stay unchanged") }
        check(late.desiredAudio.selection == .init(microphone:true,playback:true) && late.audioForwarding.phase == .active,
              "playback6 failure does not stop fullDuplex binding or clear desires")
        check(late.connection!.messages.filter { $0.first == 204 }.count == 1,
              "playback6 never sends microphone stop")
        let disabled = late.connection!.messages.filter { $0.first == 200 }.compactMap {
            Wire.decode(RemoteAudioSubscription.self,from:Data($0.dropFirst(StreamMessage.headerLength)))
        }.contains { !$0.enabled }
        check(disabled,"playback6 emits its own disabled subscription")
        cancelled.cancelDesiredAudioRequest()
        await answer(cancelled,cancelStart,phase:.active,grant:UUID())
        check(cancelled.microphonePolicy.grantID == nil && !cancelled.desiredAudio.selection.microphone,
              "OFF before grant rejects late active")
        var newList = oldList
        let generation = UUID()
        newList.inputGeneration = generation.uuidString
        newList.videoEpoch = VideoEpoch(generation:generation.uuidString,source:.desktop,
            geometry:.init(x:0,y:0,width:800,height:600),width:800,height:600)
        changed.fixtureObserve(newList)
        await answer(changed,changedStart,phase:.active,grant:UUID())
        check(changed.microphonePolicy.grantID == nil && changed.microphonePolicy.scope != changedStart.scope,
              "generation and epoch replacement rejects old scope grant")
        let oldPeer = replaced.connection!
        replaced.connection = NWConnection()
        replaced.desiredAudioSetConnection(replaced.connection)
        replaced.applyMicrophone(replaced.microphonePolicy.setConnection(replaced.connection.map(ObjectIdentifier.init)))
        await answer(replaced,replacedStart,phase:.active,grant:UUID(),from:oldPeer)
        check(replaced.microphonePolicy.grantID == nil,"replaced connection rejects old peer grant")
        await answer(expired,expiredStart,phase:.preparing)
        check(expired.microphonePolicy.phase == .requesting,"preparing at6.15 keeps request pending")
        try await wait(until:7.524,since:began)
        var wrongScope = start.scope
        wrongScope = .init(peer:wrongScope.peer,source:wrongScope.source,inputGeneration:UUID(),videoEpoch:wrongScope.videoEpoch,
            destination:wrongScope.destination,capability:wrongScope.capability)
        await answer(late,.init(operation:.start,requestID:UUID(),scope:start.scope),phase:.active,grant:UUID())
        await answer(late,.init(operation:.start,requestID:start.requestID,scope:wrongScope),phase:.active,grant:UUID())
        check(late.microphonePolicy.phase == .requesting && late.microphonePolicy.grantID == nil,
              "wrong request and scope cannot use longer budget")
        let grant = UUID()
        await answer(late,start,phase:.active,grant:grant)
        check(late.microphonePolicy.phase == .capturing && late.microphonePolicy.grantID == grant,
              "matching 7.524s active reaches capture effect")
        try await wait(until:9,since:began)
        await answer(expired,expiredStart,phase:.preparing)
        check(expired.microphonePolicy.phase == .requesting,"repeated preparing before first12 phase=\(expired.microphonePolicy.phase) forwarding=\(expired.audioForwarding.phase)")
        check(expired.microphoneTimers.filter { $0.operation == .start }.count == 1,
              "preparing never reschedules or extends the first12 timer")
        try await wait(until:12.2,since:began)
        check(expired.microphonePolicy.phase == .failed("Mac 마이크가 응답하지 않았습니다."),
              "first12 expires despite repeated preparing")
        let stops = expired.connection!.messages.filter { $0.first == 204 }.compactMap {
            Wire.decode(MicrophoneControl.self,from:Data($0.dropFirst(StreamMessage.headerLength)))
        }.filter { $0.operation == .stop }
        check(stops.count == 1 && stops[0].requestID == expiredStart.requestID && stops[0].scope == expiredStart.scope && stops[0].grantID == nil,
              "timeout cancels only original request and scope with nil grant")
        await answer(expired,expiredStart,phase:.active,grant:UUID())
        check(expired.microphonePolicy.grantID == nil,"after12 active cannot revive timed-out request")
        check(late.microphonePolicy.phase == .capturing && late.microphonePolicy.grantID == grant,
              "valid earlier active is unaffected by old start timer")
        print("GREEN microphone12 actual DispatchQueue timers and adapter: \(checks) checks passed; no device/media/network")
    }
}
