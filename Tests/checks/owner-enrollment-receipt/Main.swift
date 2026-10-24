import Foundation
import Security
import StreamProtocol
@testable import SillHostCore

private var checks = 0
private func expect(_ condition: Bool, _ label: String, line: UInt = #line) {
    checks += 1
    guard condition else { fatalError("\(line): \(label)") }
}
private func rejects(_ label: String, _ body: () throws -> Void) {
    do { try body(); fatalError(label) } catch { checks += 1 }
}

private final class Store: IdentityStore {
    let memory = MemoryIdentityStore()
    var writes = 0
    var registryReads = 0
    var pairedReads = 0
    var failRead = false
    var onRegistryRead: ((Int) throws -> Void)?
    var summary: String { "격리 메모리" }
    var testDirectory: URL? { nil }
    func loadOrCreateKey() throws -> SecKey { try memory.loadOrCreateKey() }
    func loadOrCreateRecognitionKey() throws -> Data { try memory.loadOrCreateRecognitionKey() }
    func loadPaired() throws -> [PairedDevice] { pairedReads += 1; return try memory.loadPaired() }
    func savePaired(_ devices: [PairedDevice]) throws { writes += 1; try memory.savePaired(devices) }
    func loadOwnerRegistry() throws -> Data? {
        registryReads += 1
        if failRead { throw IdentityStoreError("격리 읽기 실패") }
        try onRegistryRead?(registryReads)
        return try memory.loadOwnerRegistry()
    }
    func saveOwnerRegistry(_ record: Data) throws { writes += 1; try memory.saveOwnerRegistry(record) }
    func loadRequirePairing() throws -> Data? { try memory.loadRequirePairing() }
    func saveRequirePairing(_ record: Data) throws { writes += 1; try memory.saveRequirePairing(record) }
}

private final class Sensor: @unchecked Sendable {
    var user = 7
    var node = "peer-node"
    var expiry: String?
    var beforeRead: (() -> Void)?
    func make() -> TailnetDeviceAccess {
        TailnetDeviceAccess(testingRead: { [self] command, check in
            try check(); beforeRead?()
            switch command {
            case .status:
                return try JSONSerialization.data(withJSONObject: ["BackendState":"Running", "Self":
                    ["ID":"host-node", "UserID":7, "TailscaleIPs":["100.64.0.1"], "Expired":false]])
            case .whois:
                var peer: [String:Any] = ["StableID":node,"User":user,"MachineAuthorized":true,
                    "Addresses":["100.64.0.2/32"],"Expired":false]
                peer["KeyExpiry"] = expiry
                return try JSONSerialization.data(withJSONObject:["Node":peer,"UserProfile":["ID":user]])
            }
        })
    }
}

@MainActor private final class Fixture {
    let store = Store()
    let sensor = Sensor()
    let remote: RemoteAccess
    let deviceSPKI: Data
    let fp: String
    let principal = OwnerBootstrapRegistry.principal(user: 7, node: "peer-node")
    var identity: HostIdentity { remote.identity! }
    init() throws {
        let key = try MemoryIdentityStore().loadOrCreateKey()
        let point = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data
        deviceSPKI = SPKI.der(point: point)
        fp = try MobileEnrollment.Fingerprint(spkiDER: deviceSPKI).base64URL
        remote = RemoteAccess(store: store)
        remote.configureOwnerBootstrapForTesting(sensor: sensor.make(), enabled: true)
    }
    func register(state: OwnerBootstrapRegistry.Binding.State = .active, method: String = OwnerMacBootstrap.method,
                  pending: Bool? = nil) throws {
        var registry = OwnerBootstrapRegistry(macID: identity.macID)
        registry.bindings = [.init(principal: principal, fingerprint: fp, state: state)]
        try registry.save(store: store, identity: identity)
        try store.savePaired([PairedDevice(fingerprint: fp, name: "격리 기기", model: nil, pairedAt: 10,
            method: method, ownerPrincipal: method == OwnerMacBootstrap.method ? principal : nil,
            ownerActivationPending: pending)])
    }
    func socket(current: @escaping () -> Bool = { true }, deadline: UInt64? = nil,
                fingerprint: String? = nil, purpose: OwnerBootstrapSocket.Purpose = .bootstrap) -> OwnerBootstrapSocket {
        let b = OwnerBootstrapSocket.Binding(generation: UUID(), fingerprint: Base64URL.decode(fingerprint ?? fp)!,
            sourceIP:"100.64.0.2", localIP:"100.64.0.1", interface:"utun9")
        return .fixture(binding:b, trust:remote.trust, purpose:purpose,
            deadline:deadline ?? DispatchTime.now().uptimeNanoseconds + 10_000_000_000, current:current)
    }
    func request(expires: Int64? = nil, publicKey: Data? = nil, nonce: UInt8 = 3) throws -> PairRequest {
        let key = publicKey ?? deviceSPKI
        let challenge = try MobileEnrollment.InitialChallenge(challengeId:Base64URL.encode(Data(repeating:2,count:32)),
            nonce:Base64URL.encode(Data(repeating:nonce,count:32)), deviceId:MobileEnrollment.Fingerprint(spkiDER:key).hex,
            origin:MobileEnrollment.origin, expiresAtMilliseconds:expires ?? Int64(Date().timeIntervalSince1970*1000)+30_000)
        return PairRequest(v:2,method:OwnerMacBootstrap.method,proof:"",name:"검사 기기",model:nil,
            ownerEnrollment:try .init(challenge:challenge, devicePublicKey:Base64URL.encode(key)))
    }
    func attempt(_ socket: OwnerBootstrapSocket, _ request: PairRequest) -> Door.PairAttempt {
        .init(door:.remote,request:request,deviceFingerprint:socket.binding.fingerprint,source:socket.binding.sourceIP,
            display:"격리 검사",origin:.vpn,interface:socket.binding.interface,fromThisMac:false,cable:nil,ownerSocket:socket)
    }
    func active(_ now: Int64, principal: String? = nil, fingerprint: String? = nil) throws -> MobileEnrollment.ActiveChallenge {
        let generation = UUID().uuidString.lowercased(), id = UUID().uuidString.lowercased()
        let nonce = Base64URL.encode(Data(repeating:4,count:32)), fp = fingerprint ?? self.fp, principal = principal ?? self.principal
        let raw = try MobileEnrollment.activeRequestBytes(coreGeneration:generation,requestId:id,nonce:nonce,
            deviceFingerprint:fp,ownerPrincipal:principal,origin:MobileEnrollment.origin,deadlineMilliseconds:now+1500)
        return try .init(requestId:id,coreGeneration:generation,nonce:nonce,origin:MobileEnrollment.origin,
            deviceFingerprint:fp,ownerPrincipal:principal,requestDigest:MobileEnrollment.hexDigest(raw),
            deadlineMilliseconds:now+1500,receivedAtMilliseconds:now)
    }
}

@main private struct Checks {
    @MainActor static func main() async throws {
        try wire()
        try registry()
        try await receipts()
        try await socketDecisions()
        try observations()
        print("owner receipt 계약 검사 \(checks)개 통과. 메모리 키만 사용, keychain/TLS/network/UI/audio/service 호출 0.")
    }

    @MainActor static func wire() throws {
        let f = try Fixture(), request = try f.request()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let raw = try encoder.encode(request)
        expect(OwnerBootstrapWire.decode(raw)?.ownerEnrollment != nil,"정상 receipt wire")
        var object = try JSONSerialization.jsonObject(with:raw) as! [String:Any]
        func denied(_ object: [String:Any], _ label: String) throws {
            let bytes = try JSONSerialization.data(withJSONObject:object)
            expect(OwnerBootstrapWire.decode(bytes) == nil,label)
        }
        for key in ["v","method","proof","name","model","ownerEnrollment"] {
            var bad = object; bad[key] = NSNull(); try denied(bad,"null \(key)")
        }
        for (key,value) in [("unknown",1),("cable",false),("v",true),("v",2.5),("proof",4),("model",[]) ] as [(String,Any)] {
            var bad = object; bad[key] = value; try denied(bad,"잘못된 필드 \(key)")
        }
        for key in ["schemaVersion","challenge","devicePublicKey","extra"] {
            var bad = object, nested = bad["ownerEnrollment"] as! [String:Any]
            nested[key] = key == "extra" ? 1 : NSNull(); bad["ownerEnrollment"] = nested
            try denied(bad,"중첩 null/unknown \(key)")
        }
        for (key,value) in [("schemaVersion",true),("schemaVersion",2),("devicePublicKey",5),("challenge",[]) ] as [(String,Any)] {
            var bad = object, nested = bad["ownerEnrollment"] as! [String:Any]
            nested[key] = value; bad["ownerEnrollment"] = nested; try denied(bad,"중첩 wrong type \(key)")
        }
        for key in ["schema","challengeId","nonce","deviceId","origin","expiresAt","extra"] {
            var bad = object, nested = bad["ownerEnrollment"] as! [String:Any], c = nested["challenge"] as! [String:Any]
            c[key] = key == "extra" ? 1 : NSNull(); nested["challenge"] = c; bad["ownerEnrollment"] = nested
            try denied(bad,"challenge null/unknown \(key)")
        }
        for (key,value) in [("expiresAt",true),("expiresAt",3.5),("expiresAt",-1),("expiresAt",9_007_199_254_740_992 as Int64),("origin","https://evil.invalid"),("deviceId",String(repeating:"A",count:64)),("schema","other")] as [(String,Any)] {
            var bad = object, nested = bad["ownerEnrollment"] as! [String:Any], c = nested["challenge"] as! [String:Any]
            c[key] = value; nested["challenge"] = c; bad["ownerEnrollment"] = nested; try denied(bad,"challenge 값 \(key)")
        }
        let text = String(decoding:raw,as:UTF8.self)
        for (old,new) in [("\"schemaVersion\":1","\"schemaVersion\":1,\"schemaVersion\":1"),
                          ("\"schemaVersion\":1","\"schemaVersion\":1,\"schema\\u0056ersion\":1"),
                          ("\"v\":2","\"v\":2,\"v\":2"),
                          ("\"expiresAt\":","\"nonce\":\"duplicate\",\"expiresAt\":")] {
            expect(OwnerBootstrapWire.decode(Data(text.replacingOccurrences(of:old,with:new).utf8)) == nil,"duplicate raw key")
        }
        for bytes in [Data([0xef,0xbb,0xbf])+raw, raw+Data(" false".utf8), Data([0xff]), Data("[]".utf8)] {
            expect(OwnerBootstrapWire.decode(bytes) == nil,"raw strict")
        }
        var padded = raw; padded.append(Data(repeating:32,count:4096-raw.count))
        expect(OwnerBootstrapWire.decode(padded) != nil,"4096 경계 허용")
        padded.append(32); expect(OwnerBootstrapWire.decode(padded) == nil,"4097 거부")
        object.removeValue(forKey:"ownerEnrollment"); object["unknownLegacy"] = true
        expect(OwnerBootstrapWire.decode(try JSONSerialization.data(withJSONObject:object)) != nil,"기존 owner wire 호환")
    }

    @MainActor static func registry() throws {
        let f = try Fixture(); try f.register()
        let r = try OwnerBootstrapRegistry.load(store:f.store,identity:f.identity), paired = try f.store.loadPaired()
        expect(r.observation(principal:f.principal,fingerprint:f.fp,paired:paired) == .active,"정확 active")
        expect(r.observation(principal:f.principal,fingerprint:f.fp,paired:[]) == .notRegistered,"paired 없음")
        var pending = r; pending.bindings[0].state = .pending
        expect(pending.permits(principal:f.principal,fingerprint:f.fp,paired:paired),"permits pending 허용 대조")
        expect(pending.observation(principal:f.principal,fingerprint:f.fp,paired:paired) == .notRegistered,"receipt pending 거부")
        var revoked = r; revoked.bindings[0].state = .revoked
        expect(revoked.observation(principal:f.principal,fingerprint:f.fp,paired:paired) == .revoked,"철회")
        expect(r.observation(principal:String(repeating:"a",count:64),fingerprint:f.fp,paired:paired) == .identityChanged,"다른 principal")
        expect(r.observation(principal:f.principal,fingerprint:Base64URL.encode(Data(repeating:5,count:32)),paired:paired) == .identityChanged,"다른 fingerprint")
        expect(r.observation(principal:f.principal,fingerprint:f.fp,paired:paired+paired) == .identityChanged,"paired 중복")
        var p = paired; p[0].ownerActivationPending = true
        expect(r.observation(principal:f.principal,fingerprint:f.fp,paired:p) == .notRegistered,"pending paired")
        for method in [PairRequest.qr,PairRequest.code,"icloud",PairResult.cable] {
            p = paired; p[0].method = method; p[0].ownerPrincipal = nil
            expect(r.observation(principal:f.principal,fingerprint:f.fp,paired:p) == .active,"explicit paired \(method)")
        }
        p[0].method = "unknown"
        expect(r.observation(principal:f.principal,fingerprint:f.fp,paired:p) == .identityChanged,"알 수 없는 pairing")
    }

    @MainActor static func receipts() async throws {
        let f = try Fixture(); try f.register()
        let request = try f.request(), socket = f.socket(), writes = f.store.writes
        let result = await f.remote.judgeOwnerBootstrap(f.attempt(socket,request))
        expect(result.ok,"active receipt 발급")
        expect(f.store.writes == writes,"receipt 저장 0")
        let raw = try JSONEncoder().encode(result), json = try JSONSerialization.jsonObject(with:raw) as! [String:Any]
        expect(Set(json.keys) == ["ok","method","macID","ownerEnrollmentVersion","ownerReceipt"],"정확 5개 success 필드")
        expect(raw.count<=4096 && result.proof == nil && result.recognitionKey == nil,"response 크기와 secret 없음")
        let publicKey = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(f.identity.remote.privateKey)!,nil)! as Data
        let host = try MobileEnrollment.HostProfile(macID:f.identity.macID,trustedFingerprint:Base64URL.encode(f.identity.fingerprint),publicSPKIDER:SPKI.der(point:publicKey))
        let parts = try result.ownerReceipt!.parts(), payload = try JSONSerialization.jsonObject(with:parts.payload) as! [String:Any]
        let issued = payload["issuedAt"] as! Int64, expiry = payload["expiresAt"] as! Int64
        let expected = try MobileEnrollment.ReceiptInput(host:host,challenge:request.ownerEnrollment!.challenge,
            devicePublicSPKIDER:f.deviceSPKI,socketDeviceFingerprint:f.fp,ownerPrincipal:f.principal,
            nowMilliseconds:issued*1000,nodeExpiresAtSeconds:RemoteAccess.enrollmentNodeExpirySeconds(.distantFuture))
        let verified = try MobileEnrollment.verifyReceipt(result.ownerReceipt!,expected:expected,nowMilliseconds:issued*1000)
        expect(verified.payload.deviceFingerprint == f.fp && verified.payload.ownerPrincipal == f.principal,"실제 TLS 지문·principal 서명")
        expect(expiry == min(request.ownerEnrollment!.challenge.expiresAt/1000,issued+10),"10초 TTL cap")
        let decoded = try JSONDecoder().decode(PairResult.self,from:raw)
        expect(decoded.ownerReceipt?.payload == result.ownerReceipt?.payload,"wire receipt roundtrip")
        let second = await f.remote.judgeOwnerBootstrap(f.attempt(socket,request))
        expect(!second.ok,"같은 socket 같은 nonce 두 번째 발급 거부")
        let changed = await f.remote.judgeOwnerBootstrap(f.attempt(socket,try f.request(nonce:9)))
        expect(!changed.ok,"결과 unknown 후 새 nonce 발급 거부")
        expect(f.store.writes == writes,"중복 시도 저장 0")
        for state: OwnerBootstrapRegistry.Binding.State in [.pending,.revoked] {
            let denied = try Fixture(); try denied.register(state:state); let w=denied.store.writes
            let result = await denied.remote.judgeOwnerBootstrap(denied.attempt(denied.socket(),try denied.request()))
            expect(!result.ok && denied.store.writes == w,"\(state) 저장·활성화 없이 거부")
        }
        let fresh=try Fixture(), w=fresh.store.writes
        let freshResult=await fresh.remote.judgeOwnerBootstrap(fresh.attempt(fresh.socket(),try fresh.request()))
        expect(!freshResult.ok && fresh.store.writes==w,"새 기기 receipt-only 등록 금지")
        let bootstrap=PairRequest(v:2,method:OwnerMacBootstrap.method,proof:"",name:"격리 새 기기",model:nil)
        let first=await fresh.remote.judgeOwnerBootstrap(fresh.attempt(fresh.socket(),bootstrap))
        expect(first.ok && first.recognitionKey != nil && first.ownerReceipt == nil,"일반 bootstrap recognition 유지")
        let after=await fresh.remote.judgeOwnerBootstrap(fresh.attempt(fresh.socket(),try fresh.request()))
        expect(after.ok && after.recognitionKey == nil,"bootstrap 다음 새 연결 receipt-only")
        for method in [PairRequest.qr,PairRequest.code,"icloud",PairResult.cable] {
            let legacy=try Fixture(); try legacy.register(method:method); let w=legacy.store.writes
            let r=await legacy.remote.judgeOwnerBootstrap(legacy.attempt(legacy.socket(),try legacy.request()))
            expect(r.ok && legacy.store.writes==w,"explicit active receipt \(method)")
        }
        let wrong=try Fixture(); try wrong.register(); let other=try Fixture()
        let mismatch=await wrong.remote.judgeOwnerBootstrap(wrong.attempt(wrong.socket(),try wrong.request(publicKey:other.deviceSPKI)))
        expect(!mismatch.ok,"SPKI 자기주장과 실제 socket 지문 불일치 거부")
        for offset: Int64 in [-1,0,32_000] {
            let bad=await f.remote.judgeOwnerBootstrap(f.attempt(f.socket(),try f.request(expires:Int64(Date().timeIntervalSince1970*1000)+offset)))
            expect(!bad.ok,"challenge 만료·지나친 미래 \(offset)")
        }
        let expiring=try Fixture(); try expiring.register()
        let formatter=ISO8601DateFormatter(); formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let nodeExpiry=Date().addingTimeInterval(4.999)
        expiring.sensor.expiry=formatter.string(from:nodeExpiry)
        let bounded=await expiring.remote.judgeOwnerBootstrap(expiring.attempt(expiring.socket(),try expiring.request()))
        let boundedPayload=try JSONSerialization.jsonObject(with:bounded.ownerReceipt!.parts().payload) as! [String:Any]
        expect(boundedPayload["expiresAt"] as! Int64 == Int64(floor(nodeExpiry.timeIntervalSince1970)),"실제 node expiry floor가 TTL 최소값")
        let expiresDuringRead=try Fixture(); try expiresDuringRead.register(); expiresDuringRead.store.registryReads=0
        let receiptDeadline=(Int64(Date().timeIntervalSince1970*1000)/1000+1)*1000
        expiresDuringRead.store.onRegistryRead={ count in
            if count==3 { Thread.sleep(forTimeInterval:max(0,Double(receiptDeadline)/1000-Date().timeIntervalSince1970)+0.03) }
        }
        let expiredAfterSigning=await expiresDuringRead.remote.judgeOwnerBootstrap(expiresDuringRead.attempt(expiresDuringRead.socket(),try expiresDuringRead.request(expires:receiptDeadline+999)))
        expect(!expiredAfterSigning.ok,"서명 후 current store 읽기 중 receipt TTL 만료 거부")
        let node=try Fixture(); try node.register(); node.sensor.node="different-node"
        let nodeResult=await node.remote.judgeOwnerBootstrap(node.attempt(node.socket(),try node.request()))
        expect(!nodeResult.ok,"같은 user 다른 node 거부")
        node.sensor.user=8
        let userResult=await node.remote.judgeOwnerBootstrap(node.attempt(node.socket(),try node.request()))
        expect(!userResult.ok,"다른 user 거부")
        for when in [2,3] {
            let race=try Fixture(); try race.register(); race.store.registryReads=0
            var revoked=try OwnerBootstrapRegistry.load(store:race.store,identity:race.identity); revoked.bindings[0].state = .revoked
            race.store.registryReads=0
            race.store.onRegistryRead={ count in
                if count == when { try revoked.save(store:race.store.memory,identity:race.identity) }
            }
            let result=await race.remote.judgeOwnerBootstrap(race.attempt(race.socket(),try race.request()))
            expect(!result.ok,"서명 전/후 current registry 재철회 \(when)")
        }
        let epoch=try Fixture(); try epoch.register(); epoch.store.registryReads=0
        epoch.store.onRegistryRead={ count in if count==3 { epoch.remote.trust.update { $0.ownerBootstrapEpoch=UUID() } } }
        let epochResult=await epoch.remote.judgeOwnerBootstrap(epoch.attempt(epoch.socket(),try epoch.request()))
        expect(!epochResult.ok,"서명 후 epoch 변경 거부")
        let reentrant=try Fixture(); try reentrant.register(); reentrant.store.registryReads=0
        let reentrantSocket=reentrant.socket()
        reentrant.store.onRegistryRead={ count in if count==3 { reentrantSocket.cancel() } }
        let cancelledDuringRead=await reentrant.remote.judgeOwnerBootstrap(reentrant.attempt(reentrantSocket,try reentrant.request()))
        expect(!cancelledDuringRead.ok,"서명 후 store 재진입 socket 취소, deadlock 없이 거부")
        let switched=try Fixture(); try switched.register(); switched.store.registryReads=0
        switched.store.onRegistryRead={ count in if count==3 { switched.remote.configureOwnerBootstrapForTesting(sensor:switched.sensor.make(),enabled:false) } }
        let switchedResult=await switched.remote.judgeOwnerBootstrap(switched.attempt(switched.socket(),try switched.request()))
        expect(!switchedResult.ok,"store 재진입 remoteAccess off")
        let off=try Fixture(); try off.register(); off.remote.configureOwnerBootstrapForTesting(sensor:off.sensor.make(),enabled:false)
        let offResult=await off.remote.judgeOwnerBootstrap(off.attempt(off.socket(),try off.request()))
        expect(!offResult.ok,"remoteAccess off 거부")
        let error=try Fixture(); try error.register(); error.store.failRead=true
        let errorResult=await error.remote.judgeOwnerBootstrap(error.attempt(error.socket(),try error.request()))
        expect(!errorResult.ok,"current store 오류 거부")
        expect(try RemoteAccess.enrollmentNodeExpirySeconds(.distantFuture)>0,"distantFuture 안전 변환")
        expect(try RemoteAccess.enrollmentNodeExpirySeconds(Date(timeIntervalSince1970:Double.greatestFiniteMagnitude))==MobileEnrollment.maximumSafeInteger/1000,"epoch 안전 상한")
        rejects("NaN node expiry") { _ = try RemoteAccess.enrollmentNodeExpirySeconds(Date(timeIntervalSince1970:.nan)) }
        expect(try RemoteAccess.enrollmentNodeExpirySeconds(Date(timeIntervalSince1970:123.999))==123,"node expiry floor")
        expect(try RemoteAccess.enrollmentMilliseconds(Date(timeIntervalSince1970:123.5))==123500,"밀리초 정밀도")
    }

    @MainActor static func socketDecisions() async throws {
        let f=try Fixture(); try f.register(); let sensor=f.sensor.make(), socket=f.socket()
        guard case .success(let proof)=await sensor.principal(for:socket.binding) else { fatalError("센서 fixture") }
        var issued=0, live=true
        let dropping=f.socket(current:{live})
        guard case .success(let droppingProof)=await sensor.principal(for:dropping.binding) else { fatalError("fixture") }
        let result=dropping.issueReceipt(in:f.remote.trust,evidence:.init(sensor:sensor,proof:droppingProof),valid:{_ in true},issue:{ issued+=1; live=false; return PairResult(ok:true) })
        expect(result==nil && issued==1,"발급 중 socket 변경은 반환 거부")
        live=true
        let retry=dropping.issueReceipt(in:f.remote.trust,evidence:.init(sensor:sensor,proof:droppingProof),valid:{_ in true},issue:{issued+=1;return PairResult(ok:true)})
        expect(retry==nil && issued==1,"결과 unknown 재서명 0")
        socket.cancel()
        expect(socket.issueReceipt(in:f.remote.trust,evidence:.init(sensor:sensor,proof:proof),valid:{_ in true},issue:{PairResult(ok:true)})==nil,"취소 socket")
        let expired=f.socket(deadline:DispatchTime.now().uptimeNanoseconds-1)
        guard case .success(let expiredProof)=await sensor.principal(for:expired.binding) else { fatalError("fixture") }
        expect(expired.issueReceipt(in:f.remote.trust,evidence:.init(sensor:sensor,proof:expiredProof),valid:{_ in true},issue:{PairResult(ok:true)})==nil,"10초 admission 만료")
        let stoppedDuring=f.socket()
        guard case .success(let stoppedDuringProof)=await sensor.principal(for:stoppedDuring.binding) else { fatalError("fixture") }
        let stoppedDuringResult=stoppedDuring.issueReceipt(in:f.remote.trust,evidence:.init(sensor:sensor,proof:stoppedDuringProof),valid:{_ in true},issue:{sensor.stop();return PairResult(ok:true)})
        expect(stoppedDuringResult==nil,"서명 중 sensor.stop 재진입 deadlock 없이 반환 거부")
        let freshSensor=f.sensor.make()
        let stopped=f.socket()
        guard case .success(let stoppedProof)=await freshSensor.principal(for:stopped.binding) else { fatalError("fixture") }
        freshSensor.stop()
        expect(stopped.issueReceipt(in:f.remote.trust,evidence:.init(sensor:freshSensor,proof:stoppedProof),valid:{_ in true},issue:{PairResult(ok:true)})==nil,"sensor proof 무효")
        let finalCancellation=Task { @MainActor in
            var reads=0
            let ending=f.socket(current:{
                reads+=1
                if reads==3 { withUnsafeCurrentTask { $0?.cancel() } }
                return true
            })
            let sensor=f.sensor.make()
            guard case .success(let proof)=await sensor.principal(for:ending.binding) else { fatalError("fixture") }
            return ending.issueReceipt(in:f.remote.trust,evidence:.init(sensor:sensor,proof:proof),valid:{_ in true},issue:{PairResult(ok:true)})==nil
        }
        expect(await finalCancellation.value,"반환 직전 actual socket 재조회 중 Task 취소 거부")
        let cancelled=Task { @MainActor in
            let request=try f.request(); withUnsafeCurrentTask { $0?.cancel() }
            return await f.remote.judgeOwnerBootstrap(f.attempt(f.socket(),request))
        }
        expect(!(try await cancelled.value).ok,"Task 취소")
    }

    @MainActor static func observations() throws {
        let f=try Fixture(); try f.register(); let now=Int64(Date().timeIntervalSince1970*1000), challenge=try f.active(now)
        let writes=f.store.writes
        expect(try f.remote.mobileEnrollmentObservation(challenge:challenge,nowMS:now).reason == .active,"active query")
        var revoked=try OwnerBootstrapRegistry.load(store:f.store,identity:f.identity); revoked.bindings[0].state = .revoked
        try revoked.save(store:f.store.memory,identity:f.identity)
        expect(try f.remote.mobileEnrollmentObservation(challenge:challenge,nowMS:now).reason == .revoked,"active query 뒤 재철회 current read")
        expect(f.store.writes==writes,"active query 저장0")
        f.store.failRead=true
        expect(try f.remote.mobileEnrollmentObservation(challenge:challenge,nowMS:now).reason == .unavailable,"store error typed unavailable")
        f.remote.configureOwnerBootstrapForTesting(sensor:f.sensor.make(),enabled:false)
        expect(try f.remote.mobileEnrollmentObservation(challenge:challenge,nowMS:now).reason == .disabled,"off disabled 우선")
        rejects("늦은 active challenge") { _ = try f.remote.mobileEnrollmentObservation(challenge:challenge,nowMS:now+1500) }
        let fresh=try Fixture()
        expect(try fresh.remote.mobileEnrollmentObservation(challenge:fresh.active(now),nowMS:now).reason == .notRegistered,"미등록 관측")
        let changed=try Fixture(); try changed.register()
        expect(try changed.remote.mobileEnrollmentObservation(challenge:changed.active(now,principal:String(repeating:"a",count:64)),nowMS:now).reason == .identityChanged,"identityChanged 관측")
        let torn=try Fixture(); try torn.register(); torn.store.registryReads=0
        var pending=try OwnerBootstrapRegistry.load(store:torn.store,identity:torn.identity); pending.bindings[0].state = .pending; torn.store.registryReads=0
        torn.store.onRegistryRead={ count in if count==2 { try pending.save(store:torn.store.memory,identity:torn.identity) } }
        expect(try torn.remote.mobileEnrollmentObservation(challenge:torn.active(now),nowMS:now).reason == .unavailable,"비일관 store 읽기")
    }
}
