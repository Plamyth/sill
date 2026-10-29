import Foundation

@main struct ClozeTokenBoundaryChecks {
    static func main() throws {
        setbuf(stdout,nil)
        let out = URL(fileURLWithPath:CommandLine.arguments[1])
        let template = try VaultReviewCard.insertingTemplate(in:"\u{feff}원문 e\u{301} 😀\r\n",cardID:UUID(uuidString:"11111111-1111-4111-8111-111111111111")!)
        let blank = try VaultReviewCard.parse(template)!
        let base = try VaultReviewCard.parse(blank.replacing(.back,with:"기존 답\r\n[[원문#^anchor]]"))!
        let event = UUID(uuidString:"22222222-2222-4222-8222-222222222222")!
        var assertions = [String](), failures = [String](), rows = [[String:Any]]()
        func check(_ yes: Bool, _ name: String) { assertions.append(name); if !yes { failures.append(name) }; print(yes ? "PASS" : "FAIL",name) }
        func accepted(_ action: () throws -> Void) -> Bool { do { try action(); return true } catch { return false } }
        let bad = [
            ("decimal-original","{{c1::앞 &#125;&#125; `코드` 뒤}}"),
            ("hex-original","{{c1::앞 &#x7d;&#x7d; `코드` 뒤}}"),
            ("decimal-code-after-two-entities","{{c1::앞 &#125;&#125; &#125;&#125; `코드` 뒤}}"),
            ("entity-open-before-code","{{c1::앞 &#123;&#123; `코드` 뒤}}"),
            ("entity-opening-with-raw-hint","{{c1::앞 &#123;&#123;c1:: 원문 뒤}}"),
            ("second-token-code","{{c1::정상 &amp;}} {{c1::앞 &#125;&#125; `코드` 뒤}}"),
            ("quoted-code",">     {{c1::앞 &#125;&#125; 원문}}"),
            ("list-code","-     {{c1::앞 &#x7d;&#x7d; 원문}}"),
            ("inline-code-control","{{c1::앞 `코드` 뒤}}"),
            ("marker-in-destination","[링크](https://example.test/{{c1::원문}})")]
        let good = [
            ("plain-c1","일반 {{c1::원문}} 질문"),
            ("decimal-entity-body","{{c1::앞 &#125;&#125; 원문 뒤}}"),
            ("hex-entity-body","{{c1::앞 &#x7d;&#x7d; 원문 뒤}}"),
            ("entity-opening-body","{{c1::앞 &#123;&#123; 원문 뒤}}"),
            ("ampersand-body","{{c1::A & B &amp; C}}"),
            ("entity-body","{{c1::&#x1F600; &lt;원문&gt; &quot;답&quot;}}"),
            ("normal-entities-outside","&#125;&#125; &amp; 일반 {{c1::원문}}"),
            ("plain-review","A & B &amp; &#125;&#125; 평문 질문"),
            ("unrelated-inline","{{c1::앞 &#125;&#125; 원문}} 밖 `코드`"),
            ("normal-list","- {{c1::앞 &#x7d;&#x7d; 원문}}"),
            ("normal-quote","> 일반 {{c1::A &amp; B}}"),
            ("two-tokens","{{c1::앞 &#125;&#125; 원문}} 그리고 {{c1::뒤 &amp; 원문}}"),
            ("nested-list","- 상위\r\n  - 일반 {{c1::원문 &amp;}}"),
            ("unrelated-code-block","```\r\n다른 코드\r\n```\r\n\r\n{{c1::원문 &amp;}}"),
            ("old-looking-sentinel","CCRCLOZE00000000000000000000000000000000OPEN0Z {{c1::원문}}")]
        for (name,front) in bad + good {
            let unsupported = bad.contains { $0.0 == name }
            let markdown = try base.replacing(.front,with:front), card = try VaultReviewCard.parse(markdown)!
            let review = accepted { _ = try card.reviewQuestion(revealed:false); _ = try card.reviewQuestion(revealed:true) }
            let rating = accepted { _ = try card.rating(.hard,eventID:event,injectedDate:Date(timeIntervalSince1970:1_800_000_000)) }
            check(review == !unsupported && rating == !unsupported,name + " raw token 전체 코드 판정")
            check((card.noteSelection(NSRange(location:0,length:0),field:.front) != nil) == !unsupported,name + " noteSelection 공통 parser")
            let payload = front.replacingOccurrences(of:"{{c1::",with:"").replacingOccurrences(of:"}}",with:"")
            if ["decimal-original","hex-original","inline-code-control","decimal-entity-body","hex-entity-body","ampersand-body","entity-body"].contains(name) {
                let raw = try base.replacing(.front,with:payload), unmarked = try VaultReviewCard.parse(raw)!
                let selection = NSRange(location:0,length:payload.utf16.count)
                let wrap = accepted { _ = try unmarked.settingCloze(removing:false,selection:selection) }
                check(wrap == !unsupported,name + " 실제 선택 지정 결과 검증")
                if !unsupported {
                    let marked = try VaultReviewCard.parse(unmarked.settingCloze(removing:false,selection:selection))!
                    check(try marked.settingCloze(removing:true,selection:NSRange(location:6,length:payload.utf16.count)).utf8.elementsEqual(raw.utf8),name + " entity 원문 명시 해제 왕복")
                }
            }
            if !unsupported && rating {
                let rated = try VaultReviewCard.parse(card.rating(.hard,eventID:event,injectedDate:Date(timeIntervalSince1970:1_800_000_000)))!
                check(rated.front.utf8.elementsEqual(card.front.utf8) && rated.back.utf8.elementsEqual(base.back.utf8) && rated.metadata.cardID == base.metadata.cardID && rated.metadata.eventID == event.uuidString.lowercased() && rated.metadata.dueAt == 1_800_000_600,name + " 기존 평가·원문 bytes 보존")
                if front.hasPrefix("{{c1::"), !front.dropFirst(6).contains("{{c1::"), front.hasSuffix("}}") {
                    check(try card.reviewQuestion(revealed:true).utf8.elementsEqual(front.dropFirst(6).dropLast(2).utf8),name + " 공개 원문은 entity 재직렬화 없음")
                }
            }
            check(card.text(for:.front).utf8.elementsEqual(front.utf8) && card.metadata == base.metadata && card.back == base.back,name + " 정본 불변")
            rows.append(["case":name,"supported":!unsupported,"reviewAccepted":review,"ratingAccepted":rating,"question":front,"sourceSHA256":CanvasPacket.sha(Data(markdown.utf8))])
        }
        for scalar in ["\r","\n","\r\n","\u{2028}","\u{2029}","\u{85}","\u{b}","\u{c}"] {
            let front = "{{c1::첫 줄 &amp;" + scalar + "다음 줄}}", card = try VaultReviewCard.parse(base.replacing(.front,with:front))!
            check(!accepted { _ = try card.reviewQuestion(revealed:false) } && !accepted { _ = try card.rating(.hard,eventID:event,injectedDate:Date(timeIntervalSince1970:1_800_000_000)) } && card.noteSelection(NSRange(location:0,length:0),field:.front) == nil,"R2 newline \(scalar.unicodeScalars.map { $0.value }) 거부 유지")
            check(card.text(for:.front).utf8.elementsEqual(front.utf8),"R2 원문 보존")
        }
        try JSONSerialization.data(withJSONObject:["count":assertions.count,"assertions":assertions,"failures":failures,"cases":rows,"ModelOnly":true,"StoreExecuted":false,"whole122Repeated":false,"HTTP":false,"GUI":false],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("observations.json"))
        print("RESULT",assertions.count,"checks",failures.count,"failures")
        if !failures.isEmpty { exit(1) }
    }
}
