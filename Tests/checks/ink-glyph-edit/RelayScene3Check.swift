import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
final class StubProtocol: URLProtocol {
    static var supported = false
    static var capabilityStatus = 200
    static var putStatus = 200
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer,maxLength:buffer.count)
                if count <= 0 { break }; bytes.append(buffer,count:count)
            }
        }
        Self.bodies.append(bytes)
        let capability = request.url!.path.hasSuffix("/capabilities")
        let status = capability ? Self.capabilityStatus : Self.putStatus
        let body: [String:Any] = capability ? ["schema":"ccr.canvas-capabilities/v1",
            "sceneSchemaVersions":Self.supported ? [1,2,3] : [1,2],"nodeKinds":["note","box","ellipse","line"],
            "diagramProjection":"ccr.diagram-shapes/v1"] : ["path":"fixture","noteSha256":"x","sceneSha256":"y","imageSha256":"z","revision":0]
        client!.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client!.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body)); client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct RelayScene3Check {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration:configuration)
        let relay = CanvasRelay(address:"http://fixture.invalid",token:"isolated-fixture",session:session)
        var remote = CanvasScene(); remote.schemaVersion = 2
        let line = CanvasNode(id:UUID(),kind:.line,frame:.init(x:10,y:20,width:100,height:2),text:"",confidence:.proposal,sourceStrokeIds:[])
        let created = AgentRevision(sceneId:remote.id,baseRevision:remote.revision,annotations:[],proposedNodes:[line])
        precondition(remote.apply(created) && remote.schemaVersion == 3,"remote new kind promotes scene3")
        let edit = AgentRevision(sceneId:remote.id,baseRevision:remote.revision,annotations:[],proposedNodes:[],nodeEdits:[.init(expected:remote.nodes[0],text:"원격 직선")])
        precondition(remote.apply(edit) && remote.schemaVersion == 3 && remote.nodes[0].frame == line.frame,"remote edit never downgrades scene3 geometry")
        var direct = CanvasScene()
        _ = direct.addNode(kind:.ellipse,at:.init(x:0,y:0))
        precondition(direct.schemaVersion == 3,"new kind factory promotes scene3")
        for legacyVersion in [1,2] {
            var legacy = CanvasScene(); legacy.schemaVersion = legacyVersion
            _ = legacy.addNode(kind:.note,at:.init(x:0,y:0))
            let reopened = try JSONDecoder().decode(CanvasScene.self,from:JSONEncoder().encode(legacy))
            precondition(reopened == legacy,"legacy note preserved")
        }
        var scene = CanvasScene(); scene.schemaVersion = 3
        for status in [404,200] {
            StubProtocol.requests = []; StubProtocol.capabilityStatus = status; StubProtocol.supported = false
            do { _ = try await relay.saveVaultCanvas(scene:scene,imagePNG:Data(),baseSha256:nil); preconditionFailure("legacy accepted scene3") } catch {}
            precondition(StubProtocol.requests.count == 1 && StubProtocol.requests[0].httpMethod == "GET","unsupported server has zero PUT")
        }
        StubProtocol.requests = []; StubProtocol.supported = true
        _ = try await relay.saveVaultCanvas(scene:scene,imagePNG:Data(),baseSha256:nil)
        precondition(StubProtocol.requests.map(\.httpMethod) == ["GET","PUT"],"schema3 preflight then write")
        let body = try JSONSerialization.jsonObject(with:StubProtocol.bodies.last!) as! [String:Any]
        let stored = try JSONDecoder().decode(CanvasScene.self,from:Data(base64Encoded:body["sceneJSONBase64"] as! String)!)
        precondition(stored.schemaVersion == 3,"no silent downgrade")
        StubProtocol.requests = []; StubProtocol.putStatus = 415
        do { _ = try await relay.saveVaultCanvas(scene:scene,imagePNG:Data(),baseSha256:nil); preconditionFailure("rejection became success") }
        catch { precondition((error as NSError).code == 415,"server rejection preserved") }
        StubProtocol.requests = []; StubProtocol.supported = false; StubProtocol.putStatus = 200
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
        let packet = try CanvasPacket(scene:scene,imagePNG:png,session:.init(threadId:UUID(),sessionId:"fixture",observedAt:"fixture"))
        do { _ = try await relay.send(packet); preconditionFailure("packet bypassed scene3 gate") } catch {}
        precondition(StubProtocol.requests.map(\.httpMethod) == ["GET"],"schema3 packet has zero POST on unsupported server")
        StubProtocol.requests = []; scene.schemaVersion = 2
        _ = try await relay.saveVaultCanvas(scene:scene,imagePNG:Data(),baseSha256:nil)
        precondition(StubProtocol.requests.map(\.httpMethod) == ["PUT"],"legacy note path independent")
        print("RELAY_SCENE3_OK legacy404=blocked legacy200=blocked capability=GET_then_PUT version=3 refusal415=error scene2=PUT_only network=0")
        session.invalidateAndCancel()
    }
}
