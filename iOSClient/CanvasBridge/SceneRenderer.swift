import SwiftUI
import PencilKit

enum CanvasPalette {
    static let background = UIColor.black
    static let ink = UIColor.white
    static let link = UIColor.cyan
    static let nodeFill = UIColor.darkGray
    static let nodeText = UIColor.white
}

enum SceneRenderer {
    @MainActor
    static func png(scene: CanvasScene) async -> Data? {
        guard scene.nodes.allSatisfy(\.hasValidRotation) else { return nil }
        let visible = scene.visibility
        let drawing: PKDrawing?
        if scene.drawingBase64.isEmpty {
            drawing = nil
        } else {
            guard let data = Data(base64Encoded: scene.drawingBase64),
                  let decoded = try? PKDrawing(data: data) else { return nil }
            drawing = decoded
        }
        let size = CGSize(width: scene.width, height: scene.height)
        let bounds = CGRect(origin: .zero, size: size)
        let scale = UIScreen.main.scale
        let inkImage: UIImage?
        guard drawing != nil || scene.strokes.allSatisfy({ $0.style == nil }) else { return nil }
        if let drawing {
            guard let bitmap = CGContext(data: nil, width: Int(ceil(size.width * scale)),
                height: Int(ceil(size.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            bitmap.scaleBy(x: scale, y: scale)
            await drawing.draw(in: bitmap, frame: bounds, from: bounds, darkUserInterfaceStyle: false)
            guard let rendered = bitmap.makeImage() else { return nil }
            inkImage = UIImage(cgImage: rendered, scale: scale, orientation: .up)
        } else { inkImage = nil }
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            CanvasPalette.background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.setLineWidth(4)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
            if let inkImage {
                inkImage.draw(in: bounds)
            } else {
                for stroke in scene.strokes {
                    for points in stroke.visiblePointSegments {
                        guard let first = points.first else { continue }
                        cg.move(to: CGPoint(x: first.x, y: first.y))
                        for point in points.dropFirst() {
                            cg.addLine(to: CGPoint(x: point.x, y: point.y))
                        }
                        cg.strokePath()
                    }
                }
            }
            for link in scene.links where visible.linkIDs.contains(link.id) {
                guard let endpoints = scene.linkEndpoints(link) else { continue }
                let from = endpoints.from, to = endpoints.to
                let a = CGPoint(x: from.x, y: from.y)
                let b = CGPoint(x: to.x, y: to.y)
                cg.setStrokeColor(CanvasPalette.link.cgColor)
                cg.setLineWidth(4)
                cg.move(to: a); cg.addLine(to: b); cg.strokePath()
                let angle = atan2(b.y - a.y, b.x - a.x)
                let wing = CGFloat.pi / 7
                for sign in [-1.0,1.0] {
                    let end = CGPoint(x: b.x - 18 * cos(angle + sign * wing),
                                      y: b.y - 18 * sin(angle + sign * wing))
                    cg.move(to: b); cg.addLine(to: end); cg.strokePath()
                }
            }
            for node in scene.nodes where visible.nodeIDs.contains(node.id) {
                let frame = CGRect(x: node.frame.x, y: node.frame.y,
                                   width: node.frame.width, height: node.frame.height)
                cg.saveGState()
                cg.translateBy(x:node.frame.center.x,y:node.frame.center.y)
                cg.rotate(by:node.rotationRadians)
                cg.translateBy(x:-node.frame.center.x,y:-node.frame.center.y)
                CanvasPalette.nodeFill.setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: 14).fill()
                let color = node.confidence == .proposal ? UIColor.systemOrange : CanvasPalette.link
                color.setStroke()
                let outline = UIBezierPath(roundedRect: frame, cornerRadius: 14)
                outline.lineWidth = 3
                outline.stroke()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 26, weight: .medium),
                    .foregroundColor: CanvasPalette.nodeText
                ]
                (node.text as NSString).draw(in: frame.insetBy(dx: 16, dy: 16), withAttributes: attributes)
                cg.restoreGState()
            }
            let annotationFrames = scene.annotationFrames
            for note in scene.annotations {
                guard let placement = annotationFrames[note.id] else { continue }
                let frame = CGRect(x:placement.x,y:placement.y,width:placement.width,height:placement.height)
                cg.saveGState()
                cg.clip(to:frame)
                UIColor.systemYellow.withAlphaComponent(0.85).setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: 10).fill()
                (note.text as NSString).draw(in: frame.insetBy(dx: 10, dy: 10), withAttributes:
                    [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
                cg.restoreGState()
            }
        }
        return image.pngData()
    }
}
