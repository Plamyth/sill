import Foundation
import StreamProtocol

@MainActor final class FreshnessFixture {
    let registry=LocalAudioParticipantRegistry(), child=Process()
    let folder:URL
    let privacy:HostAudioPrivacy
    let relay:LocalAudioRelay
    let runtime:HostAudioForwardingRuntime
    let peer=AudioForwardingPairedDevice(id:AudioForwardingDeviceID(hex:String(repeating:"ab",count:32))!,pairingGeneration:UUID())
    let connection=UUID()
    var live=true
    init(_ folder:URL) throws {
        self.folder=folder
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("{}".utf8).write(to:folder.appendingPathComponent("control.json"))
        privacy=HostAudioPrivacy(registry)
        child.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        child.arguments=[CommandLine.arguments[1],folder.appendingPathComponent("control.json").path,folder.appendingPathComponent("events.jsonl").path]
        relay=LocalAudioRelay(participants:registry,process:child,packagedRuntime:.init(python:"inert-python",router:"inert-router",port:0),forwarding:true,validateLaunch:{true})
        runtime=HostAudioForwardingRuntime(relay:relay,privacy:privacy,fenceMedia:{},commitMedia:{_ in})
        registry.register(.native,bootId:UUID(),control:.init(fenceAndQuiesce:{.init($0,state:.unknown,facts:.unknown)},inspect:{_ in nil},supportsForwarding:true,forwardingPrepare:{.init($0.request,state:.quiescent,facts:.init(admissionFenced:true,startsSettled:true,mediaDetached:true,callbacksDrained:true,buffersEmpty:true,workersExited:true))}))
    }
    var context:AudioForwardingConnectionContext {
        .init(peer:peer,principal:.init(kind:.localNetwork,id:peer.id,authorizationGeneration:peer.pairingGeneration),role:.viewer,connectionID:connection,connectionIsCurrent:{[weak self] in self?.live == true},isCurrent:{[weak self] in self?.live == true})
    }
    func options(_ value:[String:Any]) throws {try JSONSerialization.data(withJSONObject:value).write(to:folder.appendingPathComponent("control.json"),options:.atomic)}
    func methods()->[String] {
        ((try? String(contentsOf:folder.appendingPathComponent("events.jsonl"),encoding:.utf8)) ?? "").split(separator:"\n").compactMap { line in
            guard let object=try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],object["event"] as? String == "request" else{return nil}
            return object["method"] as? String
        }
    }
    func observe() async -> AudioForwardingState? {await runtime.exchange(try! .init(requestID:UUID(),operation:.observe,intent:nil),context:context)}
    func finish() {
        runtime.stop()
        if child.isRunning {child.terminate()}
        child.waitUntilExit()
        precondition(!child.isRunning)
    }
}
@main struct FreshnessChecks {
    @MainActor static var checks=0,failures=0
    @MainActor static func expect(_ value:Bool,_ message:String){checks += 1;if !value{failures += 1};Swift.print("\(value ? "PASS" : "FAIL") \(message)")}
    @MainActor static func wait(_ condition:()->Bool) async {
        let end=ContinuousClock.now.advanced(by:.seconds(5))
        while !condition(),ContinuousClock.now < end {try? await Task.sleep(for:.milliseconds(1))}
        precondition(condition(),"private fixture barrier")
    }
    @MainActor static func main() async throws {
        let f=try FreshnessFixture(URL(fileURLWithPath:CommandLine.arguments[2]))
        HostLog.shared.configure(keepLines:128,fileURL:nil)
        expect(await f.runtime.start(),"inert runtime starts through real bootstrap/configuration validation")
        let initial=await f.observe()
        expect(initial?.catalog != nil,"initial connection is enrolled through existing path")
        await wait {!f.relay.checkPending && f.relay.checkWaiting == 0}
        f.runtime.checkPausePolling()
        try f.options(["delayMs":550,"splitMs":10])
        let before=f.methods().count
        let blocker=Task {await f.relay.checkedCall("hold",until:.now.advanced(by:.seconds(3)))}
        await wait {f.relay.checkPending}
        let start=ContinuousClock.now
        let reply=await f.observe()
        let elapsed=start.duration(to:.now);let c=elapsed.components
        let milliseconds=Double(c.seconds)*1000+Double(c.attoseconds)/1e15
        _=await blocker.value
        let methods=Array(f.methods().dropFirst(before))
        Swift.print("FRESHNESS elapsedMs=\(milliseconds) responsePresent=\(reply != nil) methods=\(methods)")
        expect(reply?.catalog?.principal.id == f.peer.id,"fresh observe keeps authenticated device correlation")
        expect((reply?.catalog?.bootstrap.snapshot.revision.value ?? 0) > (initial?.catalog?.bootstrap.snapshot.revision.value ?? 0),"reply comes from a newly validated snapshot rather than cached freshness")
        expect(milliseconds < 2000,"valid observe returns inside unchanged 2s refresh margin; elapsedMs=\(milliseconds)")
        expect(methods == ["hold","forwardingBootstrap"],"existing connection reads fresh authoritative bootstrap without repeated configure/attach")
        for line in HostLog.shared.lines(after:0) where line.text.contains("audio.trace relayRPC") {Swift.print("FIXTURE_RPC \(line.text)")}
        try f.options([:])
        var cursor=f.methods().count
        f.privacy.forwardingPrivacyGeneration=UUID()
        expect(await f.observe()?.catalog != nil,"changed privacy configuration is revalidated")
        expect(Array(f.methods().dropFirst(cursor)) == ["forwardingConfigure","forwardingBootstrap","forwardingEvidence"],"configuration change uses full configure/bootstrap/attach path")
        cursor=f.methods().count
        try f.options(["rotateCredential":true])
        let rotated=await f.observe()
        expect(rotated?.catalog?.bootstrap.credential.credential == String(repeating:"b",count:43),"credential rotation is not hidden by the resident session")
        expect(Array(f.methods().dropFirst(cursor)) == ["forwardingBootstrap","forwardingConfigure","forwardingBootstrap","forwardingEvidence"],"changed credential is enrolled before being returned")
        cursor=f.methods().count
        expect(await f.observe()?.catalog != nil && Array(f.methods().dropFirst(cursor)) == ["forwardingBootstrap"],"validated rotated session can observe without another attach")
        let replacementPair=UUID()
        let repaired=AudioForwardingConnectionContext(peer:.init(id:f.peer.id,pairingGeneration:replacementPair),principal:.init(kind:.localNetwork,id:f.peer.id,authorizationGeneration:replacementPair),role:.viewer,connectionID:f.connection,connectionIsCurrent:{true},isCurrent:{true})
        cursor=f.methods().count
        let repairedReply=await f.runtime.exchange(try .init(requestID:UUID(),operation:.observe,intent:nil),context:repaired)
        expect(repairedReply?.catalog?.principal.authorizationGeneration == replacementPair,"new pairing generation is validated instead of reusing old identity")
        expect(Array(f.methods().dropFirst(cursor)) == ["forwardingConfigure","forwardingBootstrap","forwardingEvidence"],"pairing change uses complete enrollment")
        try f.options([:]);_=await f.observe()
        try f.options(["delayMs":300])
        cursor=f.methods().count
        let authorityBlocker=Task {await f.relay.checkedCall("hold",until:.now.advanced(by:.seconds(3)))}
        await wait {f.relay.checkPending}
        let revoked=Task {await f.observe()}
        await wait {f.relay.checkWaiting > 0}
        f.live=false
        expect(await revoked.value == nil,"authority loss while queued still rejects before send")
        _=await authorityBlocker.value
        expect(Array(f.methods().dropFirst(cursor)) == ["hold"] && f.relay.checkConnected,"authority failure consumes no sequence and does not close an unrelated pending RPC")
        f.live=true
        cursor=f.methods().count
        let cancellationBlocker=Task {await f.relay.checkedCall("hold",until:.now.advanced(by:.seconds(3)))}
        await wait {f.relay.checkPending}
        let cancelled=Task {await f.observe()}
        await wait {f.relay.checkWaiting > 0};cancelled.cancel()
        expect(await cancelled.value == nil,"queued observation cancellation is retained")
        _=await cancellationBlocker.value
        expect(Array(f.methods().dropFirst(cursor)) == ["hold"] && f.relay.checkConnected,"cancelled observe does not transmit or cancel another RPC")
        cursor=f.methods().count
        let evidenceBlocker=Task {await f.relay.checkedCall("hold",until:.now.advanced(by:.seconds(3)))}
        await wait {f.relay.checkPending}
        let invalidated=Task {await f.observe()}
        await wait {f.relay.checkWaiting > 0}
        f.runtime.evidenceWillChange()
        expect(await invalidated.value == nil,"evidence generation change invalidates a queued observation")
        _=await evidenceBlocker.value
        expect(Array(f.methods().dropFirst(cursor)) == ["hold"] && f.relay.checkConnected,"invalidated evidence is rejected before dispatch without closing another RPC")
        cursor=f.methods().count
        let inFlight=Task {await f.observe()}
        await wait {f.relay.checkPending}
        f.privacy.forwardingPrivacyGeneration=UUID()
        expect(await inFlight.value == nil,"configuration changed after dispatch cannot publish an old response")
        expect(Array(f.methods().dropFirst(cursor)) == ["forwardingBootstrap"],"post-dispatch invalidation does not retry automatically")
        try f.options([:])
        _=await f.observe()
        let silent=f.methods().count
        f.live=false
        expect(await f.observe() == nil && f.methods().count == silent,"stale TLS/owner is rejected without sending")
        f.live=true;f.privacy.forwardingIntentAllowed=false
        expect(await f.observe() == nil && f.methods().count == silent,"privacy admission is not relaxed")
        f.privacy.forwardingIntentAllowed=true
        try f.options(["wrongDevice":true])
        expect(await f.observe() == nil,"wrong authenticated bootstrap device fails closed")
        f.finish()
        let periodic=try FreshnessFixture(URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent("periodic"))
        expect(await periodic.runtime.start(),"periodic renewal fixture starts")
        _=await periodic.observe()
        await wait {!periodic.relay.checkPending && periodic.relay.checkWaiting == 0}
        try periodic.options(["delayMs":550,"splitMs":10])
        cursor=periodic.methods().count
        await wait {periodic.relay.checkPending}
        let periodicStart=ContinuousClock.now
        let periodicReply=await periodic.observe()
        let periodicDuration=periodicStart.duration(to:.now).components
        let periodicMs=Double(periodicDuration.seconds)*1000+Double(periodicDuration.attoseconds)/1e15
        let periodicMethods=Array(periodic.methods().dropFirst(cursor))
        expect(periodicReply?.catalog != nil && periodicMs < 2000,"observe completes within refresh margin while real periodic renewal runs; elapsedMs=\(periodicMs)")
        expect(periodicMethods.first == "forwardingEvidence" && periodicMethods.contains("forwardingBootstrap") && !periodicMethods.contains("forwardingConfigure"),"periodic renewal remains active without repeated connection enrollment")
        periodic.finish()
        let deadline=try FreshnessFixture(URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent("deadline"))
        expect(await deadline.runtime.start(),"deadline fixture starts")
        _=await deadline.observe();await wait {!deadline.relay.checkPending && deadline.relay.checkWaiting == 0};deadline.runtime.checkPausePolling()
        try deadline.options(["delayMs":3200])
        let deadlineStart=ContinuousClock.now
        expect(await deadline.observe() == nil && deadline.relay.checkClosed,"existing 3s response deadline still closes a stale relay")
        let duration=deadlineStart.duration(to:.now).components
        let deadlineMs=Double(duration.seconds)*1000+Double(duration.attoseconds)/1e15
        expect(deadlineMs >= 2900 && deadlineMs < 3200,"deadline remains 3s, not a blanket timeout increase; elapsedMs=\(deadlineMs)")
        deadline.finish()
        Swift.print("FRESHNESS checks=\(checks) failures=\(failures) actualHostCoreAudioDeviceEffects=0")
        exit(failures == 0 ? 0 : 1)
    }
}
