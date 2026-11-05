import Foundation

#if !REVIEW_MODEL_ONLY
@MainActor final class DueVault {
    private struct NoteResponse: Decodable { let value: VaultNoteSnapshot }
    let process = Process(), input = Pipe(), output = Pipe()
    var writes = 0
    init() throws {
        let env = ProcessInfo.processInfo.environment
        process.executableURL = URL(fileURLWithPath:env["EPUB_PRODUCT_NODE"]!)
        process.arguments = [env["EPUB_PRODUCT_BACKEND"]!]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
        try process.run()
    }
    func close() { try? input.fileHandleForWriting.close(); process.waitUntilExit(); precondition(process.terminationStatus == 0) }
    func call(_ operation: String, _ arguments: [String:Any]) throws -> Data {
        var row = arguments; row["operation"] = operation
        var bytes = try JSONSerialization.data(withJSONObject:row); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf:bytes)
        var line = Data()
        while let part = try output.fileHandleForReading.read(upToCount:1), !part.isEmpty {
            if part[0] == 10 { break }; line.append(part)
        }
        let response = try JSONSerialization.jsonObject(with:line) as! [String:Any]
        guard response["ok"] as? Bool == true else {
            throw NSError(domain:"CanvasRelay",code:response["status"] as? Int ?? 500,
                userInfo:[VaultSaveConflict.errorKey:response["reconciliationRequired"] as? Bool == true ?
                    VaultSaveConflict.reconciliationRequired.rawValue : VaultSaveConflict.unclassified.rawValue])
        }
        return line
    }
    func note(_ path: String) async throws -> VaultNoteSnapshot {
        try JSONDecoder().decode(NoteResponse.self,from:call("readNote",["path":path])).value
    }
    func save(_ path: String, _ sha: String?, _ text: String) async throws -> VaultNoteSnapshot {
        let result = try JSONDecoder().decode(NoteResponse.self,from:call("saveNote",
            ["path":path,"baseSha256":sha as Any? ?? NSNull(),"text":text])).value
        writes += 1; return result
    }
    func external(_ path: String, _ text: String) throws {
        _ = try call("external",["path":path,"text":text])
    }
}
#endif

@main struct DueChecks {
    static var assertions = 0
    static func check(_ value: Bool, _ label: String) {
        precondition(value,label); assertions += 1; print("PASS",label)
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let now = Date(timeIntervalSince1970:1_800_000_000)
        let original = "\u{feff}앞 문단 e\u{301}\r\n" +
            "<!-- ccr-review-card:v1 {\"cardID\":\"11111111-1111-4111-8111-111111111111\",\"dueAt\":null,\"eventID\":null,\"ratedAt\":null} -->\r\n" +
            "<!-- ccr-review-front -->\r\n질문 👩🏽‍💻\r\n<!-- ccr-review-back -->\r\n답\r\n<!-- /ccr-review-card -->\r\n끝"
        let card = try VaultReviewCard.parse(original)!
        let futureText = try card.ratingGood(eventID:UUID(),injectedDate:now)
        let future = try VaultReviewCard.parse(futureText)!
        let pastText = try card.ratingGood(eventID:UUID(),injectedDate:now.addingTimeInterval(-172_800))
        check(VaultReviewCard.Filter.due.includes(card,at:now),"미평가 카드는 필터에서 유지")
        check(!VaultReviewCard.Filter.due.includes(future,at:now),"저장된 미래 Unix 기한만 제외")
        check(VaultReviewCard.Filter.all.includes(future,at:now),"필터 해제는 미래 카드도 포함")
        check(VaultReviewCard.Filter.due.includes(future,at:Date(timeIntervalSince1970:Double(future.metadata.dueAt!))),"CCR의 저장된 기한 시각부터 포함, 날짜·자정 변환 없음")
        check(VaultReviewCard.Filter.due.includes(future,at:Date(timeIntervalSince1970:.nan)),"시각 미확인은 카드 제외 근거가 아님")
        check(future.metadata.cardID == card.metadata.cardID && future.front == card.front && future.back == card.back,
              "평가와 필터가 같은 카드 ID·질문·답을 유지")
        #if !REVIEW_MODEL_ONLY
        guard case .isolated(let context) = CanvasRuntime.launch else { fatalError("isolated only") }
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let vault = try DueVault(); defer { vault.close() }
        func store() -> CanvasStore {
            let value = CanvasStore()
            value.setNoteConnection(address:context.relayAddress,token:context.token)
            return value
        }
        if CommandLine.arguments.contains("--reopen-due") {
            let reopened = store()
            await reopened.openVaultNote("Notes/saved.md",load:vault.note)
            check(reopened.vaultReviewItem?.isVisible(filter:.due,at:now) == false,"별도 프로세스 원본 재열기에서 미래 카드 제외")
            check(reopened.vaultReviewItem?.isVisible(filter:.all,at:now) == true,"별도 프로세스 필터 해제에서 같은 카드 복원")
            check(reopened.vaultReviewItem?.card.metadata.cardID == card.metadata.cardID,"별도 프로세스 cardID 유지")
            return
        }
        let failureCase = CommandLine.arguments.first { $0.hasPrefix("--failure=") }.map { String($0.dropFirst(10)) }
        if failureCase == nil {
        let path = "Notes/saved.md"
        _ = try await vault.save(path,nil,original)
        let value = store()
        await value.openVaultNote(path,load:vault.note)
        check(value.vaultReviewItem?.isVisible(filter:.due,at:now) == true,"미평가 원문을 실제 ObsidianVault에서 열기")
        let session = value.beginVaultReview(filter:.due,at:now)!
        let confirmed = await value.rateVaultReviewGood(session,injectedDate:now,save:{ try await vault.save($0,$1,$2) },load:vault.note)
        check(confirmed && value.noteRecovery == nil,"실제 Obsidian CAS 저장·GET·저널 정리 확인")
        let saved = try await vault.note(path), savedItem = value.vaultReviewItem!
        check(!savedItem.confirmationPending && !savedItem.isVisible(filter:.due,at:now),"확인된 평가만 미래 카드 제외")
        check(value.beginVaultReview(filter:.due,at:now) == nil && value.beginVaultReview(filter:.all,at:now) != nil,"Store 진입점도 같은 필터 계약 사용")
        check(savedItem.isVisible(filter:.all,at:now) && savedItem.card.metadata.cardID == card.metadata.cardID && savedItem.card.front == card.front && savedItem.card.back == card.back,
              "필터 해제는 같은 저장 원본·ID·내용을 표시")
        let beforeFilter = vault.writes
        _ = savedItem.isVisible(filter:.all,at:now)
        check(vault.writes == beforeFilter && savedItem.sourceSHA == saved.sha256 && value.vaultDraft.utf8.elementsEqual(saved.text.utf8),"필터 변경 쓰기 0·SHA·기한·원문 바이트 불변")
        let reopened = store()
        await reopened.openVaultNote(path,load:vault.note)
        check(reopened.vaultReviewItem?.card.metadata == savedItem.card.metadata && reopened.vaultReviewItem?.isVisible(filter:.due,at:now) == false,"새 Store 재열기 기한·ID·필터 유지")
        let child = Process(); child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
        child.arguments = [out.path,"--reopen-due","--ccr-test-runtime",context.id.uuidString.lowercased()]
        try child.run(); child.waitUntilExit(); check(child.terminationStatus == 0,"별도 프로세스 재열기 통과")
        let pastDue = try VaultReviewCard.parse(pastText)!.metadata.dueAt
        try vault.external(path,pastText)
        await reopened.refreshVaultNotes(load:vault.note)
        check(reopened.vaultReviewItem?.isVisible(filter:.due,at:now) == true && reopened.vaultReviewItem?.card.metadata.dueAt == pastDue,"외부 유효 기한 수정·역수신 후 다시 포함")
        try vault.external(path,futureText)
        await reopened.refreshVaultNotes(load:vault.note)
        check(reopened.vaultReviewItem?.isVisible(filter:.due,at:now) == false && reopened.vaultReviewItem?.sourceSHA == CanvasPacket.sha(Data(futureText.utf8)),"외부 미래 기한 수정도 확인 원문 SHA로 제외")
        check((try await vault.note(path)).text.utf8.elementsEqual(futureText.utf8),"검사 후에도 확인용 노트 원문 유지")
        } else if let failure = failureCase {
            let relative = "Notes/" + failure + ".md"
            _ = try await vault.save(relative,nil,original)
            var failCleanup = false
            let s = CanvasStore(noteRecoveryWrite:{ bytes,url in
                if failCleanup, try JSONDecoder().decode(VaultNoteRecoveryFile.self,from:bytes).record() == nil { throw CocoaError(.fileWriteNoPermission) }
                try CanvasLocalFile.write(bytes,to:url)
            })
            s.setNoteConnection(address:context.relayAddress,token:context.token)
            await s.openVaultNote(relative,load:vault.note)
            let captured = s.beginVaultReview(filter:.due,at:now)!
            let prior = vault.writes
            let accepted = await s.rateVaultReviewGood(captured,injectedDate:now,save:{ path,sha,text in
                check(s.vaultReviewItem?.isVisible(filter:.due,at:now) == true && s.vaultReviewItem?.confirmationPending == true,"\(failure) 전송 중에도 미확인 평가로 제외하지 않음")
                if failure == "409" { try vault.external(path,futureText) }
                let saved = try await vault.save(path,sha,text)
                if failure == "lost-response" { throw URLError(.networkConnectionLost) }
                if failure == "cleanup" { failCleanup = true }
                return saved
            },load:{ path in
                if failure == "lost-readback" { throw URLError(.timedOut) }
                return try await vault.note(path)
            })
            check(!accepted && s.vaultReviewItem?.confirmationPending == true && s.vaultReviewItem?.isVisible(filter:.due,at:now) == true,"\(failure) 미확인 평가를 완료로 처리하지 않고 카드 유지")
            let recoveryDue = failure == "cleanup" ? future.metadata.dueAt : nil
            check(s.vaultReviewItem?.card.metadata.dueAt == recoveryDue && s.noteRecovery != nil,
                  "\(failure) 실제 복구 기준 일정과 저널 유지, 정리 실패 때 미래 기한도 숨기지 않음")
            check(vault.writes == prior + (failure == "409" ? 0 : 1),"\(failure) 조건부 쓰기 횟수·중복 평가 0")
            let restored = CanvasStore()
            restored.setNoteConnection(address:context.relayAddress,token:context.token)
            check(restored.vaultReviewItem?.isVisible(filter:.due,at:now) == true && restored.vaultReviewItem?.confirmationPending == true,"\(failure) 새 Store에서도 보존된 원래 카드 유지")
            if failure == "lost-response" || failure == "lost-readback" {
                await restored.restoreNoteDraft(load:vault.note)
                check(restored.noteRecovery == nil && restored.vaultReviewItem?.isVisible(filter:.due,at:now) == false,"\(failure) 명시 재조회로 저장 확인한 뒤에만 제외")
                check(vault.writes == prior + 1,"\(failure) 재조회에서 평가 재전송 0")
            } else if failure == "409" {
                await restored.restoreNoteDraft(load:vault.note)
                check(restored.noteRecovery != nil && restored.vaultReviewItem?.isVisible(filter:.due,at:now) == true,"409는 재조회로 임의 채택하지 않고 기존 명시 조정 유지")
            }
        }
        #endif
        print("RESULT \(assertions) assertions, 0 failures")
    }
}
