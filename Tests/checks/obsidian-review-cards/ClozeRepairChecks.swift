import Foundation
import AppKit

@main struct ClozeRepairChecks {
    static var assertions = [String]()
    static func check(_ yes: Bool, _ name: String) { precondition(yes,name); assertions.append(name); print("PASS",name) }
    static func rejects(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard case .isolated(let context) = CanvasRuntime.launch else { fatalError("isolated only") }
        let out = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).resolvingSymlinksInPath()
        let vault = try OwnVault(); defer { vault.close() }
        let template = try VaultReviewCard.insertingTemplate(in:"원문 e\u{301} 😀\r\n",cardID:UUID(uuidString:"11111111-1111-4111-8111-111111111111")!)
        let blank = try VaultReviewCard.parse(template)!
        let base = try VaultReviewCard.parse(blank.replacing(.back,with:"기존 답"))!
        let now = Date(timeIntervalSince1970:1_800_000_000)
        let event = UUID(uuidString:"22222222-2222-4222-8222-222222222222")!
        let path = "cloze-repair.md"
        let bad = [
            ("R1-four-spaces","    {{c1::원문}}"), ("R1-tab","\t{{c1::원문}}"),
            ("R1-space-tab"," \t{{c1::원문}}"), ("R1-CRLF","머리\r\n\r\n    {{c1::원문}}"),
            ("R2-U2028","{{c1::첫 줄\u{2028}다음 줄}}"), ("R2-U2029","{{c1::첫 줄\u{2029}다음 줄}}"),
            ("R2-CRLF","{{c1::첫 줄\r\n다음 줄}}"), ("R2-LF","{{c1::첫 줄\n다음 줄}}"),
            ("R2-CR","{{c1::첫 줄\r다음 줄}}"), ("R2-NEL","{{c1::첫 줄\u{85}다음 줄}}"),
            ("R2-VT","{{c1::첫 줄\u{b}다음 줄}}"), ("R2-FF","{{c1::첫 줄\u{c}다음 줄}}")]
        let good = [
            ("normal-Korean","일반 {{c1::정상한글}} 질문"), ("three-spaces","   {{c1::원문}}"),
            ("payload-spaces","{{c1::일반 공백}}"), ("payload-tab","{{c1::탭\t원문}}"),
            ("plain-four-spaces","    평문 질문"), ("plain-tab","\t평문 질문"),
            ("CRLF-outside-payload","첫 줄\r\n정상 {{c1::원문}}")]
        var rows = [[String:Any]]()
        for (label,front) in bad + good {
            let path = "cloze-\(label).md"
            let unsupported = bad.contains { $0.0 == label }
            let markdown = try base.replacing(.front,with:front), card = try VaultReviewCard.parse(markdown)!
            let selection = (front as NSString).range(of:label.hasPrefix("R2-") ? "첫 줄" : "원문")
            let validSelection = selection.location == NSNotFound ? NSRange(location:0,length:0) : selection
            let reviewRejected = rejects { _ = try card.reviewQuestion(revealed:false) }
            let revealRejected = rejects { _ = try card.reviewQuestion(revealed:true) }
            let gradeRejected = rejects { _ = try card.rating(.hard,eventID:event,injectedDate:now) }
            check(reviewRejected == unsupported && revealRejected == unsupported && gradeRejected == unsupported,label + " 공통 parser의 표시·공개·평가 경계")
            check((card.noteSelection(validSelection,field:.front) == nil) == unsupported && (card.noteSelection(NSRange(location:0,length:0),field:.back) == nil) == unsupported,label + " noteSelection도 같은 parser 소비")
            check(card.text(for:.front).utf8.elementsEqual(front.utf8) && card.metadata == base.metadata && card.back == base.back,label + " 원문·metadata·답 무변경")
            _ = try await vault.save(path,nil,markdown)
            let s = CanvasStore(); s.setNoteConnection(address:context.relayAddress,token:context.token)
            await s.openVaultNote(path,load:vault.note)
            check(s.vaultDraft.utf8.elementsEqual(markdown.utf8) && s.vaultReviewEditSession != nil,label + " 실제 Store는 미지원 문서도 원문 그대로 열기")
            let session = s.beginVaultReview()
            check(s.vaultReviewCanBegin == !unsupported && (session == nil) == unsupported,label + " Store 복습 진입은 Model 판정과 동일")
            if unsupported {
                let before = s.vaultDraft
                check(!s.selectVaultReview(.front,selection:validSelection,session:s.vaultReviewEditSession!) && s.captureVaultReviewCloze(validSelection,session:s.vaultReviewEditSession!) == nil,label + " 미지원 선택·구조 명령 캡처 거부")
                check(s.vaultDraft.utf8.elementsEqual(before.utf8) && s.noteRecovery == nil && s.vaultReviewMessage == VaultReviewError.cloze.localizedDescription,label + " 원문 보존·명시 안내·저장 의도 없음")
                let bytes = try await vault.note(path)
                check(bytes.text.utf8.elementsEqual(markdown.utf8),label + " 거부 뒤 파일 원문 동일")
            } else {
                check(await s.rateVaultReview(session!,grade:.hard,injectedDate:now,save:{try await vault.save($0,$1,$2)},load:vault.note),label + " 실제 기존 평가 CAS/GET 회귀")
                let rated = try VaultReviewCard.parse(s.vaultDraft)!
                check(rated.metadata.cardID == card.metadata.cardID && rated.metadata.eventID == session!.id.uuidString.lowercased() && rated.metadata.dueAt == 1_800_000_600 && rated.front.utf8.elementsEqual(card.front.utf8) && rated.back == card.back,label + " 고정 간격·앞/뒤·ID 보존")
            }
            rows.append(["case":label,"front":front,"unsupported":unsupported,"reviewRejected":reviewRejected,"gradeRejected":gradeRejected,"markdownSHA256":CanvasPacket.sha(Data(markdown.utf8))])
        }
        _ = try await vault.save(path,nil,try base.replacing(.front,with:"지정 경계"))
        for front in ["    원문","\t원문"," \t원문","머리\r\n\r\n    원문","첫 줄\u{2028}다음 줄","첫 줄\u{2029}다음 줄"] {
            let card = try VaultReviewCard.parse(base.replacing(.front,with:front))!
            let selection = (front as NSString).range(of:front.contains("원문") ? "원문" : front)
            check(rejects { _ = try card.settingCloze(removing:false,selection:selection) },"새 지정 결과도 들여쓰기 코드·newline parser로 거부")
            let markdown = try base.replacing(.front,with:front)
            let latest = try await vault.note(path); _ = try await vault.save(path,latest.sha256,markdown)
            let s = CanvasStore(); s.setNoteConnection(address:context.relayAddress,token:context.token); await s.openVaultNote(path,load:vault.note)
            check(s.selectVaultReview(.front,selection:selection,session:s.vaultReviewEditSession!),"표식 없는 원래 텍스트 선택·plain 계약 유지")
            let captured = s.captureVaultReviewCloze(selection,session:s.vaultReviewEditSession!)!
            check(!s.setVaultReviewCloze(removing:false,captured:captured) && s.vaultDraft.utf8.elementsEqual(markdown.utf8) && s.noteRecovery == nil,"실제 Store 지정 거부는 trim·치환·의도 저장 없이 원문 유지")
        }
        check(NSApplication.shared.windows.isEmpty,"GUI Window 생성 0")
        try JSONSerialization.data(withJSONObject:["count":assertions.count,"assertions":assertions,"cases":rows,"operations":vault.operations,"whole95Repeated":false,"HTTP":false],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
    }
}
