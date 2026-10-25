import Foundation

var count = 0
func check(_ value: Bool, _ label: String) {
    precondition(value,label)
    count += 1
    print("통과 \(label)")
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let decoder = JSONDecoder()
func encoded(_ scene: CanvasScene) -> Data { try! encoder.encode(scene) }
var base = CanvasScene()
let a = base.addNode(kind:.box,at:.init(x:100,y:200),text:"원본 e\u{301}")
let b = base.addNode(kind:.note,at:.init(x:700,y:650),text:"하위 요소")
check(base.connectAsChild(parent:a,child:b),"계층 연결")
let source = UUID()
base.nodes[0].sourceStrokeIds = [source]
base.nodes[0].vaultNote = .init(path:"Notes/fixture.md",sha256:String(repeating:"a",count:64),relayAddress:"http://fixture.invalid")
base.annotations = [.init(id:UUID(),nodeId:a,text:"첫 에이전트 주석",author:"에이전트"),
                    .init(id:UUID(),nodeId:nil,text:"전역 주석",author:"에이전트"),
                    .init(id:UUID(),nodeId:b,text:"하위 주석",author:"에이전트"),
                    .init(id:UUID(),nodeId:a,text:"둘째 에이전트 주석",author:"다른 에이전트")]
let original = try encoder.encode(base)
let text = " \t댓글 👩🏽‍💻 e\u{301}\r\n둘째 줄\n "
let session = base.commentSession(for:a)!
var scene = base
check(scene.setUserComment(text,session:session),"댓글 추가")
let comment = scene.annotations.last!
check(comment.nodeId == a && comment.author == "사용자","기존 주석 형태와 표시 작성자 재사용")
check(comment.text.utf8.elementsEqual(text.utf8),"공백·조합 문자·줄바꿈 바이트 보존")
check(scene.nodes == base.nodes && scene.links == base.links && scene.strokes == base.strokes &&
      scene.drawingBase64 == base.drawingBase64,"노드 본문·출처·연결 노트·원본 획 불변")
check(Array(scene.annotations.dropLast()) == base.annotations,"에이전트·전역 주석 원문 보존")
check(scene.revision == base.revision + 1,"수정 번호 한 번 증가")
let committed = try encoder.encode(scene)
check(!scene.setUserComment("늦은 중복",session:session) && encoded(scene) == committed,"중복·늦은 확인 거부")
let edit = scene.commentSession(for:a)!
check(edit.annotation?.id == comment.id,"기존 사용자 댓글 식별자 재사용")
check(scene.setUserComment("수정한 댓글",session:edit) && scene.annotations.last?.id == comment.id &&
      scene.annotations.count == base.annotations.count + 1,"댓글 수정은 추가하지 않음")
for empty in ["", " \t\r\n", "\u{2003}\u{00a0}"] {
    let before = try encoder.encode(scene)
    check(!scene.setUserComment(empty,session:scene.commentSession(for:a)!) &&
          encoded(scene) == before,"빈 댓글 거부·기존 원문 보존")
}
var composedComment = scene
composedComment.annotations[composedComment.annotations.count-1].text = "e\u{301}"
let composedSession = composedComment.commentSession(for:a)!
composedComment.annotations[composedComment.annotations.count-1].text = "é"
check(!composedSession.matches(composedComment),"기존 댓글이 정규화 동등 문자로 바뀌어도 다른 원문으로 감지")
let current = scene.commentSession(for:a)!
for change: (inout CanvasScene) -> Void in [
    { $0.id = UUID() }, { $0.revision += 1 }, { $0.nodes.removeFirst() },
    { $0.nodes[0].text = "다른 본문" }, { $0.annotations[0].text = "원격 수정" },
    { $0.annotations[0].author = "다른 작성자" }, { $0.nodes[0].isCollapsed = true; $0.nodes[0].text += "변경" },
    { $0.nodes[0].text = "원본 é" }
] {
    var changed = scene
    change(&changed)
    let before = try encoder.encode(changed)
    check(!changed.setUserComment("덮기 금지",session:current) &&
          encoded(changed) == before,"다른 장면·번호·노드·원격 변경 거부")
}
var canonical = base
canonical.nodes[0].text = "원본 é"
check(!session.matches(canonical),"정규화로 같은 문자열도 다른 바이트면 거부")
var ambiguous = scene
ambiguous.annotations.append(.init(id:UUID(),nodeId:a,text:"다른 사용자 댓글",author:"사용자"))
let ambiguousBytes = try encoder.encode(ambiguous)
check(ambiguous.commentSession(for:a) == nil && !ambiguous.setUserComment("덮기",session:current) &&
      encoded(ambiguous) == ambiguousBytes,"같은 노드의 사용자 댓글 여러 개는 거부·보존")
var duplicateID = scene
duplicateID.annotations.append(duplicateID.annotations.last!)
check(duplicateID.commentSession(for:a) == nil,"중복 댓글 식별자 거부")
check(scene.commentSession(for:UUID()) == nil,"없는 노드에 자동 배정하지 않음")
let frames = scene.annotationFrames
let node = scene.nodes[0]
check(frames[scene.annotations[0].id] == .init(x:node.frame.x,y:node.frame.y+node.frame.height+8,width:300,height:80),"첫 미리보기 위치")
let ordered = scene.annotations.filter { $0.nodeId == a }
for (index, note) in ordered.enumerated() {
    check(frames[note.id]?.y == node.frame.y+node.frame.height+8+Double(index)*88,"배열 순서대로 미리보기 배치")
    if index > 0 {
        let previous = frames[ordered[index-1].id]!
        check(frames[note.id]!.y - previous.y - previous.height == 8,"같은 노드의 미리보기 겹침 없음")
    }
}
check(frames[base.annotations[1].id] == nil,"전역 주석 위치 추측 없음")
var folded = scene
check(folded.toggleChildren(of:a),"상위 요소 접기")
check(folded.annotationFrames[base.annotations[2].id] == nil &&
      folded.annotationFrames[comment.id] != nil && folded.annotations == scene.annotations,"계층 숨김 표시만 적용·원문 유지")
check(folded.commentSession(for:b) == nil,"숨은 노드 댓글 편집 거부")
let restored = try decoder.decode(CanvasScene.self,from:committed)
check(encoded(restored) == committed,"장면 JSON 정확한 왕복")
let json = try JSONSerialization.jsonObject(with:committed) as! [String:Any]
let notes = json["annotations"] as! [[String:Any]]
check(Set(notes.last!.keys) == ["id","nodeId","text","author"] && json["annotationFrames"] == nil,
      "새 주석 스키마·배치 저장 필드 없음")
let voice = VoiceSession(threadId:UUID(),sessionId:"격리 시험",observedAt:"")
let packet = try CanvasPacket(scene:restored,imagePNG:Data([137,80,78,71,13,10,26,10]),session:voice)
check((try! packet.frozenScene()).annotations.last!.text.utf8.elementsEqual(text.utf8),"기존 패킷에서 에이전트가 전체 댓글 읽기")
var large = base
let beforeLarge = try encoder.encode(large)
check(!large.setUserComment(String(repeating:"가",count:CanvasPacket.sceneByteLimit),session:session) &&
      encoded(large) == beforeLarge,"실제 장면 패킷 한도 거부·원본 불변")
var long = base
let longText = String(repeating:"긴 댓글\n",count:5000)
check(long.setUserComment(longText,session:session) && long.annotations.last!.text == longText,
      "미리보기 때문에 본문을 자르거나 임의 문자 한도를 추가하지 않음")
check(encoded(base) == original,"입력 원본 불변")
print("카드 댓글 순수 모델 검사 \(count)개 통과")
