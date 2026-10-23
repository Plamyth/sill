import UIKit

/// 진단 iOS 타깃에서 await NodeRotationRendererChecks.run()을 호출한다.
/// 정상 앱·vault·relay를 사용하지 않는 실제 SceneRenderer PNG 픽셀 검사다.
enum NodeRotationRendererChecks {
    enum Failure: Error { case render, pixels }

    @MainActor static func run() async throws -> [String:Data] {
        var scene = CanvasScene()
        scene.width = 640; scene.height = 400
        _ = scene.addNode(kind:.box,at:.init(x:80,y:160))
        scene.nodes[0].frame = .init(x:80,y:160,width:240,height:80)
        _ = scene.addNode(kind:.box,at:.init(x:460,y:160))
        scene.nodes[1].frame = .init(x:460,y:160,width:80,height:80)
        guard let before = await SceneRenderer.png(scene:scene) else { throw Failure.render }
        scene.nodes[0].rotationDegrees = 90
        guard let after = await SceneRenderer.png(scene:scene),
              gray(before,x:100,y:200), !gray(before,x:200,y:100),
              gray(after,x:200,y:100), !gray(after,x:100,y:200),
              gray(before,x:500,y:200), gray(after,x:500,y:200) else { throw Failure.pixels }
        return ["unrotated.png":before,"rotated.png":after]
    }

    private static func gray(_ png: Data, x: Int, y: Int) -> Bool {
        guard let image = UIImage(data:png)?.cgImage else { return false }
        let width = 640, height = 400
        var bytes = [UInt8](repeating:0,count:width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let cg = CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width * 4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            cg.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            return true
        }
        let i = (y * width + x) * 4
        return ok && bytes[i] > 25 && abs(Int(bytes[i]) - Int(bytes[i+1])) < 5 &&
            abs(Int(bytes[i+1]) - Int(bytes[i+2])) < 5
    }
}
