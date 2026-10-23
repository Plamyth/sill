import Foundation
import PencilKit
import Combine
import AppKit

@main struct NodeRotationChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let env = ProcessInfo.processInfo.environment
        let home = env["CFFIXED_USER_HOME"]!
        let output = URL(fileURLWithPath:env["PELE_OUTPUT"]!)
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/") && env["HOME"] == home)
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value,label); count += 1; print("PASS \(label)")
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
        func nearPoint(_ a: CanvasPoint, _ b: CanvasPoint) -> Bool { near(a.x,b.x) && near(a.y,b.y) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
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
        let a = store.scene.addNode(kind:.box,at:.init(x:100,y:200),text:"원본 👩🏽‍💻 e\u{301}")
        let b = store.scene.addNode(kind:.note,at:.init(x:700,y:650),text:"다른 노드")
        check(store.scene.connect(a,to:b,label:"유지할 연결"),"연결 fixture")
        store.scene.links[0].fromAnchor = .init(side:.right,offset:0.75)
        store.scene.links[0].toAnchor = .init(side:.left,offset:0.25)
        store.scene.nodes[0].sourceStrokeIds = store.scene.strokes.map(\.id)
        store.scene.nodes[1].vaultNote = .init(path:"Notes/fixture.md",sha256:String(repeating:"a",count:64),
            relayAddress:"http://fixture.invalid",blockID:"fixture",sourceState:.current)
        store.scene.annotations = [.init(id:UUID(),nodeId:a,text:"보존할 주석",author:"검사")]
        store.mode = .select
        store.selectedNode = a
        let base = store.scene, node = base.nodes[0]
        let oldJSON = try encoder.encode(base)
        check(!String(decoding:oldJSON,as:UTF8.self).contains("rotationDegrees"),"nil은 0도 필드를 쓰지 않음")
        check(try decoder.decode(CanvasScene.self,from:oldJSON) == base,"옛 JSON 변경 없이 읽기")
        var writes = 0
        let observer = store.$scene.dropFirst().sink { _ in writes += 1 }
        defer { observer.cancel() }
        func begin(_ owner: UUID = UUID()) -> UUID {
            check(store.beginNodeRotation(store.scene.nodes[0],sceneID:store.scene.id,owner:owner),"회전 시작")
            return owner
        }
        let owner = begin()
        for degree in [15.0,30,90] { check(store.updateNodeRotation(owner:owner,degrees:degree),"회전 미리보기") }
        check(store.scene == base && writes == 0 && !store.canUndoGraph,"미리보기 scene·revision·Undo 쓰기 0")
        let preview = store.displayedScene, rotated = preview.nodes[0]
        check(rotated.rotationDegrees == 90 && rotated.frame == node.frame,"미리보기 각도와 중심 고정")
        check(nearPoint(rotated.scenePoint(node.frame.center)!,node.frame.center),"중심 회전 고정")
        check(nearPoint(preview.linkEndpoints(base.links[0])!.from,.init(x:200,y:390)),"명시 right 0.75 anchor 90도 추종")
        check(preview.linkEndpoints(base.links[0])!.to == base.linkEndpoints(base.links[0])!.to,"다른 노드 명시 연결점 보존")
        var auto = base.links[0]; auto.fromAnchor = nil; auto.toAnchor = nil
        let endpoints = preview.linkEndpoints(auto)!
        let local = rotated.scenePoint(endpoints.from,inverse:true)!
        check(near(local.x,node.frame.x) || near(local.x,node.frame.x + node.frame.width) ||
              near(local.y,node.frame.y) || near(local.y,node.frame.y + node.frame.height),"자동 연결점은 회전 로컬 경계")
        let target = base.nodes[1].frame.center, center = node.frame.center
        check(near((endpoints.from.x-center.x)*(target.y-center.y),
                   (endpoints.from.y-center.y)*(target.x-center.x)),"자동 연결점은 상대 중심 방향")
        store.saveNow()
        let interim = CanvasStore(blockRecoveryURL:output.appendingPathComponent("interim.json"))
        check(interim.scene == base,"미리보기 중 실제 저장·재열기는 원본")
        check(store.finishNodeRotation(owner:owner) && writes == 1 && store.scene.revision == base.revision + 1,
              "확정 scene 쓰기·revision 각 1")
        let committed = store.scene
        var preserved = committed
        preserved.nodes[0].rotationDegrees = nil; preserved.revision = base.revision
        check(try encoder.encode(preserved) == oldJSON && store.drawing == drawing,"회전 외 raw ink·source·link·vault ID·텍스트 전부 보존")
        store.undoGraphEdit()
        check(store.scene.hasSameGraph(as:base) && store.canRedoGraph,"Undo 한 번 원래 nil 회전 복원")
        store.redoGraphEdit()
        check(store.scene.hasSameGraph(as:committed) && store.drawing == drawing,"Redo 한 번 회전·원본 PKDrawing 보존")
        let noopBase = store.scene, oldWrites = writes
        let noop = begin()
        check(store.updateNodeRotation(owner:noop,degrees:90) && store.finishNodeRotation(owner:noop) &&
              store.scene == noopBase && writes == oldWrites && store.canUndoGraph,"no-op은 revision·Undo·쓰기 보존")
        store.scene = base; store.selectedNode = a
        let nilNoop = begin()
        check(store.updateNodeRotation(owner:nilNoop,degrees:0) && store.finishNodeRotation(owner:nilNoop) &&
              store.scene.nodes[0].rotationDegrees == nil,"옛 nil의 0도 no-op 표현 보존")
        for zoom in [0.5,1,2,3] {
            store.scene = base; store.selectedNode = a
            store.viewport = CanvasViewport(zoom:zoom,pan:CGSize(width:137,height:-51))
            let owner = begin(), radius = node.frame.height / 2 + 44 / zoom
            let start = CanvasPoint(x:center.x,y:center.y + radius)
            let end = CanvasPoint(x:center.x - radius / sqrt(2),y:center.y + radius / sqrt(2))
            check(store.updateNodeRotation(owner:owner,from:start,to:end) && store.finishNodeRotation(owner:owner) &&
                  near(store.scene.nodes[0].rotationDegrees!,45),"zoom \(zoom) 화면 손잡이 중심 45도 회전")
        }
        for degrees in [Double.nan,.infinity,-.infinity,.greatestFiniteMagnitude] {
            store.scene = base; store.selectedNode = a
            let owner = begin()
            check(!store.updateNodeRotation(owner:owner,degrees:degrees) && !store.finishNodeRotation(owner:owner) &&
                  store.scene == base,"비유한·각도 overflow 거부")
            var bad = base; bad.nodes[0].rotationDegrees = degrees
            do { try store.importScene(bad); check(false,"잘못된 import 허용") } catch { check(store.scene == base,"잘못된 import 원본 보존") }
            do { _ = try encoder.encode(bad); check(false,"잘못된 저장 허용") } catch { check(true,"invalid 저장 거부") }
            var proposal = bad.nodes[0]; proposal.id = UUID(); proposal.confidence = .proposal
            let change = AgentRevision(sceneId:base.id,baseRevision:base.revision,annotations:[],proposedNodes:[proposal])
            check(!store.applyAgentRevision(change) && store.scene == base,"invalid agent 제안 원본 보존")
            let edit = AgentRevision(sceneId:base.id,baseRevision:base.revision,annotations:[],proposedNodes:[],
                                     nodeEdits:[.init(expected:bad.nodes[0],text:"덮어쓰기 금지")])
            check(!store.applyAgentRevision(edit) && store.scene == base,"invalid agent expected 원본 보존")
        }
        for raw in ["\"NaN\"","\"Infinity\"","1e309","1e308","true","{}"] {
            let text = String(decoding:try encoder.encode(node),as:UTF8.self)
            let bad = Data((text.dropLast() + ",\"rotationDegrees\":" + raw + "}").utf8)
            do { _ = try decoder.decode(CanvasNode.self,from:bad); check(false,"invalid JSON 허용") }
            catch { check(true,"invalid JSON 거부 \(raw)") }
        }
        var huge = node
        huge.frame = .init(x:1.5e308,y:0,width:1e307,height:1e308); huge.rotationDegrees = 45
        check(!huge.hasValidRotation,"회전 결과 좌표 overflow 거부")
        let mutations: [(String,(CanvasStore)->Void)] = [
            ("동일 장면 재수신",{ $0.scene = base }), ("새 장면",{ $0.scene.id = UUID() }),
            ("revision",{ $0.scene.revision += 1 }), ("새 텍스트",{ $0.scene.nodes[0].text += "새 입력" }),
            ("다른 노드",{ $0.scene.nodes[1].frame.width += 10 }),
            ("링크",{ $0.scene.links[0].label += "변경" }), ("주석",{ $0.scene.annotations[0].text += "변경" }),
            ("선택 전환",{ $0.selectedNode = nil; $0.selectedNode = a }),
            ("모드 전환",{ $0.mode = .pen; $0.mode = .select }),
            ("잉크",{ $0.updateDrawing(PKDrawing(strokes:[stroke,stroke])) }),
            ("숨김",{ _ = $0.scene.connectAsChild(parent:b,child:a); _ = $0.scene.toggleChildren(of:b) })]
        for (label,mutation) in mutations {
            store.scene = base; store.mode = .select; store.selectedNode = a
            let owner = begin(); check(store.updateNodeRotation(owner:owner,degrees:40),"stale 전 미리보기")
            mutation(store)
            let latest = try encoder.encode(store.scene)
            check(!store.updateNodeRotation(owner:owner,degrees:90) && !store.finishNodeRotation(owner:owner) &&
                  store.nodeRotationDrag == nil && store.displayedScene == store.scene,"\(label) stale 거부")
            check(try encoder.encode(store.scene) == latest,"\(label) 최신 변경 보존")
        }
        store.scene = base; store.mode = .select; store.selectedNode = a
        let first = begin(), second = UUID()
        check(!store.beginNodeRotation(node,sceneID:base.id,owner:second) &&
              !store.updateNodeRotation(owner:second,degrees:20) && !store.finishNodeRotation(owner:second) &&
              !store.cancelNodeRotation(owner:second),"다른 owner 거부")
        check(!store.beginNodeResize(node,sceneID:base.id,owner:second),"회전 중 resize 배타")
        check(store.cancelNodeRotation(owner:first) && store.scene == base,"취소 쓰기 0")
        _ = begin(second)
        check(!store.cancelNodeRotation(owner:first) && !store.finishNodeRotation(owner:first) &&
              store.nodeRotationDrag?.owner == second,"옛 callback 새 owner 보존")
        store.cancelNodeRotation(owner:second)
        check(store.beginNodeResize(node,sceneID:base.id,owner:first) &&
              !store.beginNodeRotation(node,sceneID:base.id,owner:second),"resize 중 회전 배타")
        store.cancelNodeResize(owner:first)
        check(!store.beginNodeRotation(node,sceneID:UUID(),owner:first),"scene identity 거부")
        var stale = node; stale.text = "원본 👩🏽‍💻 é"
        check(!store.beginNodeRotation(stale,sceneID:base.id,owner:first),"동등 Unicode의 다른 원본 UTF8 거부")
        for mode in [CanvasMode.pen,.eraser,.lasso] {
            store.mode = mode
            check(!store.beginNodeRotation(node,sceneID:base.id,owner:first),"선택 외 모드 거부")
        }
        store.mode = .select; store.selectedNode = a
        for degrees in [15.0,-15,0,90] {
            check(store.rotateNode(store.scene.nodes[0],sceneID:base.id,to:degrees) &&
                  (store.scene.nodes[0].rotationDegrees ?? 0) == degrees,"접근성 같은 Store 경로 \(degrees)")
        }
        // 회전 로컬 right 0.25를 화면으로 옮긴 뒤 endpoint가 정확한 로컬 anchor로 되돌리는지 검사.
        let rotatedScene = store.scene, expected = rotatedScene.nodes[0]
        let anchor = CanvasLinkAnchor(side:.right,offset:0.25)
        let worldPoint = expected.scenePoint(anchor.point(in:expected.frame)!)!
        store.selectLink(base.links[0].id)
        check(store.beginEndpointDrag(.from,linkID:base.links[0].id,owner:first),"회전된 endpoint 시작")
        check(!store.beginNodeRotation(expected,sceneID:base.id,owner:second),"endpoint 중 회전 배타")
        check(store.updateEndpointDrag(owner:first,to:worldPoint) &&
              store.displayedLink(store.scene.links[0]).fromAnchor == anchor && store.finishEndpointDrag(owner:first),
              "nearest endpoint 역변환과 확정")
        store.selectedNode = a
        let beforeResize = store.scene, beforeNode = beforeResize.nodes[0]
        let topLeft = beforeNode.scenePoint(.init(x:beforeNode.frame.x,y:beforeNode.frame.y))!
        let bottomRight = beforeNode.scenePoint(.init(x:beforeNode.frame.x + beforeNode.frame.width,y:beforeNode.frame.y + beforeNode.frame.height))!
        let localDelta = CanvasPoint(x:60,y:30), screenDelta = beforeNode.rotatedVector(localDelta)!
        check(store.beginNodeResize(beforeNode,sceneID:base.id,owner:first) &&
              store.updateNodeResize(owner:first,translation:screenDelta) && store.finishNodeResize(owner:first),"회전 후 resize")
        let resized = store.scene.nodes[0]
        check(near(resized.frame.width,beforeNode.frame.width+60) && near(resized.frame.height,beforeNode.frame.height+30),"resize 이동량 역회전")
        check(nearPoint(resized.scenePoint(.init(x:resized.frame.x,y:resized.frame.y))!,topLeft),"회전된 resize 좌상단 고정")
        check(nearPoint(resized.scenePoint(.init(x:resized.frame.x+resized.frame.width,y:resized.frame.y+resized.frame.height))!,
                        .init(x:bottomRight.x+screenDelta.x,y:bottomRight.y+screenDelta.y)),"회전된 resize 손잡이 화면 이동 추종")
        check(store.adjustNodeSize(resized,sceneID:base.id,by:.init(x:20,y:0)) &&
              near(store.scene.nodes[0].frame.width,resized.frame.width + 20),"회전 후 접근성 resize 로컬 축 유지")
        store.undoGraphEdit(); store.redoGraphEdit()
        store.moveSelected(to:CGPoint(x:300,y:400))
        check(store.scene.nodes[0].frame.x == 300 && store.scene.nodes[0].frame.y == 400 &&
              store.scene.nodes[0].rotationDegrees == 90,"회전 후 본문 화면 이동 계약")
        var proposal = node; proposal.id = UUID(); proposal.confidence = .proposal; proposal.rotationDegrees = 45
        check(store.applyAgentRevision(.init(sceneId:base.id,baseRevision:store.scene.revision,annotations:[],proposedNodes:[proposal])) &&
              store.scene.nodes.last?.rotationDegrees == 45,"agent proposal 회전 유지")
        let agentBase = store.scene, textNode = agentBase.nodes[0]
        check(store.applyAgentRevision(.init(sceneId:base.id,baseRevision:agentBase.revision,annotations:[],proposedNodes:[],
              nodeEdits:[.init(expected:textNode,text:"새 내용")])) && store.scene.nodes[0].rotationDegrees == 90,"agent text edit 회전 유지")
        var oldExpected = textNode; oldExpected.rotationDegrees = nil
        let latest = store.scene
        check(!store.applyAgentRevision(.init(sceneId:base.id,baseRevision:latest.revision,annotations:[],proposedNodes:[],
              nodeEdits:[.init(expected:oldExpected,text:"구형 덮어쓰기")])) && store.scene == latest,"회전 누락 구형 expected edit 충돌 거부")
        store.drawing = drawing
        store.saveNow()
        let saved = store.scene, sceneURL = try CanvasRuntime.stateURL(.scene)
        let savedBytes = try CanvasLocalFile.read(sceneURL)
        check(try decoder.decode(CanvasScene.self,from:savedBytes) == saved,"회전 실제 JSON readback")
        let reopened = CanvasStore(blockRecoveryURL:output.appendingPathComponent("reopened.json"))
        check(reopened.scene == saved && reopened.drawing == drawing,"재열기 회전과 PKDrawing 보존")
        try reopened.importScene(try decoder.decode(CanvasScene.self,from:savedBytes))
        check(reopened.scene == saved,"import 회전 전체 보존")
        reopened.saveNow()
        let lastValidBytes = try CanvasLocalFile.read(sceneURL)
        var invalid = reopened.scene; invalid.nodes[0].rotationDegrees = .greatestFiniteMagnitude
        reopened.scene = invalid; reopened.saveNow()
        check(try CanvasLocalFile.read(sceneURL) == lastValidBytes,"invalid 저장은 마지막 정상 파일 보존")
        // 손상된 원본은 restore 실패 뒤에도 자동 저장으로 교체하지 않는다.
        let corruptBytes = Data(String(decoding:savedBytes,as:UTF8.self).replacingOccurrences(of:"\"rotationDegrees\":90",with:"\"rotationDegrees\":1e308").utf8)
        try CanvasLocalFile.write(corruptBytes,to:sceneURL)
        let corrupt = CanvasStore(blockRecoveryURL:output.appendingPathComponent("corrupt.json"))
        check(!corrupt.sceneRecoveryNotice.isEmpty,"invalid 회전 복원 실패 표시")
        corrupt.saveNow()
        check(try CanvasLocalFile.read(sceneURL) == corruptBytes,"invalid 원본 JSON 자동 덮어쓰기 금지")
        try savedBytes.write(to:output.appendingPathComponent("rotated-scene.json"))
        print("NODE_ROTATION_CHECKS assertions=\(count) deviceExecuted=false realVaultTouched=false")
    }
}
