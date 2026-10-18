import SwiftUI
import PencilKit

extension SceneRenderer {
    @MainActor static func png(scene: CanvasScene, drawing: PKDrawing?) -> Data? {
        png(scene:scene)
    }
}

@main struct CanvasBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--native-ink-render-probe") {
                NativeInkProbeView()
            } else { CanvasWorkspace() }
        }
    }
}

struct NativeInkProbeView: View {
    @Environment(\.scenePhase) private var phase
    @State private var started = false
    @State private var result = "대기 중"

    private func ink(_ image: UIImage, at point: CGPoint, size: CGSize, transparent: Bool = false) -> Bool {
        guard let cg = image.cgImage else { return false }
        var pixels = [UInt8](repeating:0,count:cg.width * cg.height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data:bytes.baseAddress,width:cg.width,height:cg.height,
                bitsPerComponent:8,bytesPerRow:cg.width * 4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            if !transparent {
                context.setFillColor(UIColor.black.cgColor)
                context.fill(CGRect(x:0,y:0,width:cg.width,height:cg.height))
            }
            context.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
            let x = Int(point.x / size.width * CGFloat(cg.width))
            let y = Int(point.y / size.height * CGFloat(cg.height))
            let offset = (y * cg.width + x) * 4
            let values = bytes.bindMemory(to:UInt8.self)
            return transparent ? values[offset+3] > 100 :
                Int(values[offset]) + Int(values[offset+1]) + Int(values[offset+2]) > 600
        }
    }

    var body: some View {
        ScrollView { Text(result).accessibilityIdentifier("nativeInkProbeResult") }
            .task(id:phase) {
                guard phase == .active, !started else { return }
                started = true
                let size = CGSize(width:128,height:100)
                let points = stride(from:10,through:110,by:20).enumerated().map { index,x in
                    PKStrokePoint(location:CGPoint(x:CGFloat(x),y:50),timeOffset:Double(index) * 0.1,
                        size:CGSize(width:8,height:8),opacity:1,force:1,azimuth:0,altitude:1)
                }
                let path = PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:1))
                let mask = UIBezierPath(rect:CGRect(x:0,y:30,width:40,height:40))
                mask.append(UIBezierPath(rect:CGRect(x:80,y:30,width:48,height:40)))
                let stroke = PKStroke(ink:PKInk(.pen,color:.white),path:path,mask:mask)
                let drawing = PKDrawing(strokes:[stroke])
                var scene = CanvasScene()
                scene.width = Double(size.width); scene.height = Double(size.height)
                scene.drawingBase64 = drawing.dataRepresentation().base64EncodedString()
                scene.strokes = [InkStroke(id:stroke.id,points:stroke.path.map {
                    InkPoint(x:Double($0.location.x),y:Double($0.location.y),pressure:Double($0.force))
                },createdAt:stroke.path.creationDate)]
                let original = drawing.image(from:CGRect(origin:.zero,size:size),scale:1)
                guard let png = SceneRenderer.png(scene:scene), let exported = UIImage(data:png) else {
                    result = "오류 PNG 없음"; return
                }
                var legacy = scene
                legacy.drawingBase64 = ""
                let legacyImage = SceneRenderer.png(scene:legacy).flatMap(UIImage.init(data:))
                var malformed = scene
                malformed.drawingBase64 = "not-base64"
                var invalidDrawing = scene
                invalidDrawing.drawingBase64 = Data("not-a-PKDrawing".utf8).base64EncodedString()
                var emptyDrawing = scene
                emptyDrawing.drawingBase64 = PKDrawing().dataRepresentation().base64EncodedString()
                let emptyImage = SceneRenderer.png(scene:emptyDrawing).flatMap(UIImage.init(data:))
                let payload:[String:Any] = [
                    "nativeLeftInk":ink(original,at:CGPoint(x:25,y:50),size:size,transparent:true),
                    "nativeGapInk":ink(original,at:CGPoint(x:60,y:50),size:size,transparent:true),
                    "nativeRightInk":ink(original,at:CGPoint(x:95,y:50),size:size,transparent:true),
                    "exportLeftInk":ink(exported,at:CGPoint(x:25,y:50),size:size),
                    "exportGapInk":ink(exported,at:CGPoint(x:60,y:50),size:size),
                    "exportRightInk":ink(exported,at:CGPoint(x:95,y:50),size:size),
                    "legacyGapInk":legacyImage.map { ink($0,at:CGPoint(x:60,y:50),size:size) } ?? false,
                    "malformedRefused":SceneRenderer.png(scene:malformed) == nil,
                    "invalidDrawingRefused":SceneRenderer.png(scene:invalidDrawing) == nil,
                    "emptyDrawingGapInk":emptyImage.map { ink($0,at:CGPoint(x:60,y:50),size:size) } ?? false,
                    "maskedPathRanges":stroke.maskedPathRanges.map { [Double($0.lowerBound),Double($0.upperBound)] },
                    "scope":"actual production SceneRenderer in foreground iPad diagnostic; synthetic ink only"]
                if let data = try? JSONSerialization.data(withJSONObject:payload,options:.sortedKeys) {
                    result = "완료\n" + String(decoding:data,as:UTF8.self)
                }
            }
    }
}
