import Foundation
import AppKit

@main struct ClozeChecks {
    static var assertions = [String]()
    static func check(_ yes: Bool, _ name: String) { precondition(yes,name); assertions.append(name); print("PASS",name) }
    static func refuses(_ name: String, _ action: () throws -> Void) {
        do { try action(); fatalError("accepted: " + name) } catch { check(true,name) }
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated(let context) = CanvasRuntime.launch else { fatalError("isolated only") }
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).resolvingSymlinksInPath()
        let vault = try OwnVault(); defer { vault.close() }
        let path = "복습/빈칸.md", now = Date(timeIntervalSince1970:1_800_000_000)
        func store() -> CanvasStore {
            let s = CanvasStore(); s.setNoteConnection(address:context.relayAddress,token:context.token); return s
        }
        if CommandLine.arguments.contains("--reopen") {
            let s = store(); await s.openVaultNote(path,load:vault.note)
            let expected = String(decoding:try Data(contentsOf:out.appendingPathComponent("expected.md")),as:UTF8.self)
            print("REOPEN",s.vaultStatus,s.noteRecoveryNotice,s.vaultDraft.utf8.count,expected.utf8.count)
            check(s.vaultDraft.utf8.elementsEqual(expected.utf8),"새 프로세스에서 같은 Obsidian 원문·복습 카드 재열기")
            check(s.vaultReviewCanBegin,"새 프로세스에서 기존 평가·복습 진입 가능")
            return
        }
        func reopen(_ text: String) throws {
            try Data(text.utf8).write(to:out.appendingPathComponent("expected.md"))
            let p = Process(); p.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
            p.arguments = [out.path,"--ccr-test-runtime",context.id.uuidString.lowercased(),"--reopen"]
            try p.run(); p.waitUntilExit(); check(p.terminationStatus == 0,"별도 프로세스 재열기 확인")
        }
        let original = "\u{feff}---\r\n제목: 빈칸 복습\r\n---\r\n원문 [[문서/원본#^anchor]] e\u{301} 👩🏽‍💻\r\n"
        let template = try VaultReviewCard.insertingTemplate(in:original,cardID:UUID(uuidString:"11111111-1111-4111-8111-111111111111")!)
        let empty = try VaultReviewCard.parse(template)!
        let front = "가방 e\u{301} 👩🏽‍💻 Core 와 Core"
        let question = try empty.replacing(.front,with:front)
        let text = try VaultReviewCard.parse(question)!.replacing(.back,with:"답: Core\r\n원문과 별도 메모 e\u{301} 😀")
        let baseline = try VaultReviewCard.parse(text)!
        let range = (front as NSString).range(of:"Core")
        let markedText = try baseline.settingCloze(removing:false,selection:range), marked = try VaultReviewCard.parse(markedText)!
        check(marked.text(for:.front) == "가방 e\u{301} 👩🏽‍💻 {{c1::Core}} 와 Core","실제 선택한 반복 글자만 표식 지정")
        check(marked.metadata == baseline.metadata && marked.back.utf8.elementsEqual(baseline.back.utf8) && markedText.hasPrefix(original),"cardID·eventID·back·BOM/CRLF/NFD 본문·원문 참조 보존")
        check(try marked.reviewQuestion(revealed:false) == "가방 e\u{301} 👩🏽‍💻 [빈칸] 와 Core" && marked.reviewQuestion(revealed:true).utf8.elementsEqual(front.utf8),"가림과 답 공개는 원문을 변형하지 않는 표시 투영")
        let payload = (marked.text(for:.front) as NSString).range(of:"Core")
        check(try marked.settingCloze(removing:true,selection:payload).utf8.elementsEqual(text.utf8),"안의 원문 전체 선택으로 명시 해제·원문 바이트 왕복")
        let token = (marked.text(for:.front) as NSString).range(of:"{{c1::Core}}")
        check(try marked.settingCloze(removing:true,selection:token).utf8.elementsEqual(text.utf8),"표식 전체 선택으로 명시 해제")
        for value in ["가방","e\u{301}","👩🏽‍💻"] {
            let selection = (front as NSString).range(of:value)
            let state = try VaultReviewCard.parse(baseline.settingCloze(removing:false,selection:selection))!
            check(try state.reviewQuestion(revealed:true).utf8.elementsEqual(front.utf8),"한글·결합 문자·emoji 선택의 UTF16 원문 보존")
        }
        for selection in [NSRange(location:NSNotFound,length:1),NSRange(location:-1,length:1),NSRange(location:0,length:0),NSRange(location:Int.max,length:Int.max),NSRange(location:(front as NSString).range(of:"👩🏽‍💻").location + 1,length:1),NSRange(location:(front as NSString).range(of:"e\u{301}").location,length:1)] {
            refuses("잘못된 범위·부분 grapheme 거부") { _ = try baseline.settingCloze(removing:false,selection:selection) }
        }
        for unsupported in ["{{c2::Core}}","{{c01::Core}}","{{c1::Core::힌트}}","{{c1::{{c1::Core}}}}","{{c1::}}","{{c1::Core}","Core}}","\\{{c1::Core}}","`{{c1::Core}}`","<!-- {{c1::Core}} -->","{{c1::Core\n다음}}"] {
            let raw = try baseline.replacing(.front,with:unsupported), c = try VaultReviewCard.parse(raw)!
            refuses("미지원·중첩·힌트·손상 표현 표시 거부") { _ = try c.reviewQuestion(revealed:false) }
            refuses("미지원 표식 평가 거부") { _ = try c.rating(.good,eventID:UUID(),injectedDate:now) }
            check(c.text(for:.front).utf8.elementsEqual(unsupported.utf8),"미지원 입력 원문 그대로 보존")
        }
        refuses("기존 표식 위 중첩 지정 거부") { _ = try marked.settingCloze(removing:false,selection:payload) }
        refuses("일부 글자만 선택한 모호한 해제 거부") { _ = try marked.settingCloze(removing:true,selection:NSRange(location:payload.location,length:1)) }
        let two = try VaultReviewCard.parse(baseline.replacing(.front,with:"{{c1::가방}} {{c1::👩🏽‍💻}}"))!
        check(try two.reviewQuestion(revealed:false) == "[빈칸] [빈칸]" && two.reviewQuestion(revealed:true) == "가방 👩🏽‍💻","같은 c1의 여러 빈칸만 함께 가림·공개")
        check(try baseline.reviewQuestion(revealed:false).utf8.elementsEqual(front.utf8) && !baseline.hasCloze,"평문 카드 표시 계약 유지")

        let vaultRoot = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PDF_VIEW_VAULT"]!,isDirectory:true)
        try FileManager.default.createDirectory(at:vaultRoot.appendingPathComponent("복습",isDirectory:true),withIntermediateDirectories:true)
        _ = try await vault.save(path,nil,text)
        let s = store(); await s.openVaultNote(path,load:vault.note)
        print("OPEN",s.vaultStatus,s.vaultDraft.utf8.count,s.vaultNote != nil,s.vaultInputSessionID != nil)
        let fieldUI = ClozeUIBindings(store:s,session:s.vaultReviewEditSession!,showRawMarkdown:{ fatalError("unexpected raw fallback") })
        check(fieldUI.text(.front).wrappedValue.utf8.elementsEqual(front.utf8),"실제 질문 필드 get binding 원문")
        fieldUI.text(.front).wrappedValue = front + "!"
        fieldUI.text(.front).wrappedValue = front
        check(s.vaultDraft.utf8.elementsEqual(text.utf8),"실제 질문 필드 set binding이 같은 Markdown을 편집·원복")
        fieldUI.questionSelection.wrappedValue = range
        check(fieldUI.frontSelection == range && s.vaultSelection == baseline.noteSelection(range,field:.front),"실제 UI selection binding이 Store의 같은 UTF16 범위에 연결")
        let fieldCapture = s.captureVaultReviewCloze(range,session:s.vaultReviewEditSession!)!
        let answerUI = ClozeUIBindings(store:s,session:s.vaultReviewEditSession!,showRawMarkdown:{})
        answerUI.answerSelection.wrappedValue = NSRange(location:0,length:0)
        check(!s.setVaultReviewCloze(removing:false,captured:fieldCapture),"실제 답 selection binding이 이전 질문 캡처 은퇴")
        func select(_ selection: NSRange, in s: CanvasStore) -> CanvasStore.VaultReviewClozeSelection {
            check(s.selectVaultReview(.front,selection:selection,session:s.vaultReviewEditSession!),"실제 질문 필드 선택을 기존 전체 원문 NSRange에 연결")
            return s.captureVaultReviewCloze(selection,session:s.vaultReviewEditSession!)!
        }
        let first = select(range,in:s)
        check(s.setVaultReviewCloze(removing:false,captured:first),"Store 선택 필드 빈칸 편집")
        check(s.noteRecovery?.draft.utf8.elementsEqual(s.vaultDraft.utf8) == true && s.vaultDraft.utf8.elementsEqual(markedText.utf8),"같은 Markdown 초안·기존 note recovery에 표식 원문 보존")
        let initialDraft = s.vaultDraft
        check(!s.setVaultReviewCloze(removing:true,captured:first) && s.vaultDraft == initialDraft,"편집 전 캡처 재사용은 거부")
        await s.saveVaultNote(save:{try await vault.save($0,$1,$2)},load:vault.note)
        check(!s.vaultDirty && s.noteRecovery == nil && s.vaultNote?.text.utf8.elementsEqual(markedText.utf8) == true,"실제 Obsidian 파일 CAS 저장·전체 GET은 가림 문자열이 아닌 표식 원문")
        try reopen(markedText)
        let fresh = store(); await fresh.openVaultNote(path,load:vault.note)
        let current = fresh.beginVaultReview()!
        check(try current.card.reviewQuestion(revealed:false).contains("[빈칸]") && current.card.reviewQuestion(revealed:true).contains("Core"),"새 Store 앞면 가림과 답 뒤집기 원문")
        check(await fresh.rateVaultReview(current,grade:.hard,injectedDate:now,save:{try await vault.save($0,$1,$2)},load:vault.note),"기존 평가 원장과 10분 고정 간격 저장·GET")
        let rated = try VaultReviewCard.parse(fresh.vaultDraft)!
        check(rated.metadata.cardID == baseline.metadata.cardID && rated.metadata.eventID == current.id.uuidString.lowercased() && rated.metadata.dueAt == 1_800_000_600 && rated.front == marked.front && rated.back == baseline.back,"기존 cardID·eventID·일정 및 front/back 의미 유지")
        let writesAfterRate = vault.operations.filter { $0 == "saveNote" }.count
        check(!(await fresh.rateVaultReview(current,grade:.easy,injectedDate:now,save:{try await vault.save($0,$1,$2)},load:vault.note)) && vault.operations.filter { $0 == "saveNote" }.count == writesAfterRate,"같은 평가 세션 재사용 쓰기 0")
        var external = try rated.replacing(.front,with:"AI가 고친 {{c1::원문 😀}} 질문")
        external = try VaultReviewCard.parse(external)!.replacing(.back,with:"외부 답 e\u{301}")
        _ = try vault.call("external",["path":path,"text":external])
        await fresh.openVaultNote(path,load:vault.note)
        check(fresh.vaultDraft.utf8.elementsEqual(external.utf8) && fresh.beginVaultReview() != nil,"외부 Markdown 수정이 같은 복습 카드로 역수신")
        let ai = try VaultReviewCard.parse(external)!
        let aiQuestion = try ai.reviewQuestion(revealed:false)
        check(ai.metadata == rated.metadata && aiQuestion == "AI가 고친 [빈칸] 질문","AI 수정은 기존 평가 식별자를 유지")
        let chosen = (ai.text(for:.front) as NSString).range(of:"원문 😀")
        let remove = select(chosen,in:fresh)
        check(fresh.setVaultReviewCloze(removing:true,captured:remove),"역수신 표식 명시 해제")
        await fresh.saveVaultNote(save:{try await vault.save($0,$1,$2)},load:vault.note)
        check(try VaultReviewCard.parse(fresh.vaultDraft)!.metadata == rated.metadata && !fresh.vaultDraft.contains("{{c1::"),"해제 저장은 평가 원장을 고치지 않음")
        try reopen(fresh.vaultDraft)

        let plainSaved = fresh.vaultDraft
        let unsupported = try VaultReviewCard.parse(plainSaved)!.replacing(.front,with:"외부 {{c2::모호한 표식}}")
        _ = try vault.call("external",["path":path,"text":unsupported])
        await fresh.openVaultNote(path,load:vault.note)
        check(fresh.vaultDraft.utf8.elementsEqual(unsupported.utf8) && !fresh.vaultReviewCanBegin && fresh.beginVaultReview() == nil && fresh.vaultReviewMessage == VaultReviewError.cloze.localizedDescription,"미지원 외부 Markdown은 원본 보존·명시 안내·평가 거부")
        _ = try vault.call("external",["path":path,"text":plainSaved])
        await fresh.openVaultNote(path,load:vault.note)
        let connectionSelection = select((try VaultReviewCard.parse(plainSaved)!.text(for:.front) as NSString).range(of:"질문"),in:fresh)
        fresh.setNoteConnection(address:"http://192.168.88.88:4243",token:context.token)
        fresh.setNoteConnection(address:context.relayAddress,token:context.token)
        check(!fresh.setVaultReviewCloze(removing:false,captured:connectionSelection) && fresh.vaultDraft.utf8.elementsEqual(plainSaved.utf8),"연결 ABA는 옛 편집 session의 빈칸 동작 거부")
        await fresh.openVaultNote(path,load:vault.note)

        let frontNow = try VaultReviewCard.parse(fresh.vaultDraft)!.text(for:.front), a = (frontNow as NSString).range(of:"원문 😀"), b = (frontNow as NSString).range(of:"질문")
        let aba = select(a,in:fresh); _ = select(b,in:fresh); _ = select(a,in:fresh)
        let beforeABA = fresh.vaultDraft
        check(!fresh.setVaultReviewCloze(removing:false,captured:aba) && fresh.vaultDraft.utf8.elementsEqual(beforeABA.utf8),"선택 A→B→A는 이전 캡처 무효화")
        let invalidated = fresh.captureVaultReviewCloze(a,session:fresh.vaultReviewEditSession!)!
        check(!fresh.selectVaultReview(.front,selection:NSRange(location:NSNotFound,length:1),session:fresh.vaultReviewEditSession!) && !fresh.setVaultReviewCloze(removing:false,captured:invalidated),"잘못된 선택 callback도 이전 의도 무효화")
        let backFocus = select(a,in:fresh)
        check(fresh.selectVaultReview(.back,selection:NSRange(location:0,length:0),session:fresh.vaultReviewEditSession!) && !fresh.setVaultReviewCloze(removing:false,captured:backFocus),"답 선택 이후 질문의 이전 빈칸 의도 거부")
        let inputABA = select(a,in:fresh)
        let editSession = fresh.vaultReviewEditSession!
        check(fresh.editVaultReview(.front,text:frontNow+"!",session:editSession) && fresh.editVaultReview(.front,text:frontNow,session:editSession),"기존 필드 편집으로 텍스트 ABA 준비")
        check(!fresh.setVaultReviewCloze(removing:false,captured:inputABA),"질문 텍스트 A→B→A도 이전 캡처 거부")
        let safe = select(a,in:fresh)
        fresh.vaultInputBusy = true
        check(!fresh.setVaultReviewCloze(removing:false,captured:safe),"조합·Scribble busy 중 구조 편집 0")
        fresh.vaultInputBusy = false
        let safeNow = fresh.captureVaultReviewCloze(a,session:fresh.vaultReviewEditSession!)!
        check(fresh.setVaultReviewCloze(removing:false,captured:safeNow),"새 명시 선택 의도만 구조 편집")
        let submitted = fresh.vaultDraft
        var puts = 0
        await fresh.saveVaultNote(save:{p,b,t in puts += 1; _ = try await vault.save(p,b,t); throw URLError(.networkConnectionLost)},load:vault.note)
        check(puts == 1 && fresh.noteRecovery?.draft == submitted && fresh.noteRecovery?.submittedText == submitted,"ACK 미확인에 실제 제출·초안·같은 표식 보존")
        let lost = store(); await lost.restoreNoteDraft(load:vault.note)
        check(lost.vaultDraft == submitted && lost.noteRecovery == nil && puts == 1,"freshStore의 명시 GET 확인은 재평가·재PUT 없음")
        let supported = try VaultReviewCard.parse(lost.vaultDraft)!
        let add = select((supported.text(for:.front) as NSString).range(of:"질문"),in:lost)
        check(lost.setVaultReviewCloze(removing:false,captured:add),"충돌 전에 새 선택 초안")
        let pending = lost.vaultDraft
        let remote = submitted + "외부 원문 변경\r\n"
        _ = try vault.call("external",["path":path,"text":remote])
        await lost.saveVaultNote(save:{try await vault.save($0,$1,$2)},load:vault.note)
        check(lost.vaultDraft == pending && lost.noteRecovery?.submittedText == pending && !lost.vaultCanAttach,"실제 CAS409에서 외부 원문·로컬 표식·평가 보존 및 복습 차단")
        let remoteRead = try await vault.note(path)
        check(remoteRead.text == remote,"충돌 실패가 외부 원문을 덮지 않음")
        let failed = store(); await failed.restoreNoteDraft(load:vault.note)
        check(failed.noteRecovery?.draft == pending && failed.beginVaultReview() == nil,"freshStore 충돌 복구는 명시 대조 전 평가하지 않음")
        check(NSApplication.shared.windows.isEmpty,"GUI Window 생성 0")
        try JSONSerialization.data(withJSONObject:["count":assertions.count,"assertions":assertions,"operations":vault.operations,"originalMarkdownSHA":CanvasPacket.sha(Data(text.utf8)),"backSHA":CanvasPacket.sha(Data(baseline.back.utf8)),"sourceBodySHA":CanvasPacket.sha(Data(original.utf8)),"cardID":baseline.metadata.cardID],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
    }
}
