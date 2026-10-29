import Foundation
import PencilKit

final class Current: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = 1
    func matches() -> Bool { lock.lock(); defer { lock.unlock() }; return epoch == 1 }
    func change() { lock.lock(); epoch += 1; lock.unlock() }
}
final class WireProtocol: URLProtocol {
    struct Reply { let status: Int; let data: Data; var headers: [String:String] = [:]; var lost = false }
    static var replies: [Reply] = []
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []
    static var onReply: ((Int) -> Void)?
    static func reset(_ responses: [Reply]) { replies = responses; requests = []; bodies = []; onReply = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating:0,count:4096)
            while true { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; body.append(buffer,count:n) }
        }
        Self.bodies.append(body)
        guard !Self.replies.isEmpty else { client!.urlProtocol(self,didFailWithError:URLError(.badServerResponse)); return }
        let next = Self.replies.removeFirst(); Self.onReply?(Self.requests.count)
        if next.lost { client!.urlProtocol(self,didFailWithError:URLError(.timedOut)); return }
        client!.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:next.status,httpVersion:"HTTP/1.1",headerFields:next.headers)!,cacheStoragePolicy:.notAllowed)
        // 실제 bytes(for:)의 streamed limit 경계를 사용한다.
        for start in stride(from:0,to:next.data.count,by:4096) { client!.urlProtocol(self,didLoad:next.data.subdata(in:start..<min(start+4096,next.data.count))) }
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Checks {
    static var count = 0
    static func check(_ ok: Bool, _ name: String) { precondition(ok,name); count += 1; print("PASS \(name)") }
    static func refuses(_ name: String, _ f: () throws -> Void) { do { try f(); fatalError(name) } catch { check(true,name) } }
    static func fails(_ name: String, _ f: () async throws -> Void) async { do { try await f(); fatalError(name) } catch { check(true,name) } }
    static func bytes(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:[.withoutEscapingSlashes]) }
    static func object(_ data: Data) throws -> [String:Any] { try JSONSerialization.jsonObject(with:data) as! [String:Any] }
    static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated = CanvasRuntime.launch else { fatalError("isolated runtime required") }
        let folder = URL(fileURLWithPath:CommandLine.arguments[1])
        let wire = folder.appendingPathComponent("wire")
        if let flag = CommandLine.arguments.firstIndex(of:"--repairs-only"), flag + 1 < CommandLine.arguments.count {
            try await repairs(wire:wire,output:URL(fileURLWithPath:CommandLine.arguments[flag + 1]))
            print("DOCUMENT_CLIENT_REPAIRS_OK \(count); no live service/UI/device")
            return
        }
        let manifest = try object(Data(contentsOf:wire.appendingPathComponent("manifest.json")))
        var fixtures: [Int:[String:Any]] = [:], replies: [Int:WireProtocol.Reply] = [:]
        for row in manifest["responseFixtures"] as! [[String:Any]] {
            let name = row["path"] as! String, data = try Data(contentsOf:wire.appendingPathComponent(name))
            check(CanvasPacket.sha(data) == row["sha256"] as! String,"fixture file SHA \(name)")
            let f = try object(data), raw = Data(base64Encoded:f["responseJSONBase64"] as! String)!
            check(CanvasPacket.sha(raw) == row["responseSha256"] as! String,"actual HTTP response bytes SHA \(name)")
            let i = Int(name.prefix(2))!; fixtures[i] = f
            replies[i] = .init(status:f["status"] as! Int,data:raw)
        }
        let decoder = JSONDecoder(), bundle = try decoder.decode(CanvasDocumentRelay.Bundle.self,from:replies[4]!.data)
        let id = UUID(uuidString:bundle.summary.id)!, original = try bundle.validated(id:id)
        check(original.document.pages.count == 2,"actual bundle keeps both ordered pages")
        check(original.documentJSON == Data(base64Encoded:bundle.documentJSONBase64),"raw JSON retained without reserialization")
        for i in [3,5,18] { let s = try decoder.decode(CanvasDocumentRelay.Summary.self,from:replies[i]!.data); try s.validate(id:id); check(true,"actual PUT summary \(i)") }
        for i in [4,6,11,14,17] { _ = try decoder.decode(CanvasDocumentRelay.Bundle.self,from:replies[i]!.data).validated(id:id); check(true,"actual full GET bundle \(i)") }
        let conflict = try decoder.decode(CanvasDocumentRelay.Conflict.self,from:replies[13]!.data).validated(id:id)
        let candidate = try decoder.decode(CanvasDocumentRelay.Bundle.self,from:replies[14]!.data).validated(id:id)
        for i in [15,16] { let r = try decoder.decode(CanvasDocumentRelay.Resolved.self,from:replies[i]!.data); check(r.summary == candidate.summary && r.resolved && !r.reconciliationRequired,"actual resolve summary \(i)") }
        refuses("PUT summary cannot be treated as full bundle") { _ = try decoder.decode(CanvasDocumentRelay.Bundle.self,from:replies[3]!.data) }
        let (_,_,put) = try CanvasDocumentRelay.Put.make(bytes:original.documentJSON,previews:original.previews,base:nil)
        let sent = try object(put)
        check(Set(sent.keys) == Set(["base","documentJSONBase64","documentSha256","pages"]) && sent["base"] is NSNull,"exact PUT four fields including null base")
        check(Data(base64Encoded:sent["documentJSONBase64"] as! String) == original.documentJSON,"PUT retains original JSON bytes")
        var expected = try object(CanvasDocumentRelay.encoder().encode(conflict.expected)); expected["future"] = String(repeating:"0",count:64)
        refuses("future expected field is refused rather than dropped") { _ = try decoder.decode(CanvasDocumentRelay.Expected.self,from:bytes(expected)) }
        expected.removeValue(forKey:"future"); expected.removeValue(forKey:"baseSha256")
        refuses("missing nullable expected field is refused") { _ = try decoder.decode(CanvasDocumentRelay.Expected.self,from:bytes(expected)) }
        for mutation in ["order","jsonSHA","previewSHA","badPNG","badDrawing","unknownHidden","legacy"] {
            var value = try object(replies[4]!.data), pages = value["pages"] as! [[String:Any]]
            var d = try object(original.documentJSON), scenes = d["pages"] as! [[String:Any]]
            switch mutation {
            case "order": pages.reverse()
            case "jsonSHA": value["documentSha256"] = String(repeating:"0",count:64)
            case "previewSHA": pages[1]["previewSha256"] = String(repeating:"0",count:64)
            case "badPNG": let b = Data("not-png".utf8); pages[1]["previewPNGBase64"] = b.base64EncodedString(); pages[1]["previewSha256"] = CanvasPacket.sha(b)
            case "badDrawing": let b = Data("invalid-native-drawing".utf8); scenes[1]["drawingBase64"] = b.base64EncodedString(); pages[1]["drawingSha256"] = CanvasPacket.sha(b)
            case "unknownHidden": scenes[1]["futureOriginal"] = ["preserve":"e\u{301}"]
            case "legacy": d = scenes[0]
            default: break
            }
            if mutation != "legacy" { d["pages"] = scenes }
            if ["badDrawing","unknownHidden","legacy"].contains(mutation) {
                let raw = try bytes(d); value["documentJSONBase64"] = raw.base64EncodedString(); value["documentSha256"] = CanvasPacket.sha(raw)
            }
            value["pages"] = pages
            refuses("reject \(mutation) without scene fallback") { _ = try decoder.decode(CanvasDocumentRelay.Bundle.self,from:bytes(value)).validated(id:id) }
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WireProtocol.self]
        let session = URLSession(configuration:config)
        defer { session.invalidateAndCancel() }
        let relay = CanvasRelay(address:"http://192.168.88.88:4242",token:"own-document-fixture-token-0123456789",session:session)
        WireProtocol.reset([replies[1]!,replies[3]!,replies[4]!])
        let saved = try await relay.saveVaultDocument(documentJSON:original.documentJSON,previews:original.previews,base:nil,isCurrent:{true})
        check(saved.sameOriginals(as:original) && WireProtocol.requests.map(\.httpMethod) == ["GET","PUT","GET"],"URLSession save requires capability PUT and full GET")
        check(WireProtocol.requests.allSatisfy({$0.value(forHTTPHeaderField:"X-Canvas-Token") == "own-document-fixture-token-0123456789"}),"existing auth used on each document request")
        WireProtocol.reset([replies[13]!,replies[14]!,replies[1]!,replies[15]!,replies[17]!])
        let c = try await relay.vaultDocumentConflict(id:id,isCurrent:{true})
        let chosen = try await relay.vaultDocumentCandidate(c,material:.displaced,isCurrent:{true})
        let resolved = try await relay.resolveVaultDocumentConflict(c,decision:.useDisplaced,candidate:chosen,isCurrent:{true})
        check(resolved.sameOriginals(as:candidate),"candidate split GET resolve and full reopen")
        let request = try object(WireProtocol.bodies[3]), expectedBody = request["expected"] as! [String:Any]
        check(expectedBody.count == 6 && request["recoveryID"] as! String == c.recoveryID,"six opaque expected fields and recoveryID unchanged")
        check(try NSDictionary(dictionary:expectedBody).isEqual(to:object(CanvasDocumentRelay.encoder().encode(c.expected))),"expected null and SHA values preserved")
        var opaque = try object(replies[13]!.data); opaque["recoveryID"] = "opaque:AbC/+?=&e\u{301}"
        let opaqueConflict = try decoder.decode(CanvasDocumentRelay.Conflict.self,from:bytes(opaque)).validated(id:id)
        WireProtocol.reset([replies[14]!])
        _ = try await relay.vaultDocumentCandidate(opaqueConflict,material:.displaced,isCurrent:{true})
        let query = URLComponents(url:WireProtocol.requests[0].url!,resolvingAgainstBaseURL:false)!.queryItems!
        check(WireProtocol.requests[0].url!.absoluteString.contains("%2B") && query.first(where:{$0.name == "recoveryID"})!.value == opaqueConflict.recoveryID,"opaque recovery ID is percent encoded without case conversion")
        for mode in ["missing","wrong","unknown409","held200","lostACK","oversized","streamed"] {
            var cap = try object(replies[1]!.data)
            if mode == "missing" { cap.removeValue(forKey:"document") }
            if mode == "wrong" { var d = cap["document"] as! [String:Any]; d["wholeDocument"] = false; cap["document"] = d }
            let failure: WireProtocol.Reply
            if mode == "unknown409" { failure = .init(status:409,data:try bytes(["code":"future_code","publicationAttempted":false,"reconciliationRequired":false])) }
            else if mode == "held200" { failure = .init(status:200,data:try bytes(["reconciliationRequired":true,"recoveryID":"opaque-ID"])) }
            else if mode == "lostACK" { failure = .init(status:200,data:Data(),lost:true) }
            else if mode == "oversized" { failure = .init(status:200,data:replies[3]!.data,headers:["Content-Length":"100000000"]) }
            else { failure = replies[3]! }
            if mode == "streamed" { WireProtocol.reset([.init(status:200,data:Data(repeating:32,count:65537))]) }
            else { WireProtocol.reset([.init(status:200,data:try bytes(cap)),failure]) }
            await fails("refuse \(mode) with no retry or fallback") {
                _ = try await relay.saveVaultDocument(documentJSON:original.documentJSON,previews:original.previews,base:nil,isCurrent:{true})
            }
            check(!WireProtocol.requests.contains(where:{$0.url!.path == "/vault/canvas"}) && WireProtocol.requests.filter({$0.httpMethod == "PUT"}).count <= 1,"\(mode) has no legacy write or retry")
            if mode == "unknown409" {
                WireProtocol.reset([failure])
                do { _ = try await relay.vaultDocument(id:id,isCurrent:{true}); fatalError("409 accepted") }
                catch { check(VaultSaveConflict.classified(error) == .unclassified,"unknown code flags=false remains explicit barrier") }
            }
        }
        for i in [0,7,8,9,10,12] {
            WireProtocol.reset([replies[i]!])
            do { _ = try await relay.vaultDocument(id:id,isCurrent:{true}); fatalError("error fixture accepted") }
            catch {
                if i == 0 { check((error as NSError).code == 401,"actual authentication refusal") }
                else { check(VaultSaveConflict.classified(error) == (i == 7 ? .prepublication : i == 12 ? .reconciliationRequired : .unclassified),"actual recorded typed/error response \(i)") }
            }
        }
        WireProtocol.reset([.init(status:404,data:try bytes(["error":"missing"]))])
        await fails("unsupported capability endpoint blocks publication") {
            _ = try await relay.saveVaultDocument(documentJSON:original.documentJSON,previews:original.previews,base:nil,isCurrent:{true})
        }
        check(WireProtocol.requests.count == 1,"capability 404 has zero PUT")
        let current = Current(); WireProtocol.reset([replies[1]!]); WireProtocol.onReply = { _ in current.change(); current.change() }
        await fails("connection ABA after capability blocks PUT") {
            _ = try await relay.saveVaultDocument(documentJSON:original.documentJSON,previews:original.previews,base:nil,isCurrent:{current.matches()})
        }
        check(WireProtocol.requests.count == 1,"old epoch has zero PUT")
        WireProtocol.reset([])
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await relay.saveVaultDocument(documentJSON:original.documentJSON,previews:original.previews,base:nil,isCurrent:{true})
        }
        await fails("cancelled task cannot dispatch capability or PUT") { _ = try await cancelled.value }
        check(WireProtocol.requests.isEmpty,"task cancellation has zero requests")
        let epochAfterPut = Current(); WireProtocol.reset([replies[1]!,replies[3]!])
        WireProtocol.onReply = { n in if n == 2 { epochAfterPut.change() } }
        await fails("late PUT ACK from old connection is not accepted") {
            _ = try await relay.saveVaultDocument(documentJSON:original.documentJSON,previews:original.previews,base:nil,isCurrent:{epochAfterPut.matches()})
        }
        check(WireProtocol.requests.count == 2,"late ACK neither retries nor applies a checkpoint")
        WireProtocol.reset([replies[1]!,replies[3]!,replies[6]!])
        await fails("changed document on readback cannot accept ACK") {
            _ = try await relay.saveVaultDocument(documentJSON:original.documentJSON,previews:original.previews,base:nil,isCurrent:{true})
        }
        // Native ink 표본은 공유 wire의 빈 drawing 성공과 구분한다.
        let points = [10.0,20,30].enumerated().map { i,x in PKStrokePoint(location:CGPoint(x:x,y:x/2),timeOffset:Double(i)/10,size:CGSize(width:3+i,height:4+i),opacity:0.7,force:0.6,azimuth:0.3,altitude:1) }
        let stroke = PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)),transform:CGAffineTransform(rotationAngle:0.3))
        let drawing = try PKDrawing(data:PKDrawing(strokes:[stroke]).dataRepresentation()); var page = CanvasScene(); page.schemaVersion = 3; page.drawingBase64 = drawing.dataRepresentation().base64EncodedString(); page.strokes = CanvasScene.nativeInkStrokes(drawing)
        let doc = try CanvasDocument(legacy:page), raw = try doc.bytes(), png = original.previews.values.first!
        let (native,_,_) = try CanvasDocumentRelay.Put.make(bytes:raw,previews:[page.id:png],base:nil)
        check(native.documentJSONBase64 == raw.base64EncodedString() && native.pages[0].drawingSha256 == CanvasPacket.sha(drawing.dataRepresentation()),"native PKDrawing source bytes and SHA retained")
        print("DOCUMENT_RELAY_CHECKS_OK \(count); actual PKDrawing/ImageIO + recorded HTTP/URLProtocol; no live service/UI/device")
    }
}
