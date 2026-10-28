import Foundation
import PencilKit

@main struct MathSchema3Probe {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let points = [CGPoint(x:20,y:20),CGPoint(x:40,y:50)].enumerated().map { i,p in
            PKStrokePoint(location:p,timeOffset:Double(i)/10,size:CGSize(width:3,height:3),opacity:1,force:0.5,azimuth:0,altitude:1)
        }
        let stroke = PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1)))
        let store = CanvasStore()
        precondition(store.updateDrawing(PKDrawing(strokes:[stroke])))
        var source = store.scene; source.schemaVersion = 3
        store.scene = source; store.mode = .lasso; store.setInkSelection([stroke.id])
        await store.proposeInkMath { _ in "1+1=" }
        precondition(store.inkMathProposal?.source.schemaVersion == 3)
        precondition(store.confirmInkMath() && store.scene.schemaVersion == 3)
        print("PASS schema3 confirm preserves version")
        precondition(store.scene.drawingBase64 == source.drawingBase64 && store.scene.strokes == source.strokes)
        print("PASS schema3 native ink pressure source unchanged")
        store.undoGraphEdit(); precondition(store.scene.schemaVersion == 3 && store.scene.nodes.isEmpty)
        print("PASS schema3 undo preserves version")
        store.redoGraphEdit(); precondition(store.scene.schemaVersion == 3 && store.scene.nodes.count == 1)
        print("PASS schema3 redo preserves version")
        store.saveNow()
        let reopened = CanvasStore()
        precondition(reopened.scene == store.scene && reopened.scene.schemaVersion == 3)
        print("PASS schema3 saved JSON fresh Store reopen")
        var unsupported = source; unsupported.schemaVersion = 4
        do {
            _ = try CanvasInkMathProposal.capture(scene:unsupported,drawing:store.drawing,selection:[stroke.id],recognized:"1+1")
            preconditionFailure("unsupported schema4 accepted")
        } catch CanvasPenSettingsError.unsupportedInkProjection {
            precondition(unsupported.schemaVersion == 4)
            print("PASS unsupported future schema rejected without downgrade")
        }
        print("MATH_SCHEMA3_COMPATIBILITY_PROBE_OK 6 simulated consumer schema support only")
    }
}
