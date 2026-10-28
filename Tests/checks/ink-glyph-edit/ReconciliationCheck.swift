import Foundation
import PencilKit

final class ReconciliationProtocol: URLProtocol {
    static var snapshot: [String:Any] = [:], active: [String:Any] = [:], displaced: [String:Any] = [:]
    static var requests: [[String:Any]] = []
    static var mode = "normal", resolved = false, transitions = 0, selected: [String:Any] = [:]
    static var hook: (@MainActor (String,String)->Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.value(forHTTPHeaderField:"X-Canvas-Token") == "own-fixture-token-012345678901")
        let conflict = request.url!.path == "/vault/canvas/conflict"
        var result: [String:Any], status = 200
        if conflict && request.httpMethod == "PUT" {
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open();defer { stream.close() };var buffer=[UInt8](repeating:0,count:4096)
                while true { let n=stream.read(&buffer,maxLength:buffer.count);if n<=0 {break};bytes.append(contentsOf:buffer.prefix(n)) }
            }
            let body = try! JSONSerialization.jsonObject(with:bytes) as! [String:Any]
            Self.requests.append(body)
            if Self.mode == "stale" || Self.mode == "candidate" {
                status=409;result=["code":Self.mode == "candidate" ? "reconciliation_candidate_invalid":"note_reconciliation_required",
                    "error":"/private/fixture/hidden", "reconciliationRequired":true,"recoveryID":Self.snapshot["recoveryID"]!]
            } else {
                Self.selected = body["decision"] as? String == "keepCurrent" ? Self.active:Self.displaced
                if !Self.resolved { Self.transitions += 1 };Self.resolved=true
                result=Self.selected["canvas"] as! [String:Any]
                result.removeValue(forKey:"sceneJSONBase64")
                result.merge(["recoveryID":Self.snapshot["recoveryID"]!,"decision":body["decision"]!,"resolved":true,"reconciliationRequired":false]) {_,new in new}
                if Self.mode == "lost" {
                    Self.mode="normal";client!.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return
                }
                if Self.mode == "bad-result" { result["sceneSha256"]=String(repeating:"0",count:64) }
            }
        } else if conflict {
            if Self.mode=="resolved-404" && Self.resolved {status=404;result=["error":"no unresolved conflict"]}
            else {result=Self.snapshot}
        }
        else if request.url!.path == "/vault/canvas" {
            result=Self.selected["canvas"] as! [String:Any]
            if Self.mode == "changed-readback" { result["noteSha256"]=String(repeating:"0",count:64) }
        } else {
            let raw=Data(base64Encoded:Self.selected["markdownBase64"] as! String)!
            result=["path":(Self.selected["canvas"] as! [String:Any])["path"]!,"text":String(data:raw,encoding:.utf8)!,
                "sha256":Self.selected["sha256"]!,"modifiedAt":"fixture"]
        }
        let data=try! JSONSerialization.data(withJSONObject:result)
        let replyStatus=status
        Task { @MainActor in
            Self.hook?(request.url!.path,request.httpMethod ?? "GET")
            client!.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:replyStatus,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
            client!.urlProtocol(self,didLoad:data);client!.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
@main struct ReconciliationCheck {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let output=URL(fileURLWithPath:CommandLine.arguments[1])
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        precondition(support.path.hasPrefix(output.appendingPathComponent("home").path+"/"),"own routed fixture home required")
        let id=UUID(),recovery=UUID()
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jAt8AAAAASUVORK5CYII=")!
        var scene=CanvasScene();scene.id=id;scene.schemaVersion=3
        scene.drawingBase64=PKDrawing().dataRepresentation().base64EncodedString()
        _=scene.addNode(kind:.note,at:.init(x:40,y:50),text:"제안본")
        func material(_ original:CanvasScene,_ memo:String,noncanonical:Bool=false)throws->[String:Any] {
            let encoder=JSONEncoder();encoder.outputFormatting=noncanonical ? [.prettyPrinted]:[.sortedKeys]
            let bytes=try encoder.encode(original),markdown=Data(("# 보존 원문\r\n"+memo+"\r\ne\u{301} 👩🏽‍💻").utf8)
            return ["sha256":CanvasPacket.sha(markdown),"markdownBase64":markdown.base64EncodedString(),"validCanvas":true,
                "imagePNGBase64":png.base64EncodedString(),"canvas":["path":"CCR Canvas/\(id.uuidString.lowercased()).md",
                    "noteSha256":CanvasPacket.sha(markdown),"sceneSha256":CanvasPacket.sha(bytes),"imageSha256":CanvasPacket.sha(png),
                    "revision":original.revision,"sceneJSONBase64":bytes.base64EncodedString()]]
        }
        ReconciliationProtocol.active=try material(scene,"제안본")
        var external=scene;external.revision += 1;external.nodes[0].text="외부 원문"
        ReconciliationProtocol.displaced=try material(external,"외부 변경 보존",noncanonical:true)
        let expected:[String:Any]=["activeSha256":ReconciliationProtocol.active["sha256"]!,"baseSha256":NSNull(),
            "displacedSha256":ReconciliationProtocol.displaced["sha256"]!,"proposalSha256":ReconciliationProtocol.active["sha256"]!,
            "historySha256":CanvasPacket.sha(Data("[]".utf8))]
        ReconciliationProtocol.snapshot=["schema":"ccr.canvas-conflict/v1","id":id.uuidString,"recoveryID":recovery.uuidString,
            "code":"note_reconciliation_required","reconciliationRequired":true,"publicationAttempted":true,
            "expected":expected,"materials":["active":ReconciliationProtocol.active,"base":NSNull(),"displaced":ReconciliationProtocol.displaced,"proposal":ReconciliationProtocol.active],"history":[]]
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ReconciliationProtocol.self]
        let session=URLSession(configuration:config),relay=CanvasRelay(address:"http://192.168.88.88:4242",token:"own-fixture-token-012345678901",session:session)
        var count=0
        func check(_ v:Bool,_ message:String) { precondition(v,message);count += 1;print("PASS",message) }
        let snapshot=try await relay.vaultCanvasConflict(id:id)
        check(snapshot.id==id && snapshot.expected.baseSha256==nil && snapshot.materials.base==nil,"exact DTO accepts explicit absent material/null SHA")
        check(snapshot.materials.displaced?.markdown.contains("外") == false && snapshot.materials.displaced?.markdown.contains("외부 변경 보존") == true,"full original UTF8/CRLF materials are readable")
        for decision in CanvasRelay.ConflictDecision.allCases {
            ReconciliationProtocol.resolved=false
            let (result,readback)=try await relay.resolveVaultCanvasConflict(snapshot,decision:decision)
            check(result.decision==decision && readback.noteSha256==snapshot.selected(decision)?.sha256,"explicit "+decision.rawValue+" validates response and canvas/note readbacks")
            let body=ReconciliationProtocol.requests.last!,e=body["expected"] as! [String:Any]
            check(Set(body.keys)==Set(["recoveryID","expected","decision"]) && Set(e.keys)==Set(expected.keys) && e["baseSha256"] is NSNull,"PUT emits only three keys and all five original expected keys including null")
        }
        for mode in ["stale","candidate","bad-result","changed-readback"] {
            ReconciliationProtocol.mode=mode
            do { _=try await relay.resolveVaultCanvasConflict(snapshot,decision:.keepCurrent);preconditionFailure("accepted "+mode) }
            catch { check(true,"reject "+mode+" without automatic retry") }
        }
        ReconciliationProtocol.mode="lost";ReconciliationProtocol.resolved=false
        let transitions=ReconciliationProtocol.transitions
        do { _=try await relay.resolveVaultCanvasConflict(snapshot,decision:.useDisplaced);preconditionFailure("lost response") } catch {}
        let lostBody=ReconciliationProtocol.requests.last!
        _=try await relay.resolveVaultCanvasConflict(snapshot,decision:.useDisplaced)
        check(ReconciliationProtocol.transitions==transitions+1,"explicit same-choice confirmation causes one fixture publication")
        check(NSDictionary(dictionary:lostBody).isEqual(to:ReconciliationProtocol.requests.last!),"lost ACK explicit confirmation keeps same recoveryID expected and decision")
        for mutation in ["hash","version","id","png","missingExpected"] {
            var object=ReconciliationProtocol.snapshot
            if mutation=="version" {object["schema"]="unknown"}
            if mutation=="id" {object["id"]=UUID().uuidString}
            if mutation=="missingExpected" {var e=expected;e.removeValue(forKey:"baseSha256");object["expected"]=e}
            if mutation=="hash" || mutation=="png" {
                var mats=object["materials"] as! [String:Any],m=ReconciliationProtocol.active
                m[mutation=="hash" ? "sha256":"imagePNGBase64"]=mutation=="hash" ? String(repeating:"0",count:64):Data([1,2,3]).base64EncodedString()
                mats["active"]=m;object["materials"]=mats
            }
            do {_=try JSONDecoder().decode(CanvasRelay.VaultConflict.self,from:JSONSerialization.data(withJSONObject:object)).validated(id:id);preconditionFailure(mutation)}
            catch {check(true,"reject invalid material/DTO "+mutation)}
        }
        let cacheStore=CanvasStore();cacheStore.scene=scene;cacheStore.saveNow()
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let local=try encoder.encode(scene),sha=CanvasPacket.sha(local),backup=try CanvasRuntime.conflictRecoveryURL("CanvasConflictLocal-\(UUID().uuidString.lowercased()).json")
        try CanvasLocalFile.write(local,to:backup)
        cacheStore.scene.nodes[0].text="새 입력"
        do {try cacheStore.applyReconciledCanvas(external,expectedLocalSHA:sha,preservedAt:backup);preconditionFailure("stale local accepted")}
        catch {check(cacheStore.scene.nodes[0].text=="새 입력","new input blocks adoption and preserves selection source")}
        cacheStore.scene=scene
        cacheStore.inkMathInputBusy=true
        do {try cacheStore.applyReconciledCanvas(external,expectedLocalSHA:sha,preservedAt:backup);preconditionFailure("math input discarded")}
        catch {check(cacheStore.scene==scene,"active math input blocks scene replacement")}
        cacheStore.inkMathInputBusy=false;cacheStore.commentInputBusy=true
        check(!cacheStore.canApplyReconciledCanvas,"active comment input blocks reconciliation")
        cacheStore.commentInputBusy=false;cacheStore.proposedNode=scene.nodes[0].id
        check(!cacheStore.canApplyReconciledCanvas,"pending text proposal must be finished before reconciliation")
        cacheStore.proposedNode=nil
        try cacheStore.applyReconciledCanvas(external,expectedLocalSHA:sha,preservedAt:backup)
        check(cacheStore.scene==external && (try? CanvasLocalFile.read(backup))==local,"explicit selected scene replaces cache while original local bytes remain")
        let reopened=CanvasStore()
        check(reopened.scene==external,"actual native Store reopens selected scene from local cache")
        let preservedSHA=CanvasPacket.sha(try CanvasLocalFile.read(backup))
        check(preservedSHA==sha,"preserved original native/scene bytes remain intact")
        try await checkPendingReconciliationEditors(check)
        cacheStore.scene=scene
        try await WorkspaceReconciliationHarness(store:cacheStore,relay:relay).checks(check)
        let wire=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
        let example=try JSONSerialization.jsonObject(with:wire) as! [String:Any]
        let real=try JSONDecoder().decode(CanvasRelay.VaultConflict.self,from:JSONSerialization.data(withJSONObject:example["get"]!))
        _=try real.validated(id:real.id)
        check(real.materials.displaced?.validCanvas==true,"exact Galileo real-file wire example is accepted by native DTO/scene/PNG checks")
        print("RECONCILIATION_OK",count,"transport=URLProtocol fixture; real DTO Relay Store PKDrawing file API; no HTTP/UI/device acceptance")
        session.invalidateAndCancel()
    }
}
