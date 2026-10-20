import Foundation

let out = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PELE_OUTPUT"]!)
var scene = CanvasScene()
scene.id = UUID(uuidString:"11111111-1111-4111-8111-111111111111")!
scene.drawingBase64 = "raw-pencil-bytes"
let stroke = InkStroke(id:UUID(),points:[InkPoint(x:11,y:12,pressure:0.7)],createdAt:Date(timeIntervalSince1970:1))
scene.strokes = [stroke]
let a = scene.addNode(kind:.box,at:CanvasPoint(x:100,y:200),text:"한글 출발 👩🏽‍💻 e\u{301}",sourceStrokeIds:[stroke.id])
let b = scene.addNode(kind:.note,at:CanvasPoint(x:600,y:200),text:"검토 \"따옴표\" <img src=https://example.com> %%")
precondition(scene.connect(a,to:b,label:"검증 → 저장"))
let before = scene
let first = try CanvasDiagramSnapshot(scene:scene)
let edit = CanvasNodeTextEdit(expected:scene.nodes[0],text:"AI가 수정한 한글 👩🏽‍💻")
var relation = scene.links[0]
relation.label = "수정한 관계"
let change = AgentRevision(sceneId:scene.id,baseRevision:scene.revision,annotations:[],proposedNodes:[],
    nodeEdits:[edit],linkEdits:[CanvasLinkEdit(expected:scene.links[0],replacement:relation)])
let decodedChange = try JSONDecoder().decode(AgentRevision.self,from:JSONEncoder().encode(change))
precondition(scene.apply(decodedChange))
let second = try CanvasDiagramSnapshot(scene:scene)
precondition(scene.nodes[0].id == a && scene.nodes[0].sourceStrokeIds == [stroke.id])
precondition(scene.nodes[0].frame == before.nodes[0].frame && scene.nodes[0].text == edit.text)
precondition(scene.drawingBase64 == before.drawingBase64 && scene.strokes == before.strokes)
precondition(first.source != second.source && first.nodes[0].diagramID == second.nodes[0].diagramID)
let applied = scene
precondition(scene.apply(change) && scene == applied,"재수신은 멱등적으로 처리해야 합니다")
var duplicate = change
duplicate.nodeEdits = [edit,edit]
precondition(!scene.apply(duplicate) && scene == applied,"중복 명령을 거부해야 합니다")
var stale = change
stale.nodeEdits![0].text = "늦은 덮어쓰기"
precondition(!scene.apply(stale) && scene == applied,"오래된 수정은 거부해야 합니다")
var atomic = change
atomic.baseRevision = scene.revision
atomic.nodeEdits = [CanvasNodeTextEdit(expected:scene.nodes[0],text:"적용되면 안 됨")]
atomic.linkEdits![0].expected = scene.links[0]
atomic.linkEdits![0].replacement.to = UUID()
precondition(!scene.apply(atomic) && scene == applied,"끊어진 관계는 전체 수정을 거부해야 합니다")
var unicode = scene
unicode.nodes[0].text = "é"
var expected = unicode.nodes[0]
expected.text = "e\u{301}"
precondition(!unicode.editGraph(nodeEdits:[.init(expected:expected,text:"잘못된 수정")],linkEdits:[]))
var linked = scene
linked.nodes[0].vaultNote = VaultNoteReference(path:"Notes/test.md",sha256:"abc",relayAddress:"http://127.0.0.1:1")
precondition(!linked.editGraph(nodeEdits:[.init(expected:linked.nodes[0],text:"직접 수정")],linkEdits:[]))
var malformed = scene
malformed.nodes.append(malformed.nodes[0])
precondition((try? CanvasDiagramSnapshot(scene:malformed)) == nil)
var tooBig = scene
tooBig.nodes[0].text = String(repeating:"한",count:20000)
precondition((try? CanvasDiagramSnapshot(scene:tooBig)) == nil)
var punctuation = scene
punctuation.nodes[0].text = "\"]\nclick n123 \"https://example.com\"\n%% <script>"
let escaped = try CanvasDiagramSnapshot(scene:punctuation)
precondition(escaped.source.components(separatedBy:"\n").count == 4,"본문이 Mermaid 문법으로 탈출하면 안 됩니다")
try JSONEncoder().encode([first,second,escaped]).write(to:out.appendingPathComponent("snapshots.json"))
try JSONEncoder().encode(scene).write(to:out.appendingPathComponent("edited-scene.json"))
var mixedFailures = 0
func checkMixed(_ value: Bool, _ message: String) {
    print("\(value ? "PASS" : "FAIL") \(message)")
    if !value { mixedFailures += 1 }
}
var graph = before
let c = graph.addNode(kind:.box,at:.init(x:900,y:200),text:"C")
let d = graph.addNode(kind:.box,at:.init(x:1200,y:200),text:"D")
graph.links[0].kind = .parentChild
var proposal = graph.nodes[2]
proposal.id = UUID()
proposal.confidence = .proposal
proposal.sourceStrokeIds = [stroke.id]
var moved = graph.links[0]
moved.to = proposal.id
let addAndMove = AgentRevision(sceneId:graph.id,baseRevision:graph.revision,annotations:[],
    proposedNodes:[proposal],nodeEdits:[.init(expected:graph.nodes[0],text:"같은 배치 수정")],
    linkEdits:[.init(expected:graph.links[0],replacement:moved)])
var mixed = graph
checkMixed(mixed.apply(addAndMove),"혼합 배치에서 새 노드 추가와 기존 링크 끝점 이동을 함께 수용")
if mixed.revision == graph.revision + 1 {
    checkMixed(mixed.links[0] == moved && mixed.nodes.last == proposal &&
        mixed.nodes[0].confidence == .confirmed && mixed.nodes.last?.confidence == .proposal &&
        mixed.strokes == graph.strokes && mixed.drawingBase64 == graph.drawingBase64,
        "혼합 배치는 한 revision으로 제안 구분과 원본 획을 보존")
    let accepted = mixed
    checkMixed(mixed.apply(addAndMove) && mixed == accepted,"새 노드 혼합 배치 재수신은 멱등적")
}
var twoSteps = graph
precondition(twoSteps.apply(.init(sceneId:graph.id,baseRevision:graph.revision,annotations:[],proposedNodes:[proposal])))
precondition(twoSteps.editGraph(nodeEdits:addAndMove.nodeEdits!,linkEdits:addAndMove.linkEdits!))
checkMixed(mixed.hasSameGraph(as:twoSteps),"새 노드 혼합 결과는 두 단계 적용과 같은 그래프")

let newParent = CanvasLink(id:UUID(),from:d,to:b,label:"새 부모",kind:.parentChild)
moved = graph.links[0]
moved.to = c
let reparent = AgentRevision(sceneId:graph.id,baseRevision:graph.revision,annotations:[],proposedNodes:[],
    proposedLinks:[newParent],linkEdits:[.init(expected:graph.links[0],replacement:moved)])
var hierarchy = graph
checkMixed(hierarchy.apply(reparent),"혼합 배치에서 A→B를 A→C로 바꾸며 D→B를 추가")
twoSteps = graph
precondition(twoSteps.editGraph(nodeEdits:[],linkEdits:reparent.linkEdits!))
precondition(twoSteps.apply(.init(sceneId:graph.id,baseRevision:twoSteps.revision,annotations:[],
    proposedNodes:[],proposedLinks:[newParent])))
checkMixed(hierarchy.hasSameGraph(as:twoSteps),"부모 이동 혼합 결과는 두 단계 적용과 같은 그래프")
let reparented = hierarchy
checkMixed(hierarchy.apply(reparent) && hierarchy == reparented,"부모 이동 혼합 배치 재수신은 멱등적")

func rejectMixed(_ command: AgentRevision, in original: CanvasScene = graph, _ label: String) {
    var candidate = original
    checkMixed(!candidate.apply(command) && candidate == original,"혼합 배치 전체 거부와 원자성 · " + label)
}
var invalid = addAndMove
invalid.proposedNodes[0].id = graph.nodes[0].id
rejectMixed(invalid,"제안 노드와 기존 수정 대상 겹침")
invalid = addAndMove
invalid.proposedNodes.append(proposal)
rejectMixed(invalid,"제안 ID 중복")
invalid = addAndMove
invalid.linkEdits![0].replacement.to = UUID()
rejectMixed(invalid,"최종 끝점 누락")
invalid = reparent
invalid.linkEdits![0].replacement.to = b
rejectMixed(invalid,"최종 다중 부모")
invalid = reparent
invalid.proposedLinks![0].from = c
invalid.proposedLinks![0].to = a
rejectMixed(invalid,"최종 계층 순환")
invalid = addAndMove
invalid.nodeEdits![0].text = String(repeating:"한",count:6000)
rejectMixed(invalid,"텍스트 UTF8 한도")
invalid = addAndMove
invalid.linkEdits![0].replacement.label = String(repeating:"한",count:1400)
rejectMixed(invalid,"링크 UTF8 한도")
invalid = addAndMove
invalid.nodeEdits![0].expected.text = "바뀐 기대 상태"
rejectMixed(invalid,"오래된 기대 상태")
var exact = graph
exact.nodes[0].text = "é"
invalid = addAndMove
invalid.nodeEdits![0].expected = exact.nodes[0]
invalid.nodeEdits![0].expected.text = "e\u{301}"
rejectMixed(invalid,in:exact,"동등한 Unicode의 다른 UTF8")
exact = graph
exact.nodes[0].vaultNote = linked.nodes[0].vaultNote
invalid = addAndMove
invalid.nodeEdits![0].expected = exact.nodes[0]
rejectMixed(invalid,in:exact,"linked-vault 직접 수정")
invalid = addAndMove
invalid.proposedNodes[0].sourceStrokeIds = [UUID()]
rejectMixed(invalid,"제안 원본 획 출처 불일치")
if mixedFailures > 0 { exit(1) }
print("PASS 한글 노드·관계, 동일 UUID 수정, 멱등 재수신, 중복·오래된·UTF8 충돌 거부, 출처·원본 획 보존, 입력 한도")
