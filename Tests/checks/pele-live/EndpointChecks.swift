import Foundation
import PencilKit

@main struct EndpointChecks {
    @MainActor static func main() async throws {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/"))
        let output = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PELE_OUTPUT"]!)
        let fixture = URL(fileURLWithPath:home).appendingPathComponent("endpoint-fixtures")
        try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition,message)
            count += 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        func bytes(_ value: CanvasScene) throws -> Data { try encoder.encode(value) }
        func sameBytes(_ value: CanvasScene, _ expected: Data) -> Bool { (try? bytes(value)) == expected }
        func roundtrip<T: Codable>(_ value: T) throws -> T { try decoder.decode(T.self,from:encoder.encode(value)) }
        var base = CanvasScene()
        let a = base.addNode(kind:.box,at:.init(x:100,y:200),text:"출발 👩🏽‍💻 e\u{301}")
        let b = base.addNode(kind:.box,at:.init(x:600,y:200),text:"도착")
        check(base.connect(a,to:b,label:"기존 연결"),"기존 연결 생성")
        let original = base.links[0]
        var regressions: [(String,Bool)] = []
        let overlapping = CanvasStore(blockRecoveryURL:fixture.appendingPathComponent("p2-overlap.json"))
        overlapping.scene = base
        overlapping.mode = .select
        overlapping.selectLink(original.id)
        let firstOwner = UUID(), secondOwner = UUID()
        let first = overlapping.beginEndpointDrag(.from,linkID:original.id,owner:firstOwner)
        let second = overlapping.beginEndpointDrag(.to,linkID:original.id,owner:secondOwner)
        check(!overlapping.updateEndpointDrag(owner:secondOwner,to:.init(x:800,y:0)) &&
              !overlapping.finishEndpointDrag(owner:secondOwner) && !overlapping.cancelEndpointDrag(owner:secondOwner),
              "시작에 실패한 두 번째 포인터의 move·end·cancel·사라짐은 첫 드래그에 영향 없음")
        _ = overlapping.updateEndpointDrag(owner:firstOwner,to:.init(x:170,y:700))
        _ = overlapping.finishEndpointDrag(owner:firstOwner)
        regressions.append(("P2-1 시작점·끝점 시작 후 첫 포인터 이동·종료",first && !second &&
            overlapping.scene.links[0].fromAnchor != nil && overlapping.scene.links[0].toAnchor == nil))
        check(overlapping.beginEndpointDrag(.to,linkID:original.id,owner:secondOwner),"첫 드래그 종료 후 두 번째 포인터의 새 드래그 시작")
        check(!overlapping.updateEndpointDrag(owner:firstOwner,to:.init(x:0,y:0)) &&
              !overlapping.finishEndpointDrag(owner:firstOwner) && !overlapping.cancelEndpointDrag(owner:firstOwner) &&
              overlapping.endpointDrag?.owner == secondOwner,"오래된 첫 포인터 콜백은 새 드래그를 변경하거나 종료하지 않음")
        check(overlapping.cancelEndpointDrag(owner:secondOwner),"현재 소유자의 취소만 수락")
        overlapping.saveNow()
        var vendor = try JSONSerialization.jsonObject(with:encoder.encode(original)) as! [String:Any]
        vendor["fromAnchor"] = ["side":"top","offset":0.5,"vendorMeta":["v":1]]
        let vendorBytes = try JSONSerialization.data(withJSONObject:vendor)
        let decodedVendor = try? decoder.decode(CanvasLink.self,from:vendorBytes)
        let vendorPreserved = try decodedVendor.map {
            let encoded = try JSONSerialization.jsonObject(with:encoder.encode($0)) as! NSDictionary
            return encoded == (try JSONSerialization.jsonObject(with:vendorBytes) as! NSDictionary)
        } ?? true
        regressions.append(("P2-2 typed 메타데이터 보존 또는 읽기 거부",vendorPreserved))
        let sceneURL = try CanvasRuntime.stateURL(.scene)
        var corrupt = try JSONSerialization.jsonObject(with:encoder.encode(base)) as! [String:Any]
        var corruptLinks = corrupt["links"] as! [[String:Any]]
        corruptLinks[0]["fromAnchor"] = ["side":"future","offset":0.5]
        corrupt["links"] = corruptLinks
        let corruptBytes = try JSONSerialization.data(withJSONObject:corrupt)
        try CanvasLocalFile.write(corruptBytes,to:sceneURL)
        let failedRestore = CanvasStore(blockRecoveryURL:fixture.appendingPathComponent("p2-corrupt.json"))
        failedRestore.saveNow()
        regressions.append(("P2-3 복원 실패 후 원본 파일 바이트 보존",try CanvasLocalFile.read(sceneURL) == corruptBytes))
        for (name,passed) in regressions {
            FileHandle.standardOutput.write(Data("\(passed ? "PASS" : "FAIL") \(name)\n".utf8))
        }
        precondition(regressions.allSatisfy(\.1),"독립검수 P2 재현")
        try CanvasLocalFile.write(encoder.encode(base),to:sceneURL)
        let oldJSON = try encoder.encode(original)
        check(!String(decoding:oldJSON,as:UTF8.self).contains("Anchor"),"기존 JSON에 연결점 생략")
        check(try roundtrip(original) == original,"이전 JSON 하위호환")
        var wire = try JSONSerialization.jsonObject(with:oldJSON) as! [String:Any]
        wire["fromAnchor"] = NSNull()
        wire["toAnchor"] = NSNull()
        check(try decoder.decode(CanvasLink.self,from:JSONSerialization.data(withJSONObject:wire)) == original,
              "null 연결점은 자동 부착")

        for side in CanvasLinkAnchor.Side.allCases {
            for offset in [0.0,0.25,0.5,1.0] {
                let anchor = CanvasLinkAnchor(side:side,offset:offset)
                var link = original
                link.fromAnchor = anchor
                link.toAnchor = anchor
                check(try roundtrip(link) == link,"양쪽 연결점 JSON 왕복")
                let frame = CanvasRect(x:10,y:20,width:200,height:100)
                let point = anchor.point(in:frame)!
                let expected: CanvasPoint
                switch side {
                case .top: expected = .init(x:10 + 200 * offset,y:20)
                case .right: expected = .init(x:210,y:20 + 100 * offset)
                case .bottom: expected = .init(x:10 + 200 * offset,y:120)
                case .left: expected = .init(x:10,y:20 + 100 * offset)
                }
                check(point == expected,"네 변의 정규화 좌표 계산")
                check(CanvasLinkAnchor.nearest(to:point,in:frame)?.point(in:frame) == point,"경계 최근접 재투영")
            }
        }
        let frame = CanvasRect(x:100,y:200,width:200,height:100)
        let directions: [(CanvasPoint,CanvasPoint)] = [(.init(x:500,y:250),.init(x:300,y:250)),
            (.init(x:-100,y:250),.init(x:100,y:250)),(.init(x:200,y:0),.init(x:200,y:200)),
            (.init(x:200,y:500),.init(x:200,y:300)),(.init(x:400,y:350),.init(x:300,y:300)),
            (.init(x:200,y:250),.init(x:300,y:250))]
        for (target,expected) in directions {
            check(CanvasLinkAnchor.automatic(in:frame,toward:target) == expected,"자동 부착은 상대 중심 방향 경계")
        }
        check(CanvasLinkAnchor.nearest(to:.init(x:280,y:260),in:frame) == .init(side:.right,offset:0.6),
              "도형 내부에서도 가장 가까운 경계 선택")
        check(CanvasLinkAnchor.nearest(to:.init(x:450,y:100),in:frame)?.point(in:frame) == .init(x:300,y:200),
              "바깥쪽 드래그는 원래 노드의 모서리로 투영")
        check(base.linkEndpoints(original)?.from == .init(x:360,y:260) &&
              base.linkEndpoints(original)?.to == .init(x:600,y:260),"기본 선은 양쪽 경계에 연결")

        var anchored = base
        anchored.links[0].fromAnchor = .init(side:.bottom,offset:0.25)
        anchored.links[0].toAnchor = .init(side:.top,offset:0.75)
        let anchors = anchored.links
        let beforeMove = anchored.linkEndpoints(anchored.links[0])!
        anchored.moveNode(a,to:.init(x:150,y:270))
        let afterMove = anchored.linkEndpoints(anchored.links[0])!
        check(afterMove.from == .init(x:beforeMove.from.x + 50,y:beforeMove.from.y + 70),"노드 이동에 같은 연결점 추적")
        check(afterMove.to == beforeMove.to && anchored.links == anchors,"반대쪽 고정 연결점과 의미 유지")
        anchored.nodes[0].frame.width = 400
        anchored.nodes[0].frame.height = 300
        check(anchored.linkEndpoints(anchored.links[0])?.from == .init(x:250,y:570),"크기 변경 뒤 정규화 위치 유지")
        let autoBefore = base.linkEndpoints(original)!.to
        var moving = base
        moving.moveNode(a,to:.init(x:1100,y:200))
        check(moving.linkEndpoints(original)!.to != autoBefore,"자동 연결점은 상대 이동 방향에 따라 변 변경")

        var invalidFrames = [CanvasRect(x:0,y:0,width:0,height:10),.init(x:0,y:0,width:10,height:-1),
            .init(x:.nan,y:0,width:10,height:10),.init(x:0,y:.infinity,width:10,height:10),
            .init(x:0,y:0,width:.infinity,height:10),.init(x:0,y:0,width:10,height:.nan),
            .init(x:Double.greatestFiniteMagnitude,y:0,width:Double.greatestFiniteMagnitude,height:10)]
        invalidFrames.append(.init(x:0,y:0,width:-1,height:10))
        for invalid in invalidFrames {
            check(CanvasLinkAnchor(side:.top,offset:0.5).point(in:invalid) == nil,"잘못된 프레임 고정 연결 거부")
            check(CanvasLinkAnchor.nearest(to:.init(x:1,y:2),in:invalid) == nil,"잘못된 프레임 드래그 거부")
            var scene = base
            scene.nodes[0].frame = invalid
            check(scene.linkEndpoints(original) == nil,"잘못된 프레임 선 렌더링 거부")
            var replacement = original
            replacement.fromAnchor = .init(side:.right,offset:0.5)
            check(!scene.editGraph(nodeEdits:[],linkEdits:[.init(expected:original,replacement:replacement)]),
                  "잘못된 프레임에 연결점 수정 거부")
        }
        for offset in [-0.001,1.001,Double.nan,Double.infinity,-Double.infinity] {
            let invalid = CanvasLinkAnchor(side:.top,offset:offset)
            check(!invalid.isValid && invalid.point(in:frame) == nil,"범위 밖·NaN 연결점 거부")
            check((try? encoder.encode(invalid)) == nil,"유효하지 않은 연결점 직렬화 거부")
            for endpoint in CanvasLink.Endpoint.allCases {
                var replacement = original
                if endpoint == .from { replacement.fromAnchor = invalid }
                else { replacement.toAnchor = invalid }
                var scene = base
                let before = try bytes(scene)
                let edit = CanvasLinkEdit(expected:original,replacement:replacement)
                check(!scene.editGraph(nodeEdits:[.init(expected:base.nodes[0],text:"반영 금지")],linkEdits:[edit]) &&
                      sameBytes(scene,before),"수동 잘못된 연결점은 노드 수정까지 원자적 거부")
                let change = AgentRevision(sceneId:scene.id,baseRevision:scene.revision,annotations:[],proposedNodes:[],
                    nodeEdits:[.init(expected:base.nodes[0],text:"반영 금지")],linkEdits:[edit])
                check(!scene.apply(change) && sameBytes(scene,before),"AI 잘못된 연결점은 전체 장면 보존")
                var proposed = replacement
                proposed.id = UUID()
                check(!scene.apply(.init(sceneId:scene.id,baseRevision:scene.revision,annotations:[],
                    proposedNodes:[],proposedLinks:[proposed])) && sameBytes(scene,before),"AI 제안 선의 잘못된 연결점 거부")
            }
        }
        let badAnchors = ["{\"side\":\"top\",\"offset\":-0.1}","{\"side\":\"right\",\"offset\":1.1}",
            "{\"side\":\"future\",\"offset\":0.5}","{\"side\":\"left\",\"offset\":null}",
            "{\"side\":\"top\",\"offset\":\"NaN\"}"]
        for value in badAnchors {
            check((try? decoder.decode(CanvasLinkAnchor.self,from:Data(value.utf8))) == nil,"손상 연결점 JSON 거부")
        }
        for endpoint in ["fromAnchor","toAnchor"] {
            var linkWire = try JSONSerialization.jsonObject(with:oldJSON) as! [String:Any]
            linkWire[endpoint] = ["side":"top","offset":0.5,
                "vendorMeta":["v":1,"nested":["array":[true,NSNull(),["text":"e\u{301}"]]]]]
            let linkBytes = try JSONSerialization.data(withJSONObject:linkWire)
            check((try? decoder.decode(CanvasLink.self,from:linkBytes)) == nil,
                  "중첩된 알 수 없는 연결점 메타데이터를 조용히 버리지 않고 typed 링크 읽기 거부")
            var sceneWire = try JSONSerialization.jsonObject(with:encoder.encode(base)) as! [String:Any]
            sceneWire["links"] = [linkWire]
            check((try? decoder.decode(CanvasScene.self,from:JSONSerialization.data(withJSONObject:sceneWire))) == nil,
                  "typed 장면도 알 수 없는 앵커를 읽기 거부")
            let revision = AgentRevision(sceneId:base.id,baseRevision:base.revision,annotations:[],proposedNodes:[],
                linkEdits:[.init(expected:original,replacement:original)])
            for field in ["expected","replacement","proposedLinks"] {
                var revisionWire = try JSONSerialization.jsonObject(with:encoder.encode(revision)) as! [String:Any]
                if field == "proposedLinks" { revisionWire[field] = [linkWire] }
                else {
                    var edits = revisionWire["linkEdits"] as! [[String:Any]]
                    edits[0][field] = linkWire
                    revisionWire["linkEdits"] = edits
                }
                let before = try bytes(base)
                check((try? decoder.decode(AgentRevision.self,from:JSONSerialization.data(withJSONObject:revisionWire))) == nil &&
                      sameBytes(base,before),"AI 기대·대체·제안의 알 수 없는 앵커를 CAS 전에 거부")
            }
        }
        for point in [CanvasPoint(x:.nan,y:0),.init(x:0,y:.infinity)] {
            check(CanvasLinkAnchor.nearest(to:point,in:frame) == nil,"비유한 드래그 좌표 거부")
        }

        var replacement = original
        replacement.fromAnchor = .init(side:.left,offset:0.3)
        replacement.toAnchor = .init(side:.bottom,offset:0.8)
        let edit = CanvasLinkEdit(expected:original,replacement:replacement)
        let change = AgentRevision(sceneId:base.id,baseRevision:base.revision,annotations:[],proposedNodes:[],
            nodeEdits:[.init(expected:base.nodes[0],text:"AI 원자적 편집")],linkEdits:[edit])
        var applied = base
        check(applied.apply(try roundtrip(change)),"AI 텍스트와 두 연결점을 함께 반영")
        let afterAI = try bytes(applied)
        check(applied.apply(change) && sameBytes(applied,afterAI),"AI 재수신은 revision까지 멱등")
        var staleExpected = original
        staleExpected.fromAnchor = .init(side:.top,offset:0.5)
        check(!applied.editGraph(nodeEdits:[],linkEdits:[.init(expected:staleExpected,replacement:replacement)]) &&
              sameBytes(applied,afterAI),"기대 연결점이 다르면 오래된 수동 수정 거부")
        var staleChange = change
        staleChange.baseRevision = applied.revision
        check(!applied.apply(staleChange) && sameBytes(applied,afterAI),"최신 revision으로 위장한 오래된 기대 상태 거부")
        applied.links[0].toAnchor = .init(side:.right,offset:0.8)
        let changed = try bytes(applied)
        check(!applied.apply(change) && sameBytes(applied,changed),"연결점이 달라진 뒤 AI 재수신 거부")
        var replayWithInvalidExpected = change
        replayWithInvalidExpected.linkEdits![0].expected.toAnchor = .init(side:.left,offset:.nan)
        var replay = base
        check(replay.apply(change),"재수신 검사 준비")
        let replayBefore = try bytes(replay)
        check(!replay.apply(replayWithInvalidExpected) && sameBytes(replay,replayBefore),"재수신도 잘못된 expected 연결점을 거부")
        var proposal = base.nodes[1]
        proposal.id = UUID()
        proposal.confidence = .proposal
        let proposedLink = CanvasLink(id:UUID(),from:a,to:proposal.id,label:"새 제안",kind:.parentChild,
            fromAnchor:.init(side:.right,offset:0.2),toAnchor:.init(side:.left,offset:0.7))
        var proposedScene = base
        let proposedChange = AgentRevision(sceneId:base.id,baseRevision:base.revision,annotations:[],
            proposedNodes:[proposal],proposedLinks:[proposedLink])
        check(proposedScene.apply(proposedChange) && proposedScene.links.last == proposedLink,"AI 새 노드와 연결점을 원자적 제안")
        let proposedBefore = try bytes(proposedScene)
        check(proposedScene.apply(proposedChange) && sameBytes(proposedScene,proposedBefore),"AI 연결점 제안 재수신 멱등")
        let diagramBefore = try CanvasDiagramSnapshot(scene:base)
        var diagramScene = base
        diagramScene.links[0] = replacement
        let diagramAfter = try CanvasDiagramSnapshot(scene:diagramScene)
        check(diagramAfter.source == diagramBefore.source && diagramAfter.nodes == diagramBefore.nodes,
              "연결점 편집은 Mermaid 연결 의미와 노드 UUID를 바꾸지 않음")

        let store = CanvasStore(blockRecoveryURL:fixture.appendingPathComponent("endpoint-recovery.json"))
        store.scene = base
        let drawing = PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.white),path:PKStrokePath(controlPoints:[
            PKStrokePoint(location:CGPoint(x:15,y:20),timeOffset:0,size:CGSize(width:3,height:3),
                opacity:1,force:0.7,azimuth:0,altitude:1)],creationDate:Date(timeIntervalSince1970:10)))])
        store.updateDrawing(drawing)
        store.scene.nodes[0].sourceStrokeIds = store.scene.strokes.map(\.id)
        store.scene.nodes[1].vaultNote = VaultNoteReference(path:"노트/원본.md",sha256:String(repeating:"a",count:64),
            relayAddress:"http://127.0.0.1:8791",blockID:"original",sourceState:.current)
        let raw = store.scene.drawingBase64
        let strokes = store.scene.strokes
        let nodes = store.scene.nodes
        let linkID = original.id
        let dragOwner = UUID()
        for mode in [CanvasMode.pen,.eraser,.lasso] {
            store.mode = mode
            store.selectLink(linkID)
            check(store.selectedLink == nil && !store.beginEndpointDrag(.from,linkID:linkID,owner:dragOwner),"그리기·지우기·영역선택 모드에서는 선 편집 차단")
        }
        store.mode = .select
        store.selectLink(linkID)
        check(store.selectedLink == linkID && store.selectedNode == nil,"선 선택은 노드 선택과 분리")
        let beforeDrag = store.scene
        check(store.beginEndpointDrag(.from,linkID:linkID,owner:dragOwner),"시작점 드래그 시작")
        check(store.updateEndpointDrag(owner:dragOwner,to:.init(x:170,y:700)),"시작점은 원래 노드 경계로 투영")
        check(store.scene == beforeDrag && store.displayedLink(original).fromAnchor != nil,"드래그 미리보기는 scene revision과 분리")
        store.saveNow()
        let whileDragging = CanvasStore(blockRecoveryURL:fixture.appendingPathComponent("endpoint-recovery.json"))
        check(whileDragging.scene == beforeDrag,"드래그 중 자동 저장은 미확정 연결점을 기록하지 않음")
        check(store.finishEndpointDrag(owner:dragOwner) && store.scene.revision == beforeDrag.revision + 1,"드래그 종료는 한 revision으로 확정")
        check(store.scene.nodes == nodes && store.scene.strokes == strokes && store.scene.drawingBase64 == raw,
              "원본 획·노트·출처·텍스트를 보존")
        check(store.scene.links[0].from == a && store.scene.links[0].to == b &&
              store.scene.links[0].id == linkID && store.scene.links[0].label == original.label,"연결 의미와 안정 ID 보존")
        let afterFrom = store.scene
        check(store.beginEndpointDrag(.to,linkID:linkID,owner:dragOwner) && store.updateEndpointDrag(owner:dragOwner,to:.init(x:900,y:200)),"끝점 별도 드래그")
        check(store.finishEndpointDrag(owner:dragOwner) && store.scene.links[0].toAnchor != nil,"끝점 연결 위치 확정")
        let afterBoth = store.scene
        store.saveNow()
        let reopened = CanvasStore(blockRecoveryURL:fixture.appendingPathComponent("endpoint-recovery.json"))
        check(reopened.scene == afterBoth && reopened.endpointDrag == nil && reopened.selectedLink == nil,
              "새 Store 재열기는 양쪽 연결점과 원본을 복원하고 선택은 저장하지 않음")
        let packet = try CanvasPacket(scene:afterBoth,imagePNG:Data([137,80,78,71,13,10,26,10]),
            session:.init(threadId:UUID(),sessionId:"test",observedAt:""))
        check(try packet.frozenScene() == afterBoth,"패킷 typed scene 왕복 보존")
        try bytes(afterBoth).write(to:output.appendingPathComponent("endpoint-scene.json"))
        store.updateDrawing(PKDrawing(strokes:drawing.strokes + drawing.strokes))
        let latestRaw = store.scene.drawingBase64
        let latestStrokes = store.scene.strokes
        check(store.canUndoGraph,"새 획 뒤에도 graph Undo 가능")
        store.undoGraphEdit()
        check(store.scene.links == afterFrom.links && store.scene.strokes == latestStrokes &&
              store.scene.drawingBase64 == latestRaw && store.canRedoGraph,"Undo는 마지막 연결점만 되돌리고 최신 획 보존")
        store.redoGraphEdit()
        check(store.scene.links == afterBoth.links && store.scene.strokes == latestStrokes &&
              store.scene.drawingBase64 == latestRaw && store.canUndoGraph && !store.canRedoGraph,"Redo는 최신 획과 함께 연결점 복원")
        store.undoGraphEdit()
        store.scene.nodes[0].text = "외부 구조 변경"
        let beforeRedo = try bytes(store.scene)
        check(!store.canRedoGraph,"다른 구조 변경 뒤 Redo 차단")
        store.redoGraphEdit()
        check(try bytes(store.scene) == beforeRedo,"오래된 Redo는 장면을 덮지 않음")

        store.scene = afterBoth
        store.selectLink(linkID)
        check(store.beginEndpointDrag(.from,linkID:linkID,owner:dragOwner) && store.updateEndpointDrag(owner:dragOwner,to:.init(x:0,y:250)),"stale 검사 드래그 시작")
        store.scene.nodes[0].text = "외부의 새 입력"
        let external = try bytes(store.scene)
        check(!store.updateEndpointDrag(owner:dragOwner,to:.init(x:100,y:220)) && !store.finishEndpointDrag(owner:dragOwner) &&
              sameBytes(store.scene,external),"드래그 중 같은 revision의 외부 변경도 generation으로 거부")
        check(store.beginEndpointDrag(.to,linkID:linkID,owner:dragOwner),"새 드래그는 최신 장면으로 시작")
        var aiLink = store.scene.links[0]
        aiLink.toAnchor = .init(side:.left,offset:0.1)
        let incoming = AgentRevision(sceneId:store.scene.id,baseRevision:store.scene.revision,annotations:[],proposedNodes:[],
            linkEdits:[.init(expected:store.scene.links[0],replacement:aiLink)])
        check(store.applyAgentRevision(incoming),"드래그 중 들어오는 정상 AI 변경")
        let afterIncoming = try bytes(store.scene)
        check(!store.finishEndpointDrag(owner:dragOwner) && sameBytes(store.scene,afterIncoming),"AI 변경을 오래된 드래그로 덮지 않음")
        check(store.beginEndpointDrag(.to,linkID:linkID,owner:dragOwner),"취소 검사 시작")
        store.cancelEndpointDrag(owner:dragOwner)
        check(!store.finishEndpointDrag(owner:dragOwner) && sameBytes(store.scene,afterIncoming),"취소는 장면을 보존")
        check(store.beginEndpointDrag(.to,linkID:linkID,owner:dragOwner) && store.updateEndpointDrag(owner:dragOwner,to:.init(x:600,y:220)),"비유한 좌표 거부 검사 시작")
        check(!store.updateEndpointDrag(owner:dragOwner,to:.init(x:.nan,y:0)) && !store.finishEndpointDrag(owner:dragOwner) &&
              sameBytes(store.scene,afterIncoming),"잘못된 좌표 뒤 이전 미리보기를 확정하지 않음")
        check(store.beginEndpointDrag(.to,linkID:linkID,owner:dragOwner),"모드 변경 검사 시작")
        store.mode = .pen
        check(store.endpointDrag == nil && store.selectedLink == nil && !store.finishEndpointDrag(owner:dragOwner),"도구 변경은 임시 편집 취소")
        store.mode = .select
        store.selectLink(linkID)
        check(store.beginEndpointDrag(.to,linkID:linkID,owner:dragOwner),"노드 선택 검사 시작")
        store.select(a)
        check(store.endpointDrag == nil && store.selectedLink == nil,"노드 선택은 선 편집 취소")
        store.selectLink(linkID)
        check(store.beginEndpointDrag(.from,linkID:linkID,owner:dragOwner),"장면 전환 검사 시작")
        var other = store.scene
        other.id = UUID()
        try store.importScene(other)
        check(store.endpointDrag == nil && store.selectedLink == nil && !store.finishEndpointDrag(owner:dragOwner),"장면 교체 뒤 오래된 드래그 거부")
        store.saveNow()
        let finalReopen = CanvasStore(blockRecoveryURL:fixture.appendingPathComponent("endpoint-recovery.json"))
        check(finalReopen.scene == store.scene,"Undo·Redo·외부 변경 이후 저장 재열기 동등")
        finalReopen.saveNow()
        try await Task.sleep(for:.milliseconds(350))

        var failedFiles = try badAnchors.map { value -> Data in
            var valueScene = try JSONSerialization.jsonObject(with:encoder.encode(base)) as! [String:Any]
            var links = valueScene["links"] as! [[String:Any]]
            links[0]["fromAnchor"] = try JSONSerialization.jsonObject(with:Data(value.utf8))
            valueScene["links"] = links
            return try JSONSerialization.data(withJSONObject:valueScene)
        }
        var vendorScene = try JSONSerialization.jsonObject(with:encoder.encode(base)) as! [String:Any]
        vendorScene["links"] = [vendor]
        failedFiles.append(try JSONSerialization.data(withJSONObject:vendorScene))
        failedFiles.append(Data("{ 잘린 JSON 원본".utf8))
        var futureScene = base
        futureScene.schemaVersion = 2
        failedFiles.append(try encoder.encode(futureScene))
        var corruptDrawing = base
        corruptDrawing.drawingBase64 = "잘못된 base64 원본!"
        failedFiles.append(try encoder.encode(corruptDrawing))
        failedFiles.append(Data(repeating:32,count:4 * 1024 * 1024 + 1))
        for (index,originalBytes) in failedFiles.enumerated() {
            try CanvasLocalFile.write(originalBytes,to:sceneURL)
            let failed = CanvasStore(blockRecoveryURL:fixture.appendingPathComponent("failed-scene-\(index).json"))
            check(!failed.sceneRecoveryNotice.isEmpty && failed.status == failed.sceneRecoveryNotice,
                  "복원 실패를 파일 없음과 구분하고 한국어로 원본 보호 안내")
            failed.scene = base
            failed.saveNow()
            try await Task.sleep(for:.milliseconds(300))
            check(try CanvasLocalFile.read(sceneURL) == originalBytes,
                  "손상·미래 앵커·알 수 없는 필드·장면·획·크기 오류 뒤 명시 저장과 예약 자동 저장이 원본 바이트 보존")
            try failed.importScene(base)
            failed.saveNow()
            check(try !failed.sceneRecoveryNotice.isEmpty && CanvasLocalFile.read(sceneURL) == originalBytes,
                  "장면 가져오기만으로 읽지 못한 원본의 저장 차단을 자동 해제하지 않음")
            FileHandle.standardOutput.write(Data("FILE_PRESERVATION case=\(index) bytes=\(originalBytes.count) exact=true\n".utf8))
        }

        let validBytes = try encoder.encode(base)
        try CanvasLocalFile.write(validBytes,to:sceneURL)
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:sceneURL.path)
        check((try? CanvasLocalFile.read(sceneURL)) == nil,"읽기 권한 오류를 실제 파일에서 재현")
        let unreadable = CanvasStore(blockRecoveryURL:fixture.appendingPathComponent("unreadable-scene.json"))
        unreadable.scene = CanvasScene()
        unreadable.saveNow()
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:sceneURL.path)
        check(try !unreadable.sceneRecoveryNotice.isEmpty && CanvasLocalFile.read(sceneURL) == validBytes,
              "실제 read 실패 후 교체 가능한 파일도 원본 바이트 보존")

        try CanvasLocalFile.write(failedFiles[0],to:sceneURL)
        let checkpoint = CanvasStore(blockRecoveryURL:fixture.appendingPathComponent("blocked-checkpoint.json"))
        checkpoint.scene = base
        checkpoint.setNoteConnection(address:"http://test",token:"fixture-token")
        let noteText = "# 원본\n\n보존할 문단 ^p2\n"
        let note = VaultNoteSnapshot(path:"Notes/p2.md",text:noteText,
            sha256:CanvasPacket.sha(Data(noteText.utf8)),modifiedAt:"fixture")
        checkpoint.scene.nodes[0].vaultNote = .init(path:note.path,sha256:note.sha256,
            relayAddress:"http://test",blockID:"p2",sourceState:.current)
        await checkpoint.openVaultNote(note.path,nodeID:a) { _ in note }
        check(checkpoint.vaultCanAttach && checkpoint.vaultLinkedBlockID == "p2","격리 closure로 문단 checkpoint 진입 조건 충족")
        check(!checkpoint.beginLinkedBlockEdit() && checkpoint.vaultStatus.contains("기존 파일을 보존"),
              "문단 복구 checkpoint도 원본 보호 guard 사용")
        checkpoint.vaultBlockDraft = ""
        checkpoint.vaultDraft = "수정된 노트 초안"
        check(checkpoint.noteRecoveryWriteFailed && checkpoint.vaultDraft == "수정된 노트 초안" &&
              checkpoint.noteRecoveryNotice.contains("기존 파일을 보존"),"노트 복구 checkpoint도 원본 보호하며 입력은 유지")
        checkpoint.saveNow()
        check(try CanvasLocalFile.read(sceneURL) == failedFiles[0],"두 복구 checkpoint 이후 실제 원본 파일 바이트 보존")

        try CanvasLocalFile.write(validBytes,to:sceneURL)
        let repaired = CanvasStore(blockRecoveryURL:fixture.appendingPathComponent("repaired-scene.json"))
        check(repaired.sceneRecoveryNotice.isEmpty && repaired.scene == base,"원본을 정상 복구한 뒤 새 Store에서 저장 권한 회복")
        repaired.scene.nodes[0].text = "복구 후 정상 수정"
        repaired.saveNow()
        check(try decoder.decode(CanvasScene.self,from:CanvasLocalFile.read(sceneURL)) == repaired.scene,
              "정상 복구 후 수정과 저장 readback")
        let healthy = CanvasStore(blockRecoveryURL:fixture.appendingPathComponent("healthy-checkpoint.json"))
        healthy.setNoteConnection(address:"http://test",token:"fixture-token")
        healthy.scene.nodes[0].vaultNote = .init(path:note.path,sha256:note.sha256,
            relayAddress:"http://test",blockID:"p2",sourceState:.current)
        await healthy.openVaultNote(note.path,nodeID:a) { _ in note }
        check(healthy.beginLinkedBlockEdit(),"정상 장면에서는 기존 문단 복구 checkpoint 허용")
        check(try decoder.decode(CanvasScene.self,from:CanvasLocalFile.read(sceneURL)) == healthy.scene,
              "정상 문단 checkpoint의 장면 readback")
        check(healthy.closeVaultEditor(discard:true),"격리 문단 입력의 명시 종료")
        await healthy.openVaultNote(note.path,nodeID:a) { _ in note }
        healthy.vaultDraft = "정상 노트 수정"
        check(!healthy.noteRecoveryWriteFailed && healthy.noteRecovery?.draft == "정상 노트 수정",
              "정상 장면에서는 노트 복구 checkpoint 허용")
        healthy.saveNow()
        let heldBytes = try CanvasLocalFile.read(sceneURL)
        let held = sceneURL.deletingLastPathComponent().appendingPathComponent("scene-held.json")
        try FileManager.default.moveItem(at:sceneURL,to:held)
        let missing = CanvasStore(blockRecoveryURL:fixture.appendingPathComponent("missing-scene.json"))
        check(missing.sceneRecoveryNotice.isEmpty,"실제 파일 없음은 복원 실패로 표시하지 않음")
        missing.scene = base
        missing.saveNow()
        check(try decoder.decode(CanvasScene.self,from:CanvasLocalFile.read(sceneURL)) == base &&
              CanvasLocalFile.read(held) == heldBytes,"최초 저장을 허용하고 보관한 fixture도 유지")
        print("ENDPOINT_CHECKS assertions=\(count) deviceExecuted=false")
    }
}
