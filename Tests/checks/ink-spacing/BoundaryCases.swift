import Foundation
import PencilKit

@main struct SpacingBoundaryChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let baseline = CommandLine.arguments.contains("--baseline")
        func stroke(_ x: CGFloat) -> PKStroke {
            let points = [CGPoint(x:x,y:20),CGPoint(x:x,y:50)].enumerated().map { i,p in
                PKStrokePoint(location:p,timeOffset:Double(i)/10,size:CGSize(width:3,height:3),opacity:0.8,force:0.5,azimuth:0.2,altitude:1)
            }
            return PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))
        }
        let left = stroke(10), right = stroke(80), other = stroke(200)
        let drawing = PKDrawing(strokes:[left,right,other])
        var scene = CanvasScene();scene.schemaVersion = 3
        scene.drawingBase64 = drawing.dataRepresentation().base64EncodedString()
        scene.strokes = CanvasScene.nativeInkStrokes(try PKDrawing(data:Data(base64Encoded:scene.drawingBase64)!))
        scene.nodes = [.init(id:UUID(),kind:.note,frame:.init(x:10,y:100,width:260,height:120),text:"가나",confidence:.confirmed,sourceStrokeIds:[left.id,right.id])]
        let selection: Set<UUID> = [left.id,right.id]
        func propose(_ source: CanvasScene,_ amount: Double) async -> (CanvasInkSpacingProposal,Int) {
            let editing = CanvasInkSpacingProposal();var calls = 0
            await editing.propose(scene:source,nodeID:source.nodes[0].id,selection:selection,left:"가",right:"나",action:.split,amount:amount,
                isCurrent:{ $0.matches(scene:source,selection:selection) },readEvidence:{ _,_,target,_ in
                    calls += 1;let first = target == "가"
                    return .init(wholeText:"가나",matches:[first ? [left.id] : [right.id]],targetText:target,
                        remainingText:first ? "나" : "가",otherCharacterMatches:[[first ? [right.id] : [left.id]]])
                })
            return (editing,calls)
        }
        let originalBytes = try CanvasInkTextEditing.encode(scene)
        if baseline {
            var future = scene;future.schemaVersion = 99
            let before = try CanvasInkTextEditing.encode(future)
            let (editing,calls) = await propose(future,20)
            guard case .refused(let reason) = editing.phase else { preconditionFailure("schema 99 reached preview") }
            precondition(calls == 0 && editing.proposal == nil)
            let unchanged = try CanvasInkTextEditing.encode(future)
            precondition(unchanged == before)
            print("BASELINE schema99 refused before native evidence; original unchanged: \(reason)")
        }
        let (fractional,calls) = await propose(scene,1.1)
        guard case .refused(let reason) = fractional.phase else { preconditionFailure("unexpected fractional preview") }
        precondition(fractional.proposal == nil)
        if baseline {
            precondition(calls == 2 && reason == CanvasInkSpacingProposal.Refusal.identity.localizedDescription)
            var moved = right;moved.transform = moved.transform.concatenating(CGAffineTransform(translationX:1.1,y:0))
            let normalized = try PKDrawing(data:PKDrawing(strokes:[moved]).dataRepresentation()).strokes[0]
            precondition(normalized.id == right.id && normalized.transform != moved.transform)
            print("BASELINE amount1.1 identity refusal; requested tx=\(moved.transform.tx), serialized tx=\(normalized.transform.tx)")
        } else {
            precondition(calls == 0 && reason == CanvasInkSpacingProposal.Refusal.amount.localizedDescription && reason.contains("정수"))
            print("PASS amount1.1 explicitly refused as integer-only before native evidence")
            let (integer,integerCalls) = await propose(scene,20)
            guard let p = integer.proposal else { preconditionFailure("integer preview missing") }
            precondition(integerCalls == 2 && p.delta == 20 && p.before == scene && p.after.schemaVersion == 3)
            precondition(p.after.nodes[0].sourceStrokeIds == scene.nodes[0].sourceStrokeIds)
            precondition(p.after.strokes.map(\.id) == scene.strokes.map(\.id))
            for (before,after) in zip(scene.strokes,p.after.strokes) {
                if before.id == right.id {
                    precondition(zip(before.points,after.points).allSatisfy { $0.pressure == $1.pressure && $1.x == $0.x+20 && $1.y == $0.y })
                } else { precondition(before == after) }
            }
            print("PASS integer20 serialized movement; schema3/source IDs/pressure/other strokes unchanged")
        }
        let unchanged = try CanvasInkTextEditing.encode(scene)
        precondition(unchanged == originalBytes)
        print("PASS original scene/native bytes unchanged; recognition evidence is injected, not native recognition success")
    }
}
