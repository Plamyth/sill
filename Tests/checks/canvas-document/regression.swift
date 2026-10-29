import Foundation
import AppKit
import Darwin

@main struct DocumentRepairChecks {
    static let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
    static var count = 0
    static func check(_ condition: Bool, _ label: String) { precondition(condition,label); count += 1; print("PASS",label) }
    static func rejects(_ failure: CanvasDocumentFiles.Failure, _ label: String, _ body: () throws -> Void) {
        do { try body(); fatalError("accepted: \(label)") }
        catch let actual as CanvasDocumentFiles.Failure { check(actual == failure,label) }
        catch { fatalError("wrong failure: \(error)") }
    }
    static func archive(_ url: URL, expected: CanvasDocument) throws {
        let raw = try Data(contentsOf:url.appendingPathComponent("current.json"))
        let h = try JSONDecoder().decode(CanvasDocumentFiles.Head.self,from:raw)
        let generation = url.appendingPathComponent("revisions/\(h.generation.uuidString.lowercased())")
        let bytes = try Data(contentsOf:generation.appendingPathComponent("document.json"))
        let decoded = try CanvasDocument.decode(bytes)
        check(CanvasPacket.sha(bytes) == h.documentSHA && decoded == expected,"복구 세대의 전체 문서 SHA와 원문")
        check(h.pages.map(\.id) == expected.pages.map(\.id),"복구 세대의 모든 페이지 순서")
        for (page,asset) in zip(expected.pages,h.pages) {
            let folder = generation.appendingPathComponent("pages/\(page.id.uuidString.lowercased())")
            let drawing = try Data(contentsOf:folder.appendingPathComponent("drawing.pkdrawing"))
            let preview = try Data(contentsOf:folder.appendingPathComponent("preview.png"))
            check(drawing == Data(base64Encoded:page.drawingBase64) && CanvasPacket.sha(drawing) == asset.drawingSHA && preview == png && CanvasPacket.sha(preview) == asset.previewSHA,"복구 세대 native 잉크와 preview 전체 보존")
        }
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let args = CommandLine.arguments, fm = FileManager.default
        if args.count > 1 && args[1] == "--hold-lock" {
            let fd = open(args[2],O_RDWR | O_NOFOLLOW)
            precondition(fd >= 0 && flock(fd,LOCK_EX) == 0)
            print("LOCKED")
            var input = pollfd(fd:STDIN_FILENO,events:Int16(POLLIN),revents:0)
            _ = poll(&input,1,5000) // 자체 holder의 유한 수명; 서비스/다른 프로세스는 건드리지 않는다.
            _ = flock(fd,LOCK_UN); close(fd); return
        }
        let out = URL(fileURLWithPath:args[1],isDirectory:true).resolvingSymlinksInPath()
        let review = URL(fileURLWithPath:args[2],isDirectory:true).resolvingSymlinksInPath()
        let originalFolder = review.appendingPathComponent("native/directory-race")
        let originals = try fm.contentsOfDirectory(at:originalFolder,includingPropertiesForKeys:nil).filter { $0.pathExtension == "sill" }
        precondition(originals.count == 1)
        let h = try JSONDecoder().decode(CanvasDocumentFiles.Head.self,from:Data(contentsOf:originals[0].appendingPathComponent("current.json")))
        let originalBytes = try Data(contentsOf:originals[0].appendingPathComponent("revisions/\(h.generation.uuidString.lowercased())/document.json"))
        let document = try CanvasDocument.decode(originalBytes)
        let previews = Dictionary(uniqueKeysWithValues:document.pages.map { ($0.id,png) })
        var proposal = document, hidden = document.pages[0]
        hidden.annotations[0].text += " 외부"; hidden.revision += 1
        try proposal.replacePage(hidden,expectedRevision:proposal.revision)
        var races: [[String:Any]] = []
        for phase in ["afterExchange","beforeExchange","afterGeneration"] {
            let root = out.appendingPathComponent(phase,isDirectory:true)
            try fm.createDirectory(at:root,withIntermediateDirectories:true)
            let files = CanvasDocumentFiles(folder:root,requiresScope:false)
            let base = try files.save(document,previews:previews,expected:nil), canonical = files.documentURL(document.id)
            let oldHead = try Data(contentsOf:canonical.appendingPathComponent("current.json"))
            let replacement = root.appendingPathComponent("external-replacement",isDirectory:true)
            let detached = root.appendingPathComponent("detached-proposal",isDirectory:true)
            try fm.copyItem(at:canonical,to:replacement)
            let swap = { try fm.moveItem(at:canonical,to:detached); try fm.moveItem(at:replacement,to:canonical) }
            var hooks = CanvasDocumentFiles.Hooks()
            switch phase { case "afterExchange": hooks.afterExchange = swap; case "beforeExchange": hooks.beforeExchange = swap; default: hooks.afterGeneration = swap }
            let raced = CanvasDocumentFiles(folder:root,requiresScope:false,hooks:hooks)
            rejects(.publicationUnconfirmed,"DOC-R1 \(phase) 경로 교체는 성공이 아닌 미확인") { _ = try raced.save(proposal,previews:previews,expected:base.token) }
            let reopened = try CanvasDocumentFiles(folder:root,requiresScope:false).load(document.id)
            check(reopened.document == document && reopened.token == base.token && reopened.publicationPending,"DOC-R1 새 인스턴스의 정본 재열기와 지속 barrier")
            check(try Data(contentsOf:canonical.appendingPathComponent("current.json")) == oldHead,"DOC-R1 외부 정본 head 자동 rollback/변경 0")
            rejects(.pending,"DOC-R1 새 인스턴스 후속 쓰기도 보류") { _ = try CanvasDocumentFiles(folder:root,requiresScope:false).save(document,previews:previews,expected:reopened.token) }
            let intent = root.appendingPathComponent("document-pending-\(document.id.uuidString.lowercased()).json")
            let record = try JSONSerialization.jsonObject(with:Data(contentsOf:intent)) as! [String:Any]
            let archiveURL = root.appendingPathComponent("document-recovery-\(document.id.uuidString.lowercased())/\(record["attemptID"] as! String)")
            try archive(archiveURL.appendingPathComponent("base"),expected:document)
            try archive(archiveURL.appendingPathComponent("proposal"),expected:proposal)
            try archive(archiveURL.appendingPathComponent("external"),expected:document)
            try fm.moveItem(at:detached,to:out.appendingPathComponent("moved-away-\(phase)"))
            check(try CanvasDocumentFiles(folder:root,requiresScope:false).load(document.id).publicationPending,"DOC-R1 옛 문서 디렉터리가 폴더 밖으로 이동해도 barrier 유지")
            races.append(["phase":phase,"saveReturnedSuccess":false,"canonicalIsOriginal":true,"pendingOnCanonical":true,"rootIntent":intent.path,"archive":archiveURL.path])
        }
        var nested: [[String:Any]] = []
        for name in ["nodes","links","annotations"] {
            let rawURL = review.appendingPathComponent("nested-lock/unsupported-\(name).json")
            let raw = try Data(contentsOf:rawURL), hash = CanvasPacket.sha(raw)
            do { _ = try CanvasDocument.decode(raw); fatalError("unsupported nested accepted") }
            catch CanvasDocument.Failure.unsupported { check(true,"DOC-R2 reviewer 원본 \(name) byte 입력 전체 거부") }
            check(try Data(contentsOf:rawURL) == raw,"DOC-R2 reviewer 원본 입력 바이트 불변")
            let object = try JSONSerialization.jsonObject(with:raw) as! [String:Any]
            let legacy = try JSONSerialization.data(withJSONObject:(object["pages"] as! [[String:Any]])[0])
            do { _ = try CanvasDocument.decodeLegacy(legacy); fatalError("legacy nested accepted") }
            catch CanvasDocument.Failure.unsupported { check(true,"DOC-R2 legacy byte ingress도 \(name) 미지원 필드 거부") }
            nested.append(["type":name,"originalInputSHA256":hash,"decodeAccepted":false,"saveAccepted":false,"reopenedFieldMissing":false])
        }
        // 내부 구조의 지원 키도 명시한다. 실제 reviewer 세 원문을 위에서 그대로 검증한다.
        let paths: [[String]] = [["nodes","frame"],["strokes","points"],["strokes","visibility"],["strokes","visibility","visibleSegments"],["strokes","style"],["strokes","style","color"],["strokes","style","transform"],["strokes","style","samples"],["links","fromAnchor"],["nodes","vaultNote"],["penSettings"]]
        func inject(_ object: inout [String:Any], _ path: ArraySlice<String>) {
            guard let key = path.first else { object["futureRequiredPayload"] = ["version":9]; return }
            if var list = object[key] as? [[String:Any]] {
                if list.isEmpty { list = [[:]] }
                inject(&list[0],path.dropFirst()); object[key] = list
            } else { var item = object[key] as? [String:Any] ?? [:]; inject(&item,path.dropFirst()); object[key] = item }
        }
        for path in paths {
            var object = try JSONSerialization.jsonObject(with:document.bytes()) as! [String:Any]
            var pages = object["pages"] as! [[String:Any]]; inject(&pages[0],path[...]); object["pages"] = pages
            do { _ = try CanvasDocument.decode(JSONSerialization.data(withJSONObject:object)); fatalError("nested path accepted") }
            catch CanvasDocument.Failure.unsupported { check(true,"DOC-R2 nested 키 경계 \(path.joined(separator:"."))") }
        }
        let lockRoot = out.appendingPathComponent("lock-fixture",isDirectory:true)
        try fm.createDirectory(at:lockRoot,withIntermediateDirectories:true)
        let files = CanvasDocumentFiles(folder:lockRoot,requiresScope:false)
        let baseline = try files.save(document,previews:previews,expected:nil)
        let canonical = files.documentURL(document.id), lock = canonical.appendingPathComponent("writer.lock")
        let head = try Data(contentsOf:canonical.appendingPathComponent("current.json"))
        let holder = Process(), input = Pipe(), output = Pipe()
        holder.executableURL = URL(fileURLWithPath:args[0]); holder.arguments = ["--hold-lock",lock.path]
        holder.standardInput = input; holder.standardOutput = output
        try holder.run()
        var ready = Data()
        while let b = try output.fileHandleForReading.read(upToCount:1), !b.isEmpty, b != Data([10]) { ready.append(b) }
        precondition(String(decoding:ready,as:UTF8.self) == "LOCKED")
        let start = Date()
        rejects(.busy,"DOC-R3 별도 프로세스 lock 경합은 MainActor에서 정상 보류") { _ = try files.save(proposal,previews:previews,expected:baseline.token) }
        let elapsed = Date().timeIntervalSince(start)
        let remainedHeld = holder.isRunning
        try input.fileHandleForWriting.write(contentsOf:Data([10])); try input.fileHandleForWriting.close()
        holder.waitUntilExit()
        check(elapsed < 0.8 && remainedHeld,"DOC-R3 holder 해제 이전 즉시 반환")
        check(holder.terminationStatus == 0 && !holder.isRunning && kill(holder.processIdentifier,0) == -1 && errno == ESRCH,"DOC-R3 자체 holder 종료와 PID 부재")
        check(try Data(contentsOf:canonical.appendingPathComponent("current.json")) == head && files.load(document.id).token == baseline.token,"DOC-R3 경합은 원본 head와 전체 세대를 바꾸지 않음")
        check(try !files.load(document.id).publicationPending,"DOC-R3 단순 lock 경합을 영구 충돌로 바꾸지 않음")
        check(try files.save(proposal,previews:previews,expected:baseline.token).document == proposal,"DOC-R3 해제 후 같은 기대 token으로 정상 저장")
        let result: [String:Any] = ["count":count,"directorySwap":races,"nested":nested,"lock":["returnedBusyBeforeUnlock":true,"seconds":elapsed,"holderExited":true],"GUI":false,"device":false,"wholeDocumentAccepted":false]
        try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]).write(to:out.appendingPathComponent("repair-observations.json"))
        print("DOCUMENT_REPAIR_OK",count)
    }
}
