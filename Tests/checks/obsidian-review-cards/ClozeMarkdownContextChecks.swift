import Foundation

@main struct ClozeMarkdownContextChecks {
    static func main() throws {
        setbuf(stdout,nil)
        let out = URL(fileURLWithPath:CommandLine.arguments[1])
        let template = try VaultReviewCard.insertingTemplate(in:"\u{feff}원문 e\u{301} 😀\r\n",cardID:UUID(uuidString:"11111111-1111-4111-8111-111111111111")!)
        let blank = try VaultReviewCard.parse(template)!
        let base = try VaultReviewCard.parse(blank.replacing(.back,with:"기존 답\r\n[[원문#^anchor]]"))!
        let event = UUID(uuidString:"22222222-2222-4222-8222-222222222222")!
        var assertions = [String](), failures = [String](), rows = [[String:Any]]()
        func check(_ yes: Bool, _ label: String) {
            assertions.append(label); if !yes { failures.append(label) }; print(yes ? "PASS" : "FAIL",label)
        }
        func accepted(_ action: () throws -> Void) -> Bool { do { try action(); return true } catch { return false } }
        let bad = [
            ("blockquote-code",">     {{c1::원문}}"), ("nested-blockquote-code","> >     {{c1::원문}}"),
            ("list-code","-     {{c1::원문}}"), ("ordered-list-code","1.     {{c1::원문}}"),
            ("quoted-list-code","> -     {{c1::원문}}"), ("top-code","    {{c1::원문}}"),
            ("tab-code","\t{{c1::원문}}"), ("inline-code","`{{c1::원문}}`"),
            ("inline-code-inside-payload","{{c1::한글 `코드` 원문}}"),
            ("fenced-code","```swift\r\n{{c1::원문}}\r\n```"),
            ("container-code-later-offset",">     한글 e\u{301} 😀\r\n>     앞 {{c1::원문}} 뒤")]
        let good = [
            ("plain-c1","일반 {{c1::원문}} 질문"), ("plain-quote","> 일반 {{c1::원문}}"),
            ("plain-list","- 일반 {{c1::원문}}"), ("ordered-list","1. 일반 {{c1::원문}}"),
            ("nested-list","- 상위\r\n  - 일반 {{c1::원문}}"), ("quoted-list","> - 일반 {{c1::원문}}"),
            ("bold","**강조 {{c1::원문}}**"), ("three-spaces","   {{c1::원문}}"),
            ("unrelated-inline-code","일반 `다른 코드`와 {{c1::원문}}"),
            ("unrelated-fenced-code","```\r\n다른 코드 😀\r\n```\r\n\r\n- 일반 {{c1::원문}}"),
            ("unrelated-indented-code","    다른 코드\r\n\r\n일반 {{c1::원문}}"),
            ("plain-card","    빈칸 없는 평문 질문"), ("plain-tab-card","\t빈칸 없는 평문 질문")]
        for (name,front) in bad + good {
            let unsupported = bad.contains { $0.0 == name }
            let markdown = try base.replacing(.front,with:front), card = try VaultReviewCard.parse(markdown)!
            let display = accepted { _ = try card.reviewQuestion(revealed:false); _ = try card.reviewQuestion(revealed:true) }
            let rating = accepted { _ = try card.rating(.hard,eventID:event,injectedDate:Date(timeIntervalSince1970:1_800_000_000)) }
            check(display == !unsupported && rating == !unsupported,name + " 표시·평가 공통 판정")
            let range = (front as NSString).range(of:"원문")
            let selection = range.location == NSNotFound ? NSRange(location:0,length:0) : range
            check((card.noteSelection(selection,field:.front) != nil) == !unsupported,name + " 선택도 같은 parser")
            if range.location != NSNotFound && !front.contains("한글 `코드`") {
                let plain = front.replacingOccurrences(of:"{{c1::원문}}",with:"원문")
                let unmarked = try VaultReviewCard.parse(base.replacing(.front,with:plain))!
                let wrap = accepted { _ = try unmarked.settingCloze(removing:false,selection:(plain as NSString).range(of:"원문")) }
                check(wrap == !unsupported,name + " 실제 선택 지정 결과 판정")
            }
            if !unsupported && rating {
                let rated = try VaultReviewCard.parse(card.rating(.hard,eventID:event,injectedDate:Date(timeIntervalSince1970:1_800_000_000)))!
                check(rated.front.utf8.elementsEqual(card.front.utf8) && rated.back.utf8.elementsEqual(card.back.utf8) && rated.metadata.cardID == card.metadata.cardID && rated.metadata.eventID == event.uuidString.lowercased() && rated.metadata.dueAt == 1_800_000_600,name + " 평가·원문 bytes 유지")
            }
            check(card.text(for:.front).utf8.elementsEqual(front.utf8) && card.metadata == base.metadata && card.back == base.back,name + " 정규화·재직렬화 없음")
            rows.append(["case":name,"supported":!unsupported,"reviewAccepted":display,"ratingAccepted":rating,"sourceSHA256":CanvasPacket.sha(Data(markdown.utf8))])
        }
        for scalar in ["\r","\n","\r\n","\u{2028}","\u{2029}","\u{85}","\u{b}","\u{c}"] {
            let front = "{{c1::첫 줄" + scalar + "다음 줄}}", card = try VaultReviewCard.parse(base.replacing(.front,with:front))!
            check(!accepted { _ = try card.reviewQuestion(revealed:false) } && !accepted { _ = try card.rating(.hard,eventID:event,injectedDate:Date(timeIntervalSince1970:1_800_000_000)) } && card.noteSelection(NSRange(location:0,length:0),field:.front) == nil,"R2 newline \(scalar.unicodeScalars.map { $0.value }) 거부 유지")
            check(card.text(for:.front).utf8.elementsEqual(front.utf8),"R2 원문 보존")
        }
        try JSONSerialization.data(withJSONObject:["count":assertions.count,"assertions":assertions,"failures":failures,"cases":rows,"StoreExecuted":false,"whole95Repeated":false,"HTTP":false,"GUI":false],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
        print("RESULT",assertions.count,"checks",failures.count,"failures")
        if !failures.isEmpty { exit(1) }
    }
}
