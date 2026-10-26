import Foundation
import PDFKit

func checkPDFExcerptFences(_ check: (Bool,String) -> Void) throws {
    let env = ProcessInfo.processInfo.environment
    let bytes = try Data(contentsOf:URL(fileURLWithPath:env["PDF_RECOVERY_FIXTURE"]!))
    let snapshot = VaultPDFSnapshot(path:"검수.pdf",sha256:CanvasPacket.sha(bytes),dataBase64:bytes.base64EncodedString())
    let document = PDFDocument(data:bytes)!, page = document.page(at:0)!
    let selection = page.selection(for:NSRange(location:0,length:(page.string! as NSString).length))!
    let excerpt = try VaultPDFExcerpt.capture(snapshot:snapshot,document:document,selection:selection)
    let markdown = try excerpt.markdown()
    let home = URL(fileURLWithPath:env["CFFIXED_USER_HOME"]!)
    var ordinal = 0
    func accepts(_ text: String, _ expected: VaultPDFExcerpt?, _ label: String) throws {
        ordinal += 1
        let file = home.appendingPathComponent("fence-\(ordinal).md")
        try text.write(to:file,atomically:true,encoding:.utf8)
        do { check(try VaultPDFExcerpt.parse(String(contentsOf:file,encoding:.utf8)) == expected,label) }
        catch { check(false,"\(label): \(error)") }
    }
    func rejects(_ text: String, _ label: String) throws {
        ordinal += 1
        let file = home.appendingPathComponent("fence-\(ordinal).md")
        try text.write(to:file,atomically:true,encoding:.utf8)
        do { _ = try VaultPDFExcerpt.parse(String(contentsOf:file,encoding:.utf8)); check(false,label) }
        catch { check(true,label) }
    }
    check(snapshot.sha256 == "6faad94589f78548669853c7ca2271141d72ccbd8c1905462f79274c13ef61eb",
          "fence checks use the retained Unicode PDF")
    try accepts(markdown,excerpt,"canonical top-level payload")
    let example = "```ccr-pdf-source-v99\n{}\n```\n"
    try accepts(markdown + "\n## 코드 예제 메모\n\n````markdown\n" + example + "````\n",excerpt,
                "P2-R1 valid excerpt plus memo code example")
    try accepts("````markdown\n" + markdown + "\n````\n",nil,"P2-R1 full excerpt is only code example")
    for (open,close) in [("````markdown","````"),("~~~~markdown","~~~~"),("`````markdown","``````"),
                         ("~~~markdown","~~~~~"),("   ````markdown","  ````` \t"),("  ~~~~text","   ~~~~") ] {
        let hidden = open + "\n" + markdown + "\n" + close + "\n"
        try accepts(hidden,nil,"outer context hides payload: \(open)")
        try accepts(hidden + "\n" + markdown,excerpt,"outer close restores top-level: \(open)")
        try accepts(markdown + "\n" + hidden,excerpt,"memo after payload: \(open)")
    }
    for middle in ["```","~~~","`````oops","    `````","``` \t"] {
        try accepts("````markdown\n" + middle + "\n" + markdown + "\n````\n",nil,
                    "short, mismatched, indented or suffixed close stays in code: \(middle)")
    }
    try accepts("~~~markdown\n```\n" + markdown,nil,"unclosed tilde context remains code")
    for lineEnding in ["\n","\r\n"] {
        let text = ("~~~~markdown\n" + example + "~~~~\n\n" + markdown).replacingOccurrences(of:"\n",with:lineEnding)
        try accepts(text,excerpt,"line endings preserve real payload \(lineEnding.debugDescription)")
    }
    let quoted = markdown.components(separatedBy:"\n").map { "> " + $0 }.joined(separator:"\n")
    let indented = markdown.components(separatedBy:"\n").map { "    " + $0 }.joined(separator:"\n")
    let tabbed = markdown.components(separatedBy:"\n").map { "\t" + $0 }.joined(separator:"\n")
    let escaped = markdown.replacingOccurrences(of:"```",with:"\\`\\`\\`")
    let jsonString = String(decoding:try JSONEncoder().encode(markdown),as:UTF8.self)
    for (label,text) in [("blockquote",quoted),("indented code",indented),("tab code",tabbed),
                         ("escaped delimiters",escaped),("JSON string",jsonString),
                         ("plain marker","메모 안 ccr-pdf-source-v99 및 `ccr-pdf-source`는 인용입니다.")] {
        try accepts(text,nil,"example is data: \(label)")
        try accepts(text + "\n\n" + markdown,excerpt,"example preserves one real payload: \(label)")
    }
    for unsupported in ["```ccr-pdf-source-v99","```ccr-pdf-source-v2-extra"," ```ccr-pdf-source-v2",
                        "~~~ccr-pdf-source-v2","````ccr-pdf-source-v2"] {
        try rejects(unsupported + "\n{}\n```\n","unsupported top-level source remains invalid: \(unsupported)")
    }
    try rejects(markdown + "\n" + markdown,"two actual top-level payloads refuse")
    try rejects("````markdown\n" + markdown + "\n````\n" + markdown + markdown,
                "hidden example cannot hide two real payloads")
    try rejects("```ccr-pdf-source-v2\n{}\n","unclosed actual payload refuses")
    try rejects(markdown + "\n" + example,"unsupported actual second payload refuses")
    check(try excerpt.sourcePage(in:snapshot).2.string?.utf8.elementsEqual(selection.string!.utf8) == true,
          "fence filtering retains exact Unicode NSRange source return")
    for quote in ["ordinary spaces\tand  tabs 한글 é 👩💻",
                  "공백 [링크](https://example.invalid) <img src=x> ![[노트]]\t끝",
                  "\\`코드` *강조* & &#60; [[위키]]\t한 칸 두  칸"] {
        var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(excerpt)) as! [String:Any]
        object["quote"] = quote
        let value = try JSONDecoder().decode(VaultPDFExcerpt.self,from:JSONSerialization.data(withJSONObject:object))
        let text = try value.markdown()
        let display = text.components(separatedBy:"\n\n## 메모")[0].components(separatedBy:"\n\n").dropFirst(2).joined(separator:"\n\n")
        check(display.contains(" ") && display.contains("\t") && !display.contains("&#32;") && !display.contains("&#9;"),
              "display quote keeps readable ordinary spaces and tabs")
        check(try VaultPDFExcerpt.parse(text)?.quote.utf8.elementsEqual(quote.utf8) == true,
              "display formatting preserves exact quote JSON bytes")
        check(!display.contains("[") && !display.contains("<") && !display.contains("`") && !display.contains("*"),
              "display quote keeps Markdown tag and wiki delimiters encoded")
        let rendered = try AttributedString(markdown:display)
        check(rendered.runs.allSatisfy({ $0.link == nil && $0.inlinePresentationIntent == nil }),
              "Foundation display quote activates zero links tags wiki or inline code")
        if quote.contains("[[위키]]") {
            check(String(rendered.characters).contains("[[위키]]"),"Foundation renders wiki example literally")
        }
        if quote.contains("<img") {
            check(String(rendered.characters).contains("<img src=x>"),"Foundation renders tag example literally")
        }
    }
    for opener in ["````markdown", "~~~markdown", "```"] {
        try accepts("<!--\n" + opener + "\n-->\n\n" + markdown,excerpt,
                    "HTML comment fence cannot hide real native Markdown payload")
    }
    for indent in ["    ", "\t", "  \t"] {
        let quote = indent + "[표본](https://example.invalid) <img src=x> ![[위키]]"
        var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(excerpt)) as! [String:Any]
        object["quote"] = quote
        let value = try JSONDecoder().decode(VaultPDFExcerpt.self,from:JSONSerialization.data(withJSONObject:object))
        let text = try value.markdown()
        let display = text.components(separatedBy:"\n\n## 메모")[0].components(separatedBy:"\n\n").dropFirst(2).joined(separator:"\n\n")
        let rendered = try AttributedString(markdown:display)
        check(String(rendered.characters).utf8.elementsEqual(quote.utf8),"leading quote indentation keeps literal visible text")
        check(rendered.runs.allSatisfy({ run in
            run.link == nil && run.inlinePresentationIntent == nil &&
            !(run.presentationIntent?.components.contains(where:{ if case .codeBlock = $0.kind { return true }; return false }) ?? false)
        }),"leading quote indentation activates no code block or links")
        check(try VaultPDFExcerpt.parse(text)?.quote.utf8.elementsEqual(quote.utf8) == true,
              "leading indentation preserves exact original quote JSON")
    }

}
