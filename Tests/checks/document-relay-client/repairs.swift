import Foundation
import zlib

extension Checks {
    static func repairs(wire: URL, output: URL) async throws {
        let fixture = try object(Data(contentsOf:wire.appendingPathComponent("04-GET-vault-document.json")))
        let response = Data(base64Encoded:fixture["responseJSONBase64"] as! String)!
        let original = try JSONDecoder().decode(CanvasDocumentRelay.Bundle.self,from:response)
        let id = UUID(uuidString:original.summary.id)!, decoded = try original.validated(id:id)
        check(decoded.document.pages.count == 2,"normal two-page bundle remains readable")
        let previews = decoded.previews
        for variant in ["root","selected","hidden","escaped"] {
            var value = try object(decoded.documentJSON)
            if variant != "root" {
                var pages = value["pages"] as! [[String:Any]], nodes = pages[variant == "selected" ? 0 : 1]["nodes"] as! [[String:Any]]
                nodes[0]["text"] = "duplicate-target"
                pages[variant == "selected" ? 0 : 1]["nodes"] = nodes
                value["pages"] = pages
            }
            var text = String(decoding:try bytes(value),as:UTF8.self)
            let target = variant == "root" ? "\"format\":\"ccr.canvas-document\"" : "\"text\":\"duplicate-target\""
            let replacement = variant == "root" ? target + "," + target :
                "\"text\":\"duplicate-first\",\"\(variant == "escaped" ? "\\u0074ext" : "text")\":\"duplicate-target\""
            check(text.components(separatedBy:target).count == 2,"single duplicate injection target \(variant)")
            text = text.replacingOccurrences(of:target,with:replacement)
            let raw = Data(text.utf8)
            var envelope = try object(response)
            envelope["documentJSONBase64"] = raw.base64EncodedString()
            envelope["documentSha256"] = CanvasPacket.sha(raw)
            refuses("duplicate \(variant) full bundle rejected") { _ = try JSONDecoder().decode(CanvasDocumentRelay.Bundle.self,from:bytes(envelope)).validated(id:id) }
            refuses("duplicate \(variant) PUT rejected") { _ = try CanvasDocumentRelay.Put.make(bytes:raw,previews:previews,base:nil) }
            refuses("duplicate \(variant) document ingress rejected") { _ = try CanvasDocument.decodeDocument(raw) }
            refuses("duplicate \(variant) import ingress rejected") { _ = try CanvasDocument.decode(raw) }
            let folder = output.appendingPathComponent("files-\(variant)",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let files = CanvasDocumentFiles(folder:folder.resolvingSymlinksInPath(),requiresScope:false)
            _ = try files.save(decoded.document,previews:previews,expected:nil)
            let package = files.documentURL(id), headURL = package.appendingPathComponent("current.json")
            var head = try object(Data(contentsOf:headURL))
            let generation = (head["generation"] as! String).lowercased()
            let documentURL = package.appendingPathComponent("revisions/\(generation)/document.json")
            try raw.write(to:documentURL)
            head["documentSHA"] = CanvasPacket.sha(raw)
            try bytes(head).write(to:headURL)
            refuses("duplicate \(variant) Files generation rejected") { _ = try files.load(id) }
            check(try Data(contentsOf:documentURL) == raw,"duplicate \(variant) original file not rewritten")
        }
        var normal = try object(decoded.documentJSON), pages = normal["pages"] as! [[String:Any]], nodes = pages[1]["nodes"] as! [[String:Any]]
        let literal = "문자열 {\"text\":1,\"text\":2} [ ], \\ 끝 e\u{301} 👩🏽‍💻"
        nodes[0]["text"] = literal; pages[1]["nodes"] = nodes; normal["pages"] = pages
        let raw = try bytes(normal), typed = try CanvasDocument.decodeDocument(raw)
        check(typed.pages[1].nodes[0].text.utf8.elementsEqual(literal.utf8),"quoted braces and escaped value text are preserved")
        let (_,_,normalPut) = try CanvasDocumentRelay.Put.make(bytes:raw,previews:previews,base:nil)
        check(Data(base64Encoded:try object(normalPut)["documentJSONBase64"] as! String) == raw,"normal PUT keeps raw JSON bytes")

        let pageID = decoded.document.pages[0].id, png = previews[pageID]!
        try CanvasDocumentRelay.png(png); check(true,"normal PNG remains readable")
        var badCRC = png; badCRC[29] ^= 1
        var trailing = png; trailing.append(0)
        let badImages = [Data(png.prefix(8)),Data(png.prefix(33)),Data(png.prefix(45)),Data(png.dropLast()),badCRC,trailing]
        for (index,bad) in badImages.enumerated() {
            refuses("malformed PNG \(index) direct validation rejected") { try CanvasDocumentRelay.png(bad) }
            var value = try object(response), assets = value["pages"] as! [[String:Any]]
            assets[0]["previewPNGBase64"] = bad.base64EncodedString(); assets[0]["previewSha256"] = CanvasPacket.sha(bad)
            value["pages"] = assets
            refuses("malformed PNG \(index) bundle rejected") { _ = try JSONDecoder().decode(CanvasDocumentRelay.Bundle.self,from:bytes(value)).validated(id:id) }
            var badPreviews = previews; badPreviews[pageID] = bad
            refuses("malformed PNG \(index) PUT rejected") { _ = try CanvasDocumentRelay.Put.make(bytes:decoded.documentJSON,previews:badPreviews,base:nil) }
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WireProtocol.self]
        let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
        let relay = CanvasRelay(address:"http://192.168.88.88:4242",token:"own-document-fixture-token-0123456789",session:session)
        let samples: [(Any?,Any?,VaultSaveConflict)] = [(false,false,.prepublication),(true,true,.reconciliationRequired),
            (0,0,.unclassified),(1,0,.unclassified),(false,0,.unclassified),(0,false,.unclassified),
            (0.0,0.0,.unclassified),("false","false",.unclassified),(NSNull(),NSNull(),.unclassified),(nil,nil,.unclassified)]
        for (index,sample) in samples.enumerated() {
            var value: [String:Any] = ["code":"document_stale"]
            if let flag = sample.0 { value["reconciliationRequired"] = flag }
            if let flag = sample.1 { value["publicationAttempted"] = flag }
            WireProtocol.reset([.init(status:409,data:try bytes(value))])
            do { _ = try await relay.vaultDocument(id:id,isCurrent:{true}); fatalError("invalid typed status accepted") }
            catch { check(VaultSaveConflict.classified(error) == sample.2,"strict JSON flags \(index)") }
            check(WireProtocol.requests.count == 1,"strict flags \(index) no retry")
        }
        var malformedSuccess = try object(response)
        malformedSuccess["reconciliationRequired"] = 0
        WireProtocol.reset([.init(status:200,data:try bytes(malformedSuccess))])
        do { _ = try await relay.vaultDocument(id:id,isCurrent:{true}); fatalError("malformed success accepted") }
        catch { check(VaultSaveConflict.classified(error) == .unclassified,"numeric flags in successful status remain a barrier") }
        let legacyFlags: [[String:Any]] = [["reconciliationRequired":false,"publicationAttempted":false], ["reconciliationRequired":true,"publicationAttempted":true]]
        for flags in legacyFlags {
            WireProtocol.reset([.init(status:409,data:try bytes(flags))])
            do { _ = try await relay.vaultCanvas(id:id); fatalError("legacy error accepted") }
            catch { check(VaultSaveConflict.classified(error) == ((flags["reconciliationRequired"] as! Bool) ? .reconciliationRequired : .prepublication),"legacy typed Boolean behavior retained") }
        }
    }
}
