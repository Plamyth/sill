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
    private struct Put: Decodable { let baseSha256: String; let text: String }
    static var status = 200
    static var text = "# 原本\r\n한글 👩🏽‍💻 e\u{301}\n"
    static var calls: [String] = []
    static var cas = false
    static var loseResponse = false
    static var conflict = false
    static var writes = 0
    static var authenticated = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        Self.calls.append(method)
        Self.authenticated = Self.authenticated && request.value(forHTTPHeaderField:"X-Canvas-Token") == "test-token"
        var status = Self.status
        if Self.cas && method == "PUT" {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer,maxLength:buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf:buffer.prefix(count))
                }
            }
            let value = try! JSONDecoder().decode(Put.self,from:body)
            if Self.conflict { Self.text += "\nMac intervened" }
            if value.baseSha256 != CanvasPacket.sha(Data(Self.text.utf8)) { status = 409 }
            else {
                Self.text = value.text
                Self.writes += 1
                if Self.loseResponse {
                    client!.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost))
                    return
                }
            }
        }
        let path = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.first!.value!
        let data: Data
        if status == 200 {
            data = try! JSONSerialization.data(withJSONObject:["path":path,"text":Self.text,
                "sha256":CanvasPacket.sha(Data(Self.text.utf8)),"modifiedAt":"2026-10-19T00:00:00Z"])
        } else { data = Data("{\"error\":\"conflict or missing\"}".utf8) }
        client!.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,
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

        let healthy = store()
        await healthy.openVaultNote(original.path) { _ in original }
        _ = healthy.attachOpenedVaultNote()
        var foreignNode = healthy.scene.nodes[0]
        foreignNode.id = UUID()
        foreignNode.vaultNote = VaultNoteReference(path:original.path,sha256:original.sha256,relayAddress:"http://foreign")
        healthy.scene.nodes.append(foreignNode)
        var rejectedReads = 0
        await healthy.openVaultNote(original.path,nodeID:foreignNode.id) { _ in rejectedReads += 1; return fresh }
        check(rejectedReads == 0 && healthy.vaultNote?.sha256 == original.sha256 && !healthy.vaultBlocked,
            "rejected foreign-node open preserves the existing clean editor")
        healthy.vaultDraft = "healthy editor remains writable"
        check(healthy.vaultCanSave,"rejected open cannot invalidate the previous editor context")
        var healthyWrites = 0
        let healthySave = snapshot(healthy.vaultDraft)
        await healthy.saveVaultNote { _,base,_ in
            healthyWrites += 1
            check(base == original.sha256,"preserved editor keeps its original CAS base")
            return healthySave
        }
        check(healthyWrites == 1 && healthy.vaultNote?.sha256 == healthySave.sha256 && !healthy.vaultDirty,
            "original editor saves successfully after a rejected foreign open")

        let recovery = store()
        await recovery.openVaultNote(original.path) { _ in original }
        let recoveryID = recovery.attachOpenedVaultNote()!
        _ = recovery.closeVaultEditor()
        await recovery.openVaultNote(original.path,nodeID:recoveryID) { _ in original }
        recovery.setNoteConnection(address:"http://different",token:"other-token")
        var recoveryReads = 0
        await recovery.openVaultNote(original.path) { _ in recoveryReads += 1; return fresh }
        check(recoveryReads == 0 && recovery.vaultBlocked && recovery.vaultDraft == original.text,
            "read-original recovery retains linked node ownership across relay changes")

        let reopening = store(), openingGate = NoteGate()
        await reopening.openVaultNote(original.path) { _ in original }
        let reopenedID = reopening.attachOpenedVaultNote()!
        _ = reopening.closeVaultEditor()
        let opening = Task { await reopening.openVaultNote(original.path,nodeID:reopenedID,load:openingGate.load) }
        await openingGate.wait()
        await reopening.refreshVaultNotes { _ in fresh }
        openingGate.finish(original); await opening.value
        check(reopening.scene.nodes[0].text == fresh.text && reopening.vaultDraft == fresh.text,
            "older editor GET cannot regress a newer polled source or editor")

        let repolling = store(), stalePollGate = NoteGate()
        await repolling.openVaultNote(original.path) { _ in original }
        let repollID = repolling.attachOpenedVaultNote()!
        _ = repolling.closeVaultEditor()
        let stalePoll = Task { await repolling.refreshVaultNotes(load:stalePollGate.load) }
        await stalePollGate.wait()
        await repolling.openVaultNote(original.path,nodeID:repollID) { _ in fresh }
        stalePollGate.finish(original); await stalePoll.value
        check(repolling.scene.nodes[0].text == fresh.text && repolling.vaultDraft == fresh.text,
            "older poll cannot regress a newer editor read")

        let savedAfterPoll = store(), obsoleteFailure = NoteGate()
        await savedAfterPoll.openVaultNote(original.path) { _ in original }
        let obsoletePoll = Task { await savedAfterPoll.refreshVaultNotes(load:obsoleteFailure.load) }
        await obsoleteFailure.wait()
        savedAfterPoll.vaultDraft = "saved after polling began"
        let acknowledged = snapshot(savedAfterPoll.vaultDraft)
        await savedAfterPoll.saveVaultNote { _,_,_ in acknowledged }
        obsoleteFailure.fail(); await obsoletePoll.value
        await savedAfterPoll.refreshVaultNotes { _ in acknowledged }
        savedAfterPoll.vaultDraft = "next edit"
        check(!savedAfterPoll.vaultBlocked && savedAfterPoll.vaultCanSave,
            "obsolete poll failure cannot block an acknowledged save and next edit")

        let readAfterPoll = store(), supersededFailure = NoteGate()
        await readAfterPoll.openVaultNote(original.path) { _ in original }
        let supersededPoll = Task { await readAfterPoll.refreshVaultNotes(load:supersededFailure.load) }
        await supersededFailure.wait()
        await readAfterPoll.refreshVaultNotes { _ in original }
        supersededFailure.fail(); await supersededPoll.value
        check(!readAfterPoll.vaultBlocked,
            "older failed poll cannot poison a newer accepted read with the same SHA")

        let normalization = store()
        let composed = snapshot("é"), decomposed = snapshot("e\u{301}")
        await normalization.openVaultNote(composed.path) { _ in composed }
        normalization.vaultDraft = decomposed.text
        check(normalization.vaultDirty && !normalization.closeVaultEditor(),
            "normalization-only byte changes remain dirty and cannot be silently closed")

        let normalizedSave = store()
        await normalizedSave.openVaultNote(original.path) { _ in original }
        normalizedSave.vaultDraft = composed.text
        await normalizedSave.saveVaultNote { _,_,_ in decomposed }
        check(normalizedSave.vaultBlocked && normalizedSave.vaultNote?.sha256 == original.sha256 &&
            normalizedSave.vaultDraft.utf8.elementsEqual(composed.text.utf8),
            "store rejects canonically equal save acknowledgements with different UTF-8 bytes")

        let unicode = store(), unicodeNote = snapshot(String(repeating:"한글 👩🏽‍💻",count:100))
        await unicode.openVaultNote(unicodeNote.path) { _ in unicodeNote }
        _ = unicode.attachOpenedVaultNote()
        let preview = unicode.scene.nodes[0]
        check(preview.text.utf8.count <= 512 && unicodeNote.text.hasPrefix(preview.text) &&
            preview.vaultNote?.cacheTruncated == true && unicode.vaultDraft == unicodeNote.text,
            "bounded Unicode preview is marked while editor retains the complete source")

        let large = store()
        for index in 0..<5 {
            let note = snapshot(String(repeating:"x",count:900*1024),path:"Notes/large-\(index).md")
            await large.openVaultNote(note.path) { _ in note }
            _ = large.attachOpenedVaultNote()
            _ = large.closeVaultEditor()
        }
        large.saveNow()
        let restoredLarge = CanvasStore()
        check(restoredLarge.scene == large.scene && restoredLarge.scene.nodes.count == 5,
            "five valid large linked notes remain restorable with their scene identity")
        check(try JSONEncoder().encode(large.scene).count < 1024*1024,
            "linked display previews do not serialize entire large source notes")
        let sceneFile = support.appendingPathComponent("CanvasScene.json")
        let retainedBytes = try Data(contentsOf:sceneFile)
        large.scene.nodes.append(CanvasNode(id:UUID(),kind:.note,frame:frame,
            text:String(repeating:"z",count:5*1024*1024),confidence:.confirmed,sourceStrokeIds:[]))
        large.saveNow()
        check(try Data(contentsOf:sceneFile) == retainedBytes,
            "unrestorable scene cannot overwrite the last valid saved scene")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoteProtocol.self]
        let relay = CanvasRelay(address:"http://test",token:"test-token",session:URLSession(configuration:config))
        NoteProtocol.status = 200; NoteProtocol.text = decomposed.text
        do {
            _ = try await relay.saveVaultNote(at:original.path,baseSha256:original.sha256,text:composed.text)
            check(false,"Relay rejects normalized save acknowledgement bytes")
        } catch { check(true,"Relay rejects normalized save acknowledgement bytes") }
        NoteProtocol.text = original.text
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
        let hierarchy = store()
        let parent = hierarchy.scene.addNode(kind:.note,at:CanvasPoint(x:0,y:0),text:"Parent")
        let child = hierarchy.scene.addNode(kind:.note,at:CanvasPoint(x:300,y:0),text:"Child")
        let other = hierarchy.scene.addNode(kind:.note,at:CanvasPoint(x:600,y:0),text:"Other")
        hierarchy.scene.nodes[0].vaultNote = VaultNoteReference(path:original.path,sha256:original.sha256,relayAddress:"http://test")
        let preservedNodes = hierarchy.scene.nodes
        let preservedDrawing = hierarchy.scene.drawingBase64
        hierarchy.selectedNode = parent
        hierarchy.beginChildLink()
        check(hierarchy.mode == .select && hierarchy.linkStart == parent,"child action selects existing parent and enters element mode")
        hierarchy.select(child)
        check(hierarchy.scene.links.count == 1 && hierarchy.scene.links[0].kind == .parentChild &&
            hierarchy.scene.links[0].from == parent && hierarchy.scene.links[0].to == child,
            "selecting child commits semantic hierarchy")
        check(hierarchy.linkStart == nil && hierarchy.selectedNode == child,"successful hierarchy consumes pending action")
        check(hierarchy.scene.nodes == preservedNodes && hierarchy.scene.drawingBase64 == preservedDrawing && hierarchy.scene.strokes.isEmpty,
            "hierarchy action preserves source references, node data and ink")
        let beforeCycle = hierarchy.scene
        hierarchy.beginChildLink(); hierarchy.select(parent)
        check(hierarchy.scene == beforeCycle && hierarchy.status.contains("연결하지 않았습니다"),"cycle rejected without false success or scene mutation")
        hierarchy.selectedNode = other; hierarchy.beginChildLink(); hierarchy.select(child)
        check(hierarchy.scene == beforeCycle,"second parent rejected atomically")
        hierarchy.selectedNode = parent; hierarchy.beginChildLink(); hierarchy.select(UUID())
        check(hierarchy.scene == beforeCycle && hierarchy.linkStart == nil,"missing target cancels pending command without mutation")
        hierarchy.beginChildLink(); hierarchy.cancelLink()
        check(hierarchy.linkStart == nil && hierarchy.scene == beforeCycle,"explicit cancel preserves scene")
        hierarchy.beginChildLink(); hierarchy.select(parent)
        check(hierarchy.linkStart == nil && hierarchy.scene == beforeCycle,"same element tap cancels rather than latching")
        hierarchy.beginChildLink(); hierarchy.mode = .pen
        check(hierarchy.linkStart == nil,"leaving element mode cancels connection")
        hierarchy.beginChildLink(); hierarchy.selectedNode = other
        check(hierarchy.linkStart == nil,"selection changed outside select cancels pending command")
        hierarchy.selectedNode = child; hierarchy.beginLink(); hierarchy.select(parent)
        check(hierarchy.scene.links.count == 2 && hierarchy.scene.links.last?.kind == nil,
            "ordinary reverse arrow keeps legacy general semantics")
        let beforeUnlinkRevision = hierarchy.scene.revision
        hierarchy.selectedNode = child; hierarchy.unlinkFromParent()
        check(hierarchy.scene.links.count == 1 && hierarchy.scene.links[0].kind == nil &&
            hierarchy.scene.links[0].from == child && hierarchy.scene.links[0].to == parent,
            "unlink removes hierarchy only and preserves ordinary relation")
        check(hierarchy.scene.revision == beforeUnlinkRevision + 1 && hierarchy.scene.nodes == preservedNodes &&
            hierarchy.scene.drawingBase64 == preservedDrawing,"unlink increments revision once and preserves original data")
        let noParent = hierarchy.scene
        hierarchy.unlinkFromParent()
        check(hierarchy.scene == noParent,"unlink without parent is no-op")
        hierarchy.selectedNode = parent; hierarchy.beginChildLink()
        hierarchy.scene.nodes.removeAll { $0.id == parent }
        check(hierarchy.linkStart == nil,"removed source cancels pending command")
        hierarchy.selectedNode = child; hierarchy.beginChildLink()
        var imported = CanvasScene(); imported.drawingBase64 = PKDrawing().dataRepresentation().base64EncodedString()
        try hierarchy.importScene(imported)
        check(hierarchy.linkStart == nil && hierarchy.selectedNode == nil,"scene import invalidates pending connection and selection")
        hierarchy.selectedNode = UUID(); hierarchy.beginChildLink()
        check(hierarchy.linkStart == nil,"missing selected source does not arm connection")
        try await checkBlockExcerpts(check)
        print("RESULT \(checks) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
