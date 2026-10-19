import Foundation
import PencilKit
#if canImport(UIKit)
import UIKit
#endif

@main struct HierarchyFoldChecks {
    @MainActor static func main() async throws {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        precondition(support.path.hasPrefix(home + "/"), "Never use live application support")
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
            print("PASS \(message)")
        }
        func node(_ i: Int) -> CanvasNode {
            CanvasNode(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!,
                kind: .note, frame: CanvasRect(x: Double(i * 60), y: 30, width: 40, height: 40),
                text: "요소 \(i)", confidence: .confirmed, sourceStrokeIds: [])
        }
        func link(_ i: Int, _ from: CanvasNode, _ to: CanvasNode,
                  _ kind: CanvasLink.Kind? = .parentChild) -> CanvasLink {
            CanvasLink(id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", i))!,
                from: from.id, to: to.id, label: "보존할 관계", kind: kind)
        }
        let a = node(1), b = node(2), c = node(3), d = node(4), e = node(5)
        var base = CanvasScene()
        base.width = 400
        base.height = 180
        base.nodes = [a,b,c,d,e]
        base.links = [link(1,a,b), link(2,b,c), link(3,a,d),
                      link(4,a,e,.general), link(5,c,e,nil), link(6,e,a,.general)]
        base.annotations = [CanvasAnnotation(id: UUID(), nodeId: c.id, text: "숨길 주석", author: "agent"),
                            CanvasAnnotation(id: UUID(), nodeId: e.id, text: "남길 주석", author: "agent"),
                            CanvasAnnotation(id: UUID(), nodeId: nil, text: "장면 주석", author: "agent")]
        let stroke = InkStroke(id: UUID(), points: [InkPoint(x: 10,y: 170,pressure: 1),
                                                  InkPoint(x: 45,y: 170,pressure: 1)],
                               createdAt: Date(timeIntervalSince1970: 10))
        base.strokes = [stroke]
        base.nodes[2].sourceStrokeIds = [stroke.id]
        base.nodes[2].vaultNote = VaultNoteReference(path: "노트/원문.md", sha256: "source",
            relayAddress: "http://127.0.0.1:9999", blockID: "block", sourceState: .changed)
        base.drawingBase64 = PKDrawing().dataRepresentation().base64EncodedString()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalBytes = try encoder.encode(base)
        let decoded = try JSONDecoder().decode(CanvasScene.self, from: originalBytes)
        check(decoded == base && decoded.nodes.allSatisfy { $0.isCollapsed == nil }, "old scene without collapse flag decodes unchanged")
        var wire = try JSONSerialization.jsonObject(with: encoder.encode(a)) as! [String: Any]
        check(wire["isCollapsed"] == nil, "legacy node omits optional collapse flag")
        wire["isCollapsed"] = NSNull()
        let nullNode = try JSONDecoder().decode(CanvasNode.self, from: JSONSerialization.data(withJSONObject: wire))
        check(nullNode.isCollapsed == nil, "null collapse flag decodes as expanded")
        wire["isCollapsed"] = "true"
        check((try? JSONDecoder().decode(CanvasNode.self, from: JSONSerialization.data(withJSONObject: wire))) == nil,
              "malformed collapse flag is rejected")
        check(base.visibility.nodeIDs == Set(base.nodes.map(\.id)), "all legacy nodes start visible")
        check(!base.toggleChildren(of: e.id), "ordinary links do not make a parent")
        check(!base.toggleChildren(of: UUID()), "missing parent cannot mutate scene")
        check(try encoder.encode(base) == originalBytes, "rejected toggles preserve every byte")

        var folded = base
        check(folded.toggleChildren(of: b.id), "nested parent folds")
        check(folded.visibility.nodeIDs == [a.id,b.id,d.id,e.id], "inner fold hides only its descendants")
        check(folded.toggleChildren(of: a.id), "outer parent folds")
        check(folded.visibility.nodeIDs == [a.id,e.id], "outer fold hides nested parent and siblings")
        check(folded.visibility.linkIDs == [base.links[3].id,base.links[5].id], "both endpoints must be visible for every link kind")
        check(folded.visibility.annotationIDs == [base.annotations[1].id], "descendant and unpositioned annotations are absent from rendered projection")
        check(folded.strokes == base.strokes && folded.drawingBase64 == base.drawingBase64 &&
              folded.links == base.links && folded.annotations == base.annotations, "fold never deletes ink, relations or annotations")
        var expectedNodes = base.nodes
        expectedNodes[0].isCollapsed = true
        expectedNodes[1].isCollapsed = true
        check(folded.nodes == expectedNodes && folded.revision == base.revision + 2, "only parent flags and revision change; descendants retain text and source")
        check(try JSONDecoder().decode(CanvasScene.self, from: encoder.encode(folded)) == folded,
              "collapsed JSON retains all data and flags without another storage channel")
        let packet = try CanvasPacket(scene: folded, imagePNG: Data([137,80,78,71,13,10,26,10]),
            session: VoiceSession(threadId: UUID(),sessionId: "test",observedAt: ""))
        check(try packet.frozenScene() == folded, "agent packet contains complete folded scene")
        check(folded.toggleChildren(of: a.id) && folded.visibility.nodeIDs == [a.id,b.id,d.id,e.id],
              "unfolding ancestor restores child's own folded state")
        check(folded.nodes[1].isCollapsed == true, "inner collapse flag is preserved")
        check(folded.toggleChildren(of: b.id) && folded.visibility == base.visibility, "unfolding child restores all original visible items")
        var orphanFold = base
        orphanFold.nodes[4].isCollapsed = true
        check(orphanFold.toggleChildren(of: e.id) && orphanFold.nodes[4].isCollapsed == false,
              "folded parent can unfold after its final child link is removed")

        var broken = base
        broken.links = [link(1,a,b),link(2,b,c),link(3,c,a),link(4,d,c),link(5,a,a),link(6,a,node(99))]
        broken.nodes[0].isCollapsed = true
        let repairedVisibility = broken.visibility
        check(repairedVisibility.nodeIDs == [a.id,d.id,e.id], "legacy cycle, second parent, self and dangling edges remain bounded")
        broken.links.reverse()
        broken.nodes.reverse()
        check(broken.visibility == repairedVisibility, "legacy visibility is deterministic regardless of input array order")
        broken.nodes = broken.nodes.map { var n = $0; n.isCollapsed = true; return n }
        check(broken.visibility.nodeIDs.contains(a.id), "even fully collapsed legacy cycle leaves an unfoldable root visible")
        var deep = CanvasScene()
        deep.nodes = (1...900).map(node)
        deep.links = (0..<899).map { link($0,deep.nodes[$0],deep.nodes[$0 + 1]) }
        deep.nodes[0].isCollapsed = true
        check(deep.visibility.nodeIDs == [deep.nodes[0].id], "deep hierarchy folds iteratively without recursive stack growth")

        let store = CanvasStore()
        store.scene = base
        store.select(a.id)
        store.beginChildLink()
        store.toggleSelectedChildren()
        check(store.selectedNode == a.id && store.linkStart == nil && store.scene.nodes[0].isCollapsed == true,
              "store keeps folded parent selected and cancels pending child link")
        let afterFold = store.scene
        store.select(c.id)
        check(store.selectedNode == a.id && store.scene == afterFold, "hidden target cannot be selected or connected")
        store.selectedNode = c.id
        check(store.selectedNode == nil, "direct hidden selection is normalized")
        store.beginLink()
        check(store.linkStart == nil, "hidden node cannot begin a link")
        store.moveSelected(to: CGPoint(x: 1000,y: 1000))
        check(store.scene == afterFold, "hidden selection cannot move its node")
        store.select(e.id)
        store.beginLink()
        store.select(c.id)
        check(store.linkStart == nil && store.selectedNode == e.id && store.scene == afterFold,
              "hidden second endpoint safely cancels pending general link")
        store.scene = base
        store.select(c.id)
        store.beginChildLink()
        store.proposedNode = c.id
        var remote = base
        _ = remote.toggleChildren(of: a.id)
        store.scene = remote
        check(store.selectedNode == nil && store.linkStart == nil && store.proposedNode == nil,
              "remote fold clears hidden selection, link start and open proposal")
        store.saveNow()
        let saved = try JSONDecoder().decode(CanvasScene.self,
            from: Data(contentsOf: support.appendingPathComponent("CanvasScene.json")))
        check(saved == remote && CanvasStore().scene == remote, "existing isolated autosave and restore retain collapsed scene losslessly")
        try store.importScene(remote)
        check(store.scene == remote && store.selectedNode == nil, "existing import retains flags and all descendants")
        var hiddenAgent = remote
        check(hiddenAgent.apply(AgentRevision(sceneId: remote.id,baseRevision: remote.revision,
            annotations: [CanvasAnnotation(id: UUID(),nodeId: c.id,text: "숨긴 뒤 추가",author: "agent")],proposedNodes: [])),
              "agent can still address retained hidden data")
        check(hiddenAgent.visibility.annotationIDs == remote.visibility.annotationIDs, "new hidden-node annotation stays absent from rendered projection")
#if canImport(UIKit)
        var rendered = remote
        rendered.drawingBase64 = ""
        rendered.strokes = []
        let png = await SceneRenderer.png(scene: rendered)
        var pruned = rendered
        let visible = rendered.visibility
        pruned.nodes.removeAll { !visible.nodeIDs.contains($0.id) }
        pruned.links.removeAll { !visible.linkIDs.contains($0.id) }
        pruned.annotations.removeAll { !visible.annotationIDs.contains($0.id) }
        let prunedPNG = await SceneRenderer.png(scene: pruned)
        check(png != nil && png == prunedPNG,
              "actual PNG of fold equals visible-only geometry including links and annotations")
        _ = rendered.toggleChildren(of: a.id)
        check(png != (await SceneRenderer.png(scene: rendered)), "actual PNG restores descendants after unfold")
        var withInk = remote
        withInk.drawingBase64 = ""
        let foldedInk = await SceneRenderer.png(scene: withInk)
        _ = withInk.toggleChildren(of: a.id)
        let unfoldedInk = await SceneRenderer.png(scene: withInk)
        check(foldedInk != nil && foldedInk != unfoldedInk,
              "legacy ink remains renderable across hierarchy folds")
        withInk = remote
        withInk.drawingBase64 = ""
        withInk.strokes = []
        let inkless = await SceneRenderer.png(scene: withInk)
        check(foldedInk != inkless, "folded PNG still includes original legacy ink")
        let controls = [10.0,45.0].map { x in
            PKStrokePoint(location: CGPoint(x:x,y:170),timeOffset:x / 100,
                size:CGSize(width:5,height:5),opacity:1,force:1,azimuth:0,altitude:1)
        }
        let drawing = PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.white),
            path:PKStrokePath(controlPoints:controls,creationDate:Date(timeIntervalSince1970:10)))])
        var native = remote
        native.drawingBase64 = drawing.dataRepresentation().base64EncodedString()
        let nativePNG = await SceneRenderer.png(scene:native)
        pruned.drawingBase64 = native.drawingBase64
        let prunedNativePNG = await SceneRenderer.png(scene:pruned)
        check(nativePNG != nil && nativePNG == prunedNativePNG && nativePNG != inkless,
              "actual native PencilKit PNG preserves source ink while hiding descendants")
        print("PNG_RUNTIME=actual SceneRenderer UIKit")
#else
        print("PNG_RUNTIME=unavailable on native macOS; same tests require UIKit runtime")
#endif
        print("HIERARCHY_FOLD_CHECKS assertions=\(checks) deviceExecuted=false")
    }
}
