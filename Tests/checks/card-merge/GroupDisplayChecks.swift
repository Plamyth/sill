import Foundation

@main struct GroupDisplayChecks {
    static func main() throws {
        let input = URL(fileURLWithPath:CommandLine.arguments[1])
        let raw = try Data(contentsOf:input)
        let scene = try JSONDecoder().decode(CanvasScene.self,from:raw)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(scene)
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw NSError(domain:"GroupDisplayChecks",code:1,userInfo:[NSLocalizedDescriptionKey:label]) }
            count += 1; print("PASS \(label)")
        }
        let group = try CanvasGroup.entries(in:scene).first!
        let mark = scene.annotations.first { $0.nodeId == group.node.id && $0.author == CanvasGroup.author }!
        try check(CanvasGroup.displayAuthor(mark) == "그룹 정보","inspector maps the reserved author to Korean")
        for (index,id) in group.memberIDs.enumerated() {
            let link = scene.links.first { $0.from == group.node.id && $0.to == id && $0.label == CanvasGroup.linkPrefix + String(index + 1) }!
            try check(CanvasGroup.displayLabel(link,in:scene) == "그룹 소속 \(index + 1)","valid membership keeps its original ordinal in Korean")
            try check(CanvasGroup.accessibilityLabel(link,in:scene) == "연결선 그룹 소속 \(index + 1)","actual A11y formatter uses the same Korean membership name")
            var stale = link; stale.id = UUID()
            try check(CanvasGroup.displayLabel(stale,in:scene).utf8.elementsEqual(stale.label.utf8),"a foreign link ID is not reinterpreted as membership")
        }
        var normal = scene
        let human = CanvasLink(id:UUID(),from:group.node.id,to:group.memberIDs[0],label:"내 연결 ccr.sill.group/v1 · 1 e\u{301}\r\n",kind:.general)
        normal.links.append(human)
        try check(CanvasGroup.displayLabel(human,in:normal).utf8.elementsEqual(human.label.utf8),"ordinary link text including a namespace substring stays byte exact")
        try check(CanvasGroup.accessibilityLabel(human,in:normal).utf8.elementsEqual(("연결선 " + human.label).utf8),"ordinary A11y text retains the original NFD and CRLF")
        let comment = CanvasAnnotation(id:UUID(),nodeId:group.memberIDs[0],text:CanvasGroup.author + " · 사용자 본문",author:"사용자 e\u{301}\r\n")
        try check(CanvasGroup.displayAuthor(comment).utf8.elementsEqual(comment.author.utf8),"ordinary comment author is not translated or normalized")
        var lookalike = mark; lookalike.author += " 사용자"
        try check(CanvasGroup.displayAuthor(lookalike).utf8.elementsEqual(lookalike.author.utf8),"an author merely containing the namespace remains ordinary text")
        var badVersion = scene
        let markIndex = badVersion.annotations.firstIndex { $0.id == mark.id }!
        badVersion.annotations[markIndex].author = "ccr.sill.group/v2"
        let versionBefore = try encoder.encode(badVersion)
        try check(CanvasGroup.displayAuthor(badVersion.annotations[markIndex]) == "ccr.sill.group/v2","unknown version is not presented as v1 group information")
        let firstLink = scene.links.first { $0.from == group.node.id && $0.label.hasPrefix(CanvasGroup.linkPrefix) }!
        try check(CanvasGroup.displayLabel(firstLink,in:badVersion).utf8.elementsEqual(firstLink.label.utf8),"unsupported group version does not receive a fabricated valid ordinal")
        var badOrder = scene
        let linkIndex = badOrder.links.firstIndex { $0.id == firstLink.id }!
        badOrder.links[linkIndex].label = CanvasGroup.linkPrefix + "01"
        let orderBefore = try encoder.encode(badOrder)
        try check(CanvasGroup.displayLabel(badOrder.links[linkIndex],in:badOrder) == CanvasGroup.linkPrefix + "01","invalid numbering is neither translated as valid nor renumbered")
        var plain = CanvasScene()
        plain.nodes = group.memberIDs.map { id in scene.nodes.first { $0.id == id }! }
        let orphan = CanvasLink(id:UUID(),from:plain.nodes[0].id,to:plain.nodes[1].id,label:CanvasGroup.linkPrefix + "1",kind:.general)
        plain.links = [orphan]
        try check(CanvasGroup.displayLabel(orphan,in:plain).utf8.elementsEqual(orphan.label.utf8),"namespace-like ordinary data without a valid group marker is preserved")
        let ordinary = CanvasLink(id:UUID(),from:plain.nodes[0].id,to:plain.nodes[1].id,label:"일반 관계 e\u{301}",kind:.general)
        plain.links = [ordinary]
        let diagram = try CanvasDiagramSnapshot(scene:plain)
        try check(diagram.source.contains("일반 관계 e\u{301}"),"existing diagram path retains ordinary Unicode link text")
        plain.links[0].label = ""
        try check(CanvasGroup.accessibilityLabel(plain.links[0],in:plain) == "연결선","existing empty A11y label is unchanged")
        let emptyDiagram = try CanvasDiagramSnapshot(scene:plain)
        try check(emptyDiagram.source.contains("연결"),"existing empty diagram relation is unchanged")
        let groupedDiagram = try CanvasDiagramSnapshot(scene:scene)
        try check(!groupedDiagram.source.contains("ccr"),"valid membership remains hidden and no new namespace text rendering path is added")
        try check(encoder.encode(badVersion) == versionBefore && encoder.encode(badOrder) == orderBefore,"formatting never repairs malformed data or versions")
        try check(encoder.encode(scene) == before && Data(contentsOf:input) == raw,"original IDs numbering labels author JSON and native ink remain byte exact")
        print("GROUP_DISPLAY_CHECKS_OK \(count)")
    }
}
