import Foundation
#if !REVIEW_MODEL_ONLY
import PencilKit
#endif

@MainActor final class ReviewGate {
    private var continuation: CheckedContinuation<VaultNoteSnapshot,Error>?
    var waiting = false
    func load(_ path: String) async throws -> VaultNoteSnapshot {
        try await withCheckedThrowingContinuation { continuation = $0; waiting = true }
    }
    func wait() async { while !waiting { await Task.yield() } }
    func finish(_ note: VaultNoteSnapshot) { continuation!.resume(returning:note); continuation = nil }
}

@MainActor final class ReviewFile {
    let url: URL
    var writes = 0
    init(root: URL, text: String) throws {
        url = root.appendingPathComponent(UUID().uuidString + ".md")
        try Data(text.utf8).write(to:url)
    }
    func load(_ path: String) throws -> VaultNoteSnapshot {
        let data = try Data(contentsOf:url)
        return VaultNoteSnapshot(path:path,text:String(decoding:data,as:UTF8.self),
            sha256:CanvasPacket.sha(data),modifiedAt:"fixture")
    }
    func save(_ path: String, _ sha: String, _ text: String) throws -> VaultNoteSnapshot {
        guard try load(path).sha256 == sha else { throw NSError(domain:"CanvasRelay",code:409) }
        try Data(text.utf8).write(to:url,options:.atomic)
        writes += 1
        return try load(path)
    }
}

@main struct ReviewChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["CCR_REVIEW_ROOT"]!)
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--preferences-readback" {
            let suite = CommandLine.arguments[2], expected = CommandLine.arguments[3]
            precondition(suite.hasPrefix(root.path + "/"))
            let values = UserDefaults(suiteName:suite)!.persistentDomain(forName:suite)
            let actual = values?["scope"] as? String
            precondition(expected == "absent" ? actual == nil : actual == expected)
            print("PREFERENCES_CHILD \(expected)")
            return
        }
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        precondition(support.path.hasPrefix(root.path + "/"),"실사용 상태 경로 거부")
        var assertions = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            assertions += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let suite = root.appendingPathComponent("preferences/review-fixture").path
        let plist = URL(fileURLWithPath:suite + ".plist")
        try FileManager.default.createDirectory(at:plist.deletingLastPathComponent(),withIntermediateDirectories:true)
        let defaults = UserDefaults(suiteName:suite)!
        defaults.set("isolated",forKey:"scope")
        check(defaults.synchronize(),"절대 경로 preferences 쓰기 동기화")
        func preferencePlist(_ expected: String?) throws -> [String:Any] {
            let deadline = Date().addingTimeInterval(3)
            repeat {
                if let data = try? Data(contentsOf:plist),
                   let values = try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
                   values["scope"] as? String == expected { return values }
                Thread.sleep(forTimeInterval:0.02)
            } while Date() < deadline
            throw URLError(.timedOut)
        }
        let preferenceValues = try preferencePlist("isolated")
        let preferenceBytes = try Data(contentsOf:plist)
        check(plist.path.hasPrefix(root.path + "/") && preferenceValues["scope"] as? String == "isolated",
              "테스트 plist 물리 위치와 저장된 키 확인")
        func preferenceReadback(_ expected: String) throws -> Bool {
            let child = Process()
            child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
            child.arguments = ["--preferences-readback",suite,expected]
            try child.run()
            child.waitUntilExit()
            return child.terminationStatus == 0
        }
        check(try preferenceReadback("isolated"),"별도 프로세스에서 절대 suite 키 복원")
        defaults.removeObject(forKey:"scope")
        check(defaults.synchronize(),"승인된 fixture의 추가 키만 공식 API로 정리")
        let cleaned = try preferencePlist(nil)
        check(try cleaned["scope"] == nil && preferenceReadback("absent"),"물리 plist와 별도 프로세스에서 테스트 키 부재 확인")
        let preferencesReceipt: [String:Any] = [
            "suite":suite,"plist":plist.path,"writtenPlistSHA256":CanvasPacket.sha(preferenceBytes),
            "childReadback":true,"scopeRemoved":true,"domainDeletion":false]
        print("PREFERENCES_RECEIPT " + String(decoding:try JSONSerialization.data(
            withJSONObject:preferencesReceipt,options:[.sortedKeys]),as:UTF8.self))
        func rejects(_ text: String) -> Bool {
            do { _ = try VaultReviewCard.parse(text); return false } catch { return true }
        }
        let original = "\u{feff}---\r\ntitle: 그대로\r\n---\r\n# 가방 👩🏽‍💻 e\u{301}\r\n\r\n문단 ^keep\r\n"
        let template = try VaultReviewCard.insertingTemplate(in:original,
            cardID:UUID(uuidString:"11111111-1111-4111-8111-111111111111")!)
        let empty = try VaultReviewCard.parse(template)!
        check(!empty.ready && empty.metadata.eventID == nil,"빈 틀은 확정 질문·답이 아님")
        check(template.utf8.starts(with:original.utf8),"BOM·CRLF·조합문자 원문 접두 바이트 보존")
        let cardText = template.replacingOccurrences(of:"<!-- ccr-review-front -->\r\n\r\n",
            with:"<!-- ccr-review-front -->\r\n**가방**은 어디?\r\n")
            .replacingOccurrences(of:"<!-- ccr-review-back -->\r\n\r\n",
            with:"<!-- ccr-review-back -->\r\n- 답: e\u{301} 👩🏽‍💻\r\n") + "\r\n끝 문단\u{feff}\r\n"
        let card = try VaultReviewCard.parse(cardText)!
        check(card.ready && card.front == "**가방**은 어디?\r\n" && card.back.hasPrefix("- 답:"),"Markdown 질문·답 해석")
        let event = UUID(uuidString:"22222222-2222-4222-8222-222222222222")!
        let now = Date(timeIntervalSince1970:1_800_000_000.8)
        let rated = try card.ratingGood(eventID:event,injectedDate:now)
        let parsed = try VaultReviewCard.parse(rated)!
        check(parsed.metadata.ratedAt == 1_800_000_000 && parsed.metadata.dueAt == 1_800_086_400,
              "주입 시각·고정 86400초 저장")
        check(parsed.metadata.cardID == card.metadata.cardID && parsed.metadata.eventID == event.uuidString.lowercased(),"카드 ID 유지·평가 ID 영속화")
        check(parsed.front.utf8.elementsEqual(card.front.utf8) && parsed.back.utf8.elementsEqual(card.back.utf8),"평가가 질문·답 바이트를 바꾸지 않음")
        let suffix = "\r\n끝 문단\u{feff}\r\n"
        check(rated.utf8.starts(with:original.utf8) && rated.utf8.suffix(suffix.utf8.count).elementsEqual(suffix.utf8),"평가 전후 구역 밖 바이트 보존")
        check(try parsed.ratingGood(eventID:event,injectedDate:now.addingTimeInterval(10)) == rated,"동일 이벤트는 기한을 다시 늘리지 않음")
        check(try VaultReviewCard.parse("아무 표식 없는 노트") == nil,"기존 일반 노트 계약 유지")
        let invalid = [
            cardText + cardText, cardText.replacingOccurrences(of:"<!-- /ccr-review-card -->",with:""),
            cardText.replacingOccurrences(of:"ccr-review-card:v1",with:"ccr-review-card:v2"),
            cardText.replacingOccurrences(of:card.metadata.cardID,with:"fake"),
            cardText.replacingOccurrences(of:card.metadata.cardID,with:"00000000-0000-0000-0000-000000000000"),
            cardText.replacingOccurrences(of:"\"dueAt\":null",with:"\"dueAt\":1"),
            rated.replacingOccurrences(of:"1800086400",with:"1800086401"),
            rated.replacingOccurrences(of:"1800000000",with:"-1"),
            cardText.replacingOccurrences(of:"\"dueAt\":null",with:"\"dueAt\":null,\"dueAt\":null"),
            cardText.replacingOccurrences(of:"\"dueAt\":null",with:"\"dueAt\":null,\"extra\":1"),
            cardText.replacingOccurrences(of:"<!-- ccr-review-back -->",with:" <!-- ccr-review-back -->"),
            "```md\n" + cardText + "\n```", "---\n" + cardText.replacingOccurrences(of:original,with:"") + "\n---",
            "<!--\n" + cardText + "\n-->",
            "ccr-review-card 누락", cardText + "\n<!-- ccr-review-front -->",
            rated.replacingOccurrences(of:"1800000000",with:"9223372036854775807"),
            cardText.replacingOccurrences(of:"\"ratedAt\":null",with:"\"ratedAt\":1.5")]
        for (index,text) in invalid.enumerated() { check(rejects(text),"불완전·중복·위조·미지원 표식 거부 \(index)") }
        for date in [Date(timeIntervalSince1970:-1),Date(timeIntervalSince1970:.infinity),
                     Date(timeIntervalSince1970:253_402_300_799)] {
            do { _ = try card.ratingGood(eventID:UUID(),injectedDate:date); check(false,"범위 밖 시각 거부") }
            catch { check(true,"범위 밖 시각 거부") }
        }
        do { _ = try empty.ratingGood(eventID:event,injectedDate:now); check(false,"빈 답 평가 거부") }
        catch { check(true,"빈 답 평가 거부") }

        #if !REVIEW_MODEL_ONLY
        func makeStore(journal: URL? = nil, scene: CanvasScene? = nil) -> CanvasStore {
            let value = CanvasStore(blockRecoveryURL:root.appendingPathComponent(UUID().uuidString + ".block"),
                noteRecoveryURL:journal ?? root.appendingPathComponent(UUID().uuidString + ".note"))
            value.scene = scene ?? CanvasScene()
            value.setNoteConnection(address:"http://fixture",token:"fixture-only")
            return value
        }
        let path = "Notes/review.md"
        let file = try ReviewFile(root:root,text:cardText), store = makeStore()
        await store.openVaultNote(path,load:file.load)
        let nodeID = store.scene.addNode(kind:.note,at:CanvasPoint(x:10,y:20),text:"보존")
        store.scene.nodes[0].sourceStrokeIds = [UUID()]
        let nodes = store.scene.nodes
        let session = store.beginVaultReview()!
        let confirmed = await store.rateVaultReviewGood(session,injectedDate:now,save:file.save,load:file.load)
        check(confirmed && file.writes == 1 && !store.vaultDirty,"평가 자동 저장·GET 재조회 확인")
        check(store.scene.nodes == nodes && store.scene.nodes[0].id == nodeID,"연결 없는 요소·원본 획 계보·텍스트 보존")
        check(store.closeVaultEditor(),"평가 뒤 편집기 정상 닫기")
        let reopened = makeStore()
        await reopened.openVaultNote(path,load:file.load)
        check(try VaultReviewCard.parse(reopened.vaultDraft)?.metadata.eventID == session.id.uuidString.lowercased(),"새 Store에서 파일 재열기 평가·기한 보존")
        check(!(await reopened.rateVaultReviewGood(session,injectedDate:now,save:file.save,load:file.load)) && file.writes == 1,
              "다른 편집 세션에 이전 평가 콜백 거부")
        let aiText = try file.load(path).text.replacingOccurrences(of:"어디?",with:"무엇?")
        try Data(aiText.utf8).write(to:file.url,options:.atomic)
        await reopened.refreshVaultNotes(load:file.load)
        check(reopened.vaultDraft.utf8.elementsEqual(aiText.utf8) && reopened.beginVaultReview()?.card.front.contains("무엇?") == true,
              "외부 Markdown 수정 → refresh → 카드 앞면 수용")

        for mutation in ["selection","node","draft","busy","connection","scene","reopen","sha"] {
            let source = try ReviewFile(root:root,text:cardText), value = makeStore()
            await value.openVaultNote(path,load:source.load)
            let targetNode = value.scene.addNode(kind:.note,at:CanvasPoint(x:0,y:0),text:"선택 대상")
            let captured = value.beginVaultReview()!
            switch mutation {
            case "selection": value.vaultSelection = NSRange(location:1,length:0)
            case "node": value.selectedNode = targetNode
            case "draft": value.vaultDraft += "새 입력"
            case "busy": value.vaultInputBusy = true
            case "connection": value.setNoteConnection(address:"http://other",token:"other")
            case "scene": value.scene = CanvasScene()
            case "reopen":
                _ = value.closeVaultEditor()
                await value.openVaultNote("Notes/other.md",load:source.load)
            default:
                try Data((cardText + "Mac 수정").utf8).write(to:source.url)
                await value.refreshVaultNotes(load:source.load)
            }
            let before = value.vaultDraft
            let result = await value.rateVaultReviewGood(captured,injectedDate:now,save:source.save,load:source.load)
            check(!result && source.writes == 0 && value.vaultDraft.utf8.elementsEqual(before.utf8),"캡처 이후 \(mutation) 변경은 전송·덮어쓰기 0")
        }

        let duplicateFile = try ReviewFile(root:root,text:cardText), duplicate = makeStore(), gate = ReviewGate()
        await duplicate.openVaultNote(path,load:duplicateFile.load)
        let attempt = duplicate.beginVaultReview()!
        let saving = Task { await duplicate.rateVaultReviewGood(attempt,injectedDate:now,save:{ path,sha,text in
            let saved = try duplicateFile.save(path,sha,text)
            _ = try await gate.load(path)
            return saved
        },load:duplicateFile.load) }
        await gate.wait()
        let again = await duplicate.rateVaultReviewGood(attempt,injectedDate:now,save:duplicateFile.save,load:duplicateFile.load)
        check(!again && duplicateFile.writes == 1,"진행 중 중복 탭은 같은 이벤트 추가 저장 0")
        duplicate.vaultDraft += "\n저장 중 새 입력"
        let later = duplicate.vaultDraft
        gate.finish(try duplicateFile.load(path))
        check(!(await saving.value) && duplicate.vaultDraft == later && duplicate.vaultDirty,"늦은 저장 응답이 동시 입력을 덮거나 저장 완료로 표시하지 않음")

        for mode in ["lost","readback","wrong-response","conflict","readback-changed"] {
            let source = try ReviewFile(root:root,text:cardText), journal = root.appendingPathComponent(UUID().uuidString + ".note")
            let value = makeStore(journal:journal)
            await value.openVaultNote(path,load:source.load)
            let captured = value.beginVaultReview()!, scene = value.scene
            let result = await value.rateVaultReviewGood(captured,injectedDate:now,save:{ path,sha,text in
                if mode == "conflict" { try Data((cardText + "외부 수정").utf8).write(to:source.url) }
                let saved = try source.save(path,sha,text)
                if mode == "lost" { throw URLError(.networkConnectionLost) }
                if mode == "wrong-response" {
                    return VaultNoteSnapshot(path:path,text:text,sha256:String(repeating:"0",count:64),modifiedAt:"fixture")
                }
                return saved
            },load:{ path in
                if mode == "readback" { throw URLError(.timedOut) }
                if mode == "readback-changed" {
                    let saved = try source.load(path)
                    try Data((saved.text + "저장 직후 외부 수정").utf8).write(to:source.url)
                }
                return try source.load(path)
            })
            check(!result && value.vaultBlocked && value.noteRecovery?.submittedText != nil,"\(mode) 결과 미확인은 성공 표시 없이 기존 저널 보존")
            let record = value.noteRecovery!, pending = try VaultReviewCard.parse(record.draft)!
            check(pending.metadata.eventID == captured.id.uuidString.lowercased(),"\(mode) 재시도용 ID를 새로 만들지 않음")
            let recovered = makeStore(journal:journal,scene:scene)
            await recovered.restoreNoteDraft(load:source.load)
            if mode == "conflict" || mode == "readback-changed" {
                check(recovered.vaultNote == nil && recovered.noteRecovery != nil && source.writes == (mode == "conflict" ? 0 : 1),
                      "CAS·재조회 충돌 후 원문·복구 입력 보존")
            } else {
                check(recovered.noteRecovery == nil && !recovered.vaultDirty && recovered.vaultDraft == record.submittedText && source.writes == 1,
                      "\(mode) 새 Store 재조회로 같은 평가 수용·중복 쓰기 0")
            }
        }

        let lateFile = try ReviewFile(root:root,text:cardText), late = makeStore(), readGate = ReviewGate()
        await late.openVaultNote(path,load:lateFile.load)
        let lateSession = late.beginVaultReview()!
        let lateTask = Task { await late.rateVaultReviewGood(lateSession,injectedDate:now,save:lateFile.save,load:readGate.load) }
        await readGate.wait()
        late.setNoteConnection(address:"http://new",token:"new")
        let oldDraft = late.vaultDraft
        readGate.finish(try lateFile.load(path))
        check(!(await lateTask.value) && late.vaultDraft == oldDraft && late.vaultBlocked,"연결 전환 뒤 늦은 readback은 편집기 성공으로 수용하지 않음")

        let templateJournal = root.appendingPathComponent("template.note")
        let plain = try ReviewFile(root:root,text:original), templateStore = makeStore(journal:templateJournal)
        await templateStore.openVaultNote(path,load:plain.load)
        check(templateStore.insertVaultReviewTemplate() && templateStore.vaultDirty && plain.writes == 0,"틀 삽입은 명시적 로컬 초안 변경만 수행")
        check(templateStore.beginVaultReview() == nil && !templateStore.insertVaultReviewTemplate(),"빈·미저장 틀 복습과 중복 틀 삽입 거부")
        let templateDraft = templateStore.vaultDraft, recovery = templateStore.noteRecovery!
        let restoredTemplate = makeStore(journal:templateJournal,scene:templateStore.scene)
        await restoredTemplate.restoreNoteDraft(load:plain.load)
        check(recovery.draft == templateDraft && restoredTemplate.vaultDraft == templateDraft &&
              restoredTemplate.vaultCanSave && plain.writes == 0,"틀 초안도 새 Store에서 기존 복구 계약으로 재열기")
        #endif
        print("RESULT \(assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
