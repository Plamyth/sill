import Foundation
import PencilKit
import Combine
import AppKit

@main struct NodeResizeChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let env = ProcessInfo.processInfo.environment
        let home = env["CFFIXED_USER_HOME"]!
        let output = URL(fileURLWithPath:env["PELE_OUTPUT"]!)
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/") && env["HOME"] == home)
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value,label)
            count += 1
            print("PASS \(label)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let store = CanvasStore(blockRecoveryURL:output.appendingPathComponent("recovery.json"))
        store.scene = CanvasScene()
        let stroke = PKStroke(ink:PKInk(.pen,color:.white),path:PKStrokePath(controlPoints:[
            PKStrokePoint(location:CGPoint(x:15,y:20),timeOffset:0,size:CGSize(width:3,height:3),
                opacity:1,force:0.7,azimuth:0,altitude:1),
            PKStrokePoint(location:CGPoint(x:70,y:90),timeOffset:1,size:CGSize(width:4,height:4),
                opacity:1,force:0.8,azimuth:0,altitude:1)],creationDate:Date(timeIntervalSince1970:10)),
            transform:CGAffineTransform(a:1.2,b:0.1,c:0.2,d:0.9,tx:30,ty:40),
            mask:NSBezierPath(rect:CGRect(x:60,y:40,width:40,height:110)))
        let drawing = PKDrawing(strokes:[stroke])
        store.updateDrawing(drawing)
        check(stroke.mask != nil && !stroke.maskedPathRanges.isEmpty,"부분 마스크·transform이 있는 native fixture")
        let a = store.scene.addNode(kind:.box,at:.init(x:100,y:200),text:"원본 👩🏽‍💻 e\u{301}")
        let b = store.scene.addNode(kind:.note,at:.init(x:700,y:650),text:"연결된 노트")
        check(store.scene.connect(a,to:b,label:"유지할 연결"),"연결 fixture 생성")
        store.scene.links[0].fromAnchor = .init(side:.right,offset:0.75)
        store.scene.links[0].toAnchor = .init(side:.left,offset:0.25)
        store.scene.nodes[0].sourceStrokeIds = store.scene.strokes.map(\.id)
        let noteText = "# 격리 노트\n\n연결된 문단 ^fixture\n"
        let note = VaultNoteSnapshot(path:"Notes/fixture.md",text:noteText,
            sha256:CanvasPacket.sha(Data(noteText.utf8)),modifiedAt:"fixture")
        store.scene.nodes[0].vaultNote = .init(path:note.path,sha256:note.sha256,
            relayAddress:"http://fixture.invalid",blockID:"fixture",sourceState:.current)
        store.scene.annotations = [.init(id:UUID(),nodeId:a,text:"보존할 주석",author:"검사")]
        store.mode = .select
        store.selectedNode = a
        let base = store.scene
        let node = base.nodes[0]
        var writes = 0
        let observer = store.$scene.dropFirst().sink { _ in writes += 1 }
        defer { observer.cancel() }
        func begin(_ owner: UUID = UUID()) -> UUID {
            check(store.beginNodeResize(store.scene.nodes[0],sceneID:store.scene.id,owner:owner),"선택 노드 드래그 시작")
            return owner
        }
        let owner = begin()
        for amount in [20.0,70,140] {
            check(store.updateNodeResize(owner:owner,translation:.init(x:amount,y:amount / 2)),"드래그 미리보기 갱신")
        }
        check(store.scene == base && writes == 0 && !store.canUndoGraph,"미리보기는 scene·revision·Undo·저장 쓰기 0")
        let preview = store.displayedScene
        check(preview.nodes[0].frame == .init(x:100,y:200,width:400,height:190),"원점 고정과 누적 크기 미리보기")
        let ends = preview.linkEndpoints(base.links[0])!
        check(ends.from == .init(x:500,y:342.5) && ends.to == base.linkEndpoints(base.links[0])!.to,
              "명시 연결점은 미리보기 경계를 즉시 추종")
        var auto = base.links[0]
        auto.fromAnchor = nil
        auto.toAnchor = nil
        check(preview.linkEndpoints(auto)!.from != base.linkEndpoints(auto)!.from &&
              preview.linkEndpoints(auto)!.to != base.linkEndpoints(auto)!.to,"자동 연결점 양끝은 미리보기 중심·경계 추종")
        store.saveNow()
        let interim = CanvasStore(blockRecoveryURL:output.appendingPathComponent("interim.json"))
        check(interim.scene == base,"드래그 중 저장·재열기는 미확정 크기를 저장하지 않음")
        check(store.finishNodeResize(owner:owner) && writes == 1 && store.scene.revision == base.revision + 1,
              "한 드래그는 scene 쓰기·revision 증가 각 1회")
        let resized = store.scene
        var preserved = resized
        preserved.nodes[0].frame = node.frame
        preserved.revision = base.revision
        check(try encoder.encode(preserved) == encoder.encode(base),"frame·revision 외 모든 JSON 바이트 의미 보존")
        check(store.drawing == drawing && store.scene.drawingBase64 == base.drawingBase64 &&
              store.scene.strokes == base.strokes,"native 잉크·transform·sourceStrokeIDs 보존")
        store.undoGraphEdit()
        check(store.scene.hasSameGraph(as:base) && !store.canUndoGraph && store.canRedoGraph,"드래그 전체를 Undo 한 번으로 복원")
        store.redoGraphEdit()
        check(store.scene.hasSameGraph(as:resized) && !store.canRedoGraph,"Redo 한 번으로 크기 복원")
        let beforeNoop = store.scene
        let oldWrites = writes
        let noop = begin()
        check(store.updateNodeResize(owner:noop,translation:.init(x:0,y:0)) && store.finishNodeResize(owner:noop) &&
              store.scene == beforeNoop && writes == oldWrites,"no-op 크기는 scene·revision 쓰기 0")
        check(store.canUndoGraph,"no-op은 기존 Undo를 덮지 않음")
        for zoom in [0.5,1.0,2.0,3.0] {
            store.scene = base
            store.viewport = CanvasViewport(zoom:zoom,pan:CGSize(width:137,height:-51))
            store.selectedNode = a
            let drag = begin()
            let start = node.frame.center
            let worldStart = CanvasPoint(x:node.frame.x + node.frame.width - 9 / zoom,
                                         y:node.frame.y + node.frame.height + 7 / zoom)
            let viewStart = CGPoint(x:worldStart.x * zoom + store.pan.width,y:worldStart.y * zoom + store.pan.height)
            let viewEnd = CGPoint(x:viewStart.x + 60 * zoom,y:viewStart.y - 30 * zoom)
            let worldEnd = CanvasPoint(x:(viewEnd.x - store.pan.width) / zoom,y:(viewEnd.y - store.pan.height) / zoom)
            check(store.updateNodeResize(owner:drag,translation:.init(x:worldEnd.x - worldStart.x,y:worldEnd.y - worldStart.y)) &&
                  store.finishNodeResize(owner:drag) && store.scene.nodes[0].frame == .init(x:100,y:200,width:320,height:90),
                  "zoom \(zoom)·pan·손잡이 내부 오프셋에서 canvas 좌표 크기 확정")
            check(store.scene.nodes[0].frame.center != start,"크기 조절은 좌상단을 유지")
        }
        store.scene = base
        store.selectedNode = a
        let shrink = begin()
        check(store.updateNodeResize(owner:shrink,translation:.init(x:-200,y:-80)) && store.finishNodeResize(owner:shrink) &&
              store.scene.nodes[0].frame == .init(x:100,y:200,width:60,height:40),"축소 확정")
        let minimum = begin()
        check(store.updateNodeResize(owner:minimum,translation:.init(x:-59.5,y:-39.5)) && store.finishNodeResize(owner:minimum) &&
              store.scene.nodes[0].frame.width == 0.5,"유한 양수 크기 허용")

        for delta in [CanvasPoint(x:-260,y:0),.init(x:-261,y:0),.init(x:0,y:-120),
                      .init(x:.nan,y:0),.init(x:0,y:.infinity),.init(x:-.infinity,y:0)] {
            store.scene = base
            store.selectedNode = a
            let drag = begin()
            check(!store.updateNodeResize(owner:drag,translation:delta) && !store.finishNodeResize(owner:drag) &&
                  store.scene == base && store.nodeResizeDrag == nil,"0·음수·비유한 크기는 확정 없이 취소")
        }
        store.scene = base
        store.selectedNode = a
        store.scene.nodes[0].frame.x = Double.greatestFiniteMagnitude
        store.scene.nodes[0].frame.width = Double.greatestFiniteMagnitude
        check(!store.beginNodeResize(store.scene.nodes[0],sceneID:base.id,owner:UUID()),"끝 좌표 overflow 프레임 시작 거부")
        store.scene = base
        store.selectedNode = a
        check(!store.beginNodeResize(node,sceneID:UUID(),owner:UUID()),"기대 sceneID 불일치 거부")
        var stale = node
        stale.text = "원본 👩🏽‍💻 é"
        check(stale.text == node.text && !store.beginNodeResize(stale,sceneID:base.id,owner:UUID()),"정규화 동등 문자도 원본 UTF-8 다르면 거부")
        for mode in [CanvasMode.pen,.eraser,.lasso] {
            store.mode = mode
            check(!store.beginNodeResize(node,sceneID:base.id,owner:UUID()),"선택 모드 외 크기 조절 거부")
        }
        let mutations: [(String,(CanvasStore) -> Void)] = [
            ("장면 교체",{ $0.scene.id = UUID() }),
            ("같은 ID 장면 재수신",{ $0.scene = base }),
            ("노드 텍스트 변경",{ $0.scene.nodes[0].text = "새 입력" }),
            ("동시 다른 노드 변경",{ $0.scene.nodes[1].frame.width += 10 }),
            ("동시 링크 변경",{ $0.scene.links[0].label = "최신 링크" }),
            ("동시 주석 변경",{ $0.scene.annotations[0].text = "최신 주석" }),
            ("장면 revision 변경",{ $0.scene.revision += 1 }),
            ("선택 해제 후 복귀",{ $0.selectedNode = nil; $0.selectedNode = a }),
            ("모드 전환 후 복귀",{ $0.mode = .pen; $0.mode = .select }),
            ("원본 잉크 갱신",{ $0.updateDrawing(PKDrawing(strokes:[stroke,stroke])) }),
            ("노드 숨김",{ value in
                _ = value.scene.connectAsChild(parent:b,child:a)
                _ = value.scene.toggleChildren(of:b)
            })
        ]
        for (label,mutate) in mutations {
            store.scene = base
            store.mode = .select
            store.selectedNode = a
            let drag = begin()
            check(store.updateNodeResize(owner:drag,translation:.init(x:90,y:30)),"취소 전 미리보기")
            mutate(store)
            let latest = try encoder.encode(store.scene)
            check(!store.updateNodeResize(owner:drag,translation:.init(x:300,y:200)) &&
                  !store.finishNodeResize(owner:drag) && store.nodeResizeDrag == nil &&
                  store.displayedScene == store.scene,"\(label) 시 오래된 드래그 거부")
            check(try encoder.encode(store.scene) == latest,"\(label) 이후 최신 JSON 유지")
        }
        store.scene = base
        store.mode = .select
        store.selectedNode = a
        let first = begin(), second = UUID()
        check(!store.beginNodeResize(node,sceneID:base.id,owner:second) &&
              !store.cancelNodeResize(owner:second) && !store.finishNodeResize(owner:second) &&
              !store.updateNodeResize(owner:second,translation:.init(x:100,y:100)),"두 번째 포인터가 기존 드래그를 덮지 않음")
        check(store.cancelNodeResize(owner:first),"소유자 취소")
        _ = begin(second)
        check(!store.cancelNodeResize(owner:first) && !store.finishNodeResize(owner:first) &&
              !store.updateNodeResize(owner:first,translation:.init(x:100,y:100)) &&
              store.nodeResizeDrag?.owner == second,"취소된 이전 콜백은 새 드래그를 지우지 않음")
        check(store.updateNodeResize(owner:second,translation:.init(x:100,y:50)) && store.finishNodeResize(owner:second),"새 소유자 정상 확정")
        store.saveNow()
        let committed = store.scene
        let sceneURL = try CanvasRuntime.stateURL(.scene)
        check(sceneURL.path.hasPrefix(home + "/"),"장면 파일은 격리 HOME 내부")
        check(try JSONDecoder().decode(CanvasScene.self,from:CanvasLocalFile.read(sceneURL)) == committed,"실제 로컬 JSON readback")
        let reopened = CanvasStore(blockRecoveryURL:output.appendingPathComponent("reopened.json"))
        check(reopened.scene == committed && reopened.drawing == drawing,"새 Store 재열기의 크기·원본 잉크 보존")
        reopened.setNoteConnection(address:"http://fixture.invalid",token:"fixture")
        var fakeReads = 0
        await reopened.openVaultNote(note.path,nodeID:a) { path in
            precondition(path == note.path)
            fakeReads += 1
            return note
        }
        check(fakeReads == 1 && reopened.scene.nodes[0].vaultNote?.path == node.vaultNote?.path &&
              reopened.scene.nodes[0].vaultNote?.blockID == node.vaultNote?.blockID &&
              reopened.scene.nodes[0].vaultNote?.relayAddress == node.vaultNote?.relayAddress &&
              reopened.scene.nodes[0].frame == committed.nodes[0].frame,
              "기존 가짜 relay 캐시 갱신 뒤에도 크기·원본 문단 identity 유지")
        try encoder.encode(committed).write(to:output.appendingPathComponent("resized-scene.json"))
        store.drawing = drawing
        for delta in [CanvasPoint(x:20,y:0),CanvasPoint(x:-20,y:0),
                      CanvasPoint(x:0,y:20),CanvasPoint(x:0,y:-20)] {
            let before = store.scene
            let expected = before.nodes[0]
            check(store.adjustNodeSize(expected,sceneID:before.id,by:delta),"드래그 없는 크기 증감 실행")
            check(store.scene.nodes[0].frame.width == expected.frame.width + delta.x &&
                  store.scene.nodes[0].frame.height == expected.frame.height + delta.y &&
                  store.scene.revision == before.revision + 1,"접근성 증감은 지정한 축만 한 번 확정")
            let after = store.scene
            store.undoGraphEdit()
            check(store.scene.hasSameGraph(as:before),"접근성 한 동작을 한 번에 되돌리기")
            store.redoGraphEdit()
            check(store.scene.hasSameGraph(as:after) && store.drawing == drawing,
                  "접근성 다시 실행과 원본 잉크 보존")
        }
        let latest = store.scene
        var staleNode = latest.nodes[0]
        staleNode.text += " 이전 상태"
        check(!store.adjustNodeSize(staleNode,sceneID:latest.id,by:.init(x:20,y:0)) && store.scene == latest,
              "오래된 접근성 요소는 최신 상태를 덮지 않음")
        check(!store.adjustNodeSize(latest.nodes[0],sceneID:UUID(),by:.init(x:20,y:0)) && store.scene == latest,
              "다른 장면의 접근성 동작 거부")
        check(!store.adjustNodeSize(latest.nodes[0],sceneID:latest.id,by:.init(x:.infinity,y:0)) &&
              store.scene == latest && store.nodeResizeDrag == nil,"잘못된 접근성 크기는 취소하고 원본 보존")
        let active = begin()
        check(!store.adjustNodeSize(latest.nodes[0],sceneID:latest.id,by:.init(x:20,y:0)) &&
              store.nodeResizeDrag?.owner == active,"접근성 동작은 이미 진행 중인 드래그를 취소하지 않음")
        store.cancelNodeResize(owner:active)
        print("NODE_RESIZE_CHECKS assertions=\(count) deviceExecuted=false realVaultTouched=false")
    }
}
