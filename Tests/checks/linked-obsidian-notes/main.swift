import Foundation
import PencilKit
import AppKit

@MainActor final class NoteGate {
    private var continuation: CheckedContinuation<VaultNoteSnapshot, Error>?
    var waiting = false
    func load(_ path: String) async throws -> VaultNoteSnapshot {
        try await withCheckedThrowingContinuation { continuation = $0; waiting = true }
    }
    func wait() async { while !waiting { await Task.yield() } }
    func finish(_ note: VaultNoteSnapshot) { continuation!.resume(returning:note); continuation = nil }
    func fail() { continuation!.resume(throwing:URLError(.timedOut)); continuation = nil }
}

final class NoteProtocol: URLProtocol {
    static var status = 200
    static var text = "# 原本\r\n한글 👩🏽‍💻 e\u{301}\n"
    static var calls: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        Self.calls.append(method)
        let path = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.first!.value!
        let data: Data
        if Self.status == 200 {
            data = try! JSONSerialization.data(withJSONObject:["path":path,"text":Self.text,
                "sha256":CanvasPacket.sha(Data(Self.text.utf8)),"modifiedAt":"2026-10-19T00:00:00Z"])
        } else { data = Data("{\"error\":\"conflict or missing\"}".utf8) }
        client!.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:Self.status,
            httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client!.urlProtocol(self,didLoad:data)
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct LinkedNotesCheck {
    @MainActor static func main() async throws {
        let expectedHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        precondition(support.path.hasPrefix(expectedHome + "/"),"Refusing real application support")
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        func snapshot(_ text: String, path: String = "Notes/test.md") -> VaultNoteSnapshot {
            VaultNoteSnapshot(path:path,text:text,sha256:CanvasPacket.sha(Data(text.utf8)),modifiedAt:"now")
        }
        func store() -> CanvasStore {
            let s = CanvasStore()
            s.scene = CanvasScene()
            s.drawing = PKDrawing()
            s.scene.drawingBase64 = s.drawing.dataRepresentation().base64EncodedString()
            s.setNoteConnection(address:"http://test",token:"test-token")
            return s
        }
        let original = snapshot("# 原本\r\n한글 👩🏽‍💻 e\u{301}\n")
        let fresh = snapshot("# agent edited\n")
        let s = store()
        await s.openVaultNote(original.path) { _ in original }
        let first = s.attachOpenedVaultNote()!
        _ = s.attachOpenedVaultNote()!
        let frame = s.scene.nodes[0].frame
        let strokeID = UUID()
        s.scene.nodes[0].sourceStrokeIds = [strokeID]
        let legacyNode = CanvasNode(id:UUID(),kind:.note,frame:frame,text:"plain",confidence:.confirmed,sourceStrokeIds:[])
        let legacy = try JSONEncoder().encode(legacyNode)
        check(!String(decoding:legacy,as:UTF8.self).contains("vaultNote"),"legacy JSON omits optional reference")
        check(try JSONDecoder().decode(CanvasNode.self,from:legacy).vaultNote == nil,"legacy JSON decodes")
        let linkedRoundTrip = try JSONDecoder().decode(CanvasScene.self,from:JSONEncoder().encode(s.scene))
        check(linkedRoundTrip == s.scene,"linked scene JSON round trip preserves reference and cache")
        check(!s.scene.confirmNode(first,text:"bypass"),"model refuses linked confirmNode bypass")
        s.proposedNode = first; s.proposalText = "bypass"; s.confirmProposal()
        check(s.scene.nodes[0].text == original.text,"store refuses linked confirmProposal bypass")
        var proposal = s.scene.nodes[0]; proposal.id = UUID(); proposal.confidence = .proposal
        let beforeAgent = s.scene
        check(!s.scene.apply(AgentRevision(sceneId:s.scene.id,baseRevision:s.scene.revision,
            annotations:[],proposedNodes:[proposal])) && s.scene == beforeAgent,
            "agent cannot introduce a source reference through scene revisions")
        var refreshReads = 0
        await s.refreshVaultNotes { _ in refreshReads += 1; return fresh }
        check(refreshReads == 1,"duplicate-path nodes share one source GET per refresh")
        check(s.scene.nodes.allSatisfy { $0.text == fresh.text && $0.vaultNote?.sha256 == fresh.sha256 },
            "duplicate-path nodes refresh only verified cache and source SHA")
        check(s.scene.nodes[0].frame == frame && s.scene.nodes[0].sourceStrokeIds == [strokeID],
            "cache refresh preserves geometry and stroke provenance")
        check(s.vaultNote?.text == fresh.text && s.vaultDraft == fresh.text,"clean editor receives canonical text")
        s.vaultDraft = "local draft"
        await s.refreshVaultNotes { _ in snapshot("remote second change") }
        check(s.vaultDraft == "local draft" && s.vaultBlocked,"dirty refresh preserves input and blocks blind save")
        check(!s.closeVaultEditor() && s.vaultDraft == "local draft","dirty close/navigation refuses")
        do { try s.importScene(CanvasScene()); check(false,"dirty import refuses") }
        catch { check(s.vaultDraft == "local draft","dirty import preserves draft") }
        check(s.closeVaultEditor(discard:true) && s.vaultNote == nil,"explicit discard closes editor")

        let typing = store()
        await typing.openVaultNote(original.path) { _ in original }
        _ = typing.attachOpenedVaultNote()
        typing.vaultDraft = "submitted"
        let saveGate = NoteGate()
        var submittedBase = "", submittedText = ""
        let saveTask = Task { await typing.saveVaultNote { path, base, text in
            submittedBase = base; submittedText = text
            return try await saveGate.load(path)
        } }
        await saveGate.wait()
        check(!typing.closeVaultEditor(discard:true),"even explicit discard waits for outstanding PUT")
        typing.vaultDraft = "typed while saving"
        saveGate.finish(snapshot("submitted")); await saveTask.value
        check(submittedBase == original.sha256 && submittedText == "submitted","PUT freezes original CAS base and submitted text")
        check(typing.vaultDraft == "typed while saving" && typing.vaultNote?.text == "submitted" && typing.vaultCanSave,
            "save response advances base without overwriting newer input")
        check(typing.scene.nodes[0].text == "submitted","node cache contains saved source, never unsubmitted draft")

        for mutation in ["connection", "scene", "editor", "path", "same-scene import"] {
            let state = store(), gate = NoteGate()
            let task = Task { await state.openVaultNote(original.path,load:gate.load) }
            await gate.wait()
            switch mutation {
            case "connection":
                state.setNoteConnection(address:"http://elsewhere",token:"new")
                state.setNoteConnection(address:"http://test",token:"test-token")
            case "scene": state.scene = CanvasScene()
            case "editor": _ = state.closeVaultEditor()
            case "path": await state.openVaultNote("Notes/other.md") { _ in snapshot("other",path:"Notes/other.md") }
            default: try state.importScene(state.scene)
            }
            let before = state.vaultNote
            gate.finish(original); await task.value
            check(state.vaultNote == before,"stale GET rejected after \(mutation)")
        }
        for mutation in ["connection", "scene", "editor", "path"] {
            let state = store(), gate = NoteGate()
            await state.openVaultNote(original.path) { _ in original }
            let node = state.attachOpenedVaultNote()!
            _ = state.closeVaultEditor()
            await state.openVaultNote(original.path,nodeID:node) { _ in original }
            state.vaultDraft = "submitted"
            let task = Task { await state.saveVaultNote { path,_,_ in try await gate.load(path) } }
            await gate.wait()
            if mutation == "scene" { state.scene = CanvasScene() }
            else if mutation == "path" {
                state.scene.nodes[0].vaultNote = VaultNoteReference(path:"Notes/other.md",sha256:original.sha256,relayAddress:"http://test")
            } else {
                state.setNoteConnection(address:"http://elsewhere",token:"new")
                if mutation == "editor" { _ = state.closeVaultEditor(discard:true) }
            }
            let beforeDraft = state.vaultDraft, beforeBase = state.vaultNote
            gate.finish(snapshot("submitted")); await task.value
            check(state.vaultDraft == beforeDraft && state.vaultNote == beforeBase,"stale PUT rejected after \(mutation)")
        }
        let poll = store(), pollGate = NoteGate()
        await poll.openVaultNote(original.path) { _ in original }
        let pollTask = Task { await poll.refreshVaultNotes(load:pollGate.load) }
        await pollGate.wait()
        poll.vaultDraft = "new typing"
        pollGate.finish(fresh); await pollTask.value
        check(poll.vaultDraft == "new typing" && poll.vaultNote?.sha256 == original.sha256,
            "poll started before typing cannot replace the editor base or draft")

        let overlap = store(), older = NoteGate(), newer = NoteGate()
        await overlap.openVaultNote(original.path) { _ in original }
        _ = overlap.attachOpenedVaultNote()
        let oldPoll = Task { await overlap.refreshVaultNotes(load:older.load) }
        await older.wait()
        let newPoll = Task { await overlap.refreshVaultNotes(load:newer.load) }
        await newer.wait()
        newer.finish(fresh); await newPoll.value
        older.finish(original); await oldPoll.value
        check(overlap.scene.nodes[0].text == fresh.text && overlap.vaultDraft == fresh.text,
            "late older poll cannot regress verified cache or editor base")

        let failed = store(), failedGate = NoteGate()
        let failedOpen = Task { await failed.openVaultNote(original.path,load:failedGate.load) }
        await failedGate.wait()
        await failed.openVaultNote("Notes/other.md") { _ in snapshot("newer editor",path:"Notes/other.md") }
        failedGate.fail(); await failedOpen.value
        check(failed.vaultNote?.path == "Notes/other.md" && failed.vaultDraft == "newer editor" && !failed.vaultBlocked,
            "late GET failure cannot poison newer editor")

        let foreign = store()
        await foreign.openVaultNote(original.path) { _ in original }
        let foreignID = foreign.attachOpenedVaultNote()!
        _ = foreign.closeVaultEditor()
        foreign.setNoteConnection(address:"http://different",token:"test-token")
        var foreignReads = 0
        await foreign.openVaultNote(original.path,nodeID:foreignID) { _ in foreignReads += 1; return original }
        check(foreignReads == 0 && foreign.vaultNote == nil,
            "linked node cannot silently bind to a different relay")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoteProtocol.self]
        let relay = CanvasRelay(address:"http://test",token:"test-token",session:URLSession(configuration:config))
        let api = store()
        NoteProtocol.status = 200; NoteProtocol.calls = []
        await api.openVaultNote(original.path,load:relay.vaultNote)
        _ = api.attachOpenedVaultNote()
        await api.refreshVaultNotes(load:relay.vaultNote)
        check(NoteProtocol.calls == ["GET","GET"],"open/attach/cache polling use existing GET API without writes")
        api.vaultDraft = "do not lose"
        NoteProtocol.status = 409
        await api.saveVaultNote { path,base,text in try await relay.saveVaultNote(at:path,baseSha256:base,text:text) }
        check(api.vaultDraft == "do not lose" && api.vaultBlocked && NoteProtocol.calls.last == "PUT",
            "actual Relay HTTP 409 preserves draft and blocks retries")
        let callCount = NoteProtocol.calls.count
        await api.saveVaultNote { path,base,text in try await relay.saveVaultNote(at:path,baseSha256:base,text:text) }
        check(NoteProtocol.calls.count == callCount,"blocked conflict does not retry PUT")
        NoteProtocol.status = 404
        await api.refreshVaultNotes(load:relay.vaultNote)
        check(api.vaultDraft == "do not lose" && api.scene.nodes[0].text == original.text,
            "missing source keeps draft and last verified cache")
        _ = api.closeVaultEditor(discard:true)
        await api.openVaultNote("Notes/missing.md",load:relay.vaultNote)
        check(api.vaultNote == nil && api.vaultBlocked && NoteProtocol.calls.last == "GET",
            "missing source is refused without recreation")
        for invalid in ["../note.md", "/note.md", "a//b.md", ".obsidian/a.md", "a\\b.md", "note.txt"] {
            check(!VaultNoteReference.validPath(invalid),"invalid source path refused: \(invalid)")
        }
        do { _ = try snapshot("bad",path:"Notes/other.md").validated(at:original.path); check(false,"wrong path") }
        catch { check(true,"mismatched response path refused") }
        let invalidHash = VaultNoteSnapshot(path:original.path,text:"tamper",sha256:original.sha256,modifiedAt:"now")
        do { _ = try invalidHash.validated(at:original.path); check(false,"bad hash") }
        catch { check(true,"mismatched cache hash refused") }
        print("RESULT \(checks) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
