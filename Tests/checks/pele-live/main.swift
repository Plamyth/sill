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
print("PASS 한글 노드·관계, 동일 UUID 수정, 멱등 재수신, 중복·오래된·UTF8 충돌 거부, 출처·원본 획 보존, 입력 한도")
