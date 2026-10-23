import Foundation
import ImageIO

@main
struct NativeSceneEncoder {
    struct PNGInput: Decodable { let image: Data; let scene: CanvasScene }

    static func renderedRotationMatches(_ input: PNGInput) -> Bool {
        let data = input.image, scene = input.scene
        guard data.starts(with:[137,80,78,71,13,10,26,10]),
              data.suffix(12) == Data([0,0,0,0,73,69,78,68,174,66,96,130]),
              let source = CGImageSourceCreateWithData(data as CFData,nil),
              CGImageSourceGetType(source) == "public.png" as CFString,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source,0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= 2048, height >= 1536, width <= 8192, height <= 8192,
              width * 1536 == height * 2048,
              scene.width == 2048, scene.height == 1536, scene.nodes.count == 2,
              let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
        else { return false }
        let first = scene.nodes[0], second = scene.nodes[1]
        let f = first.frame, g = second.frame
        let angle = (first.rotationDegrees ?? 0) * .pi / 180
        let center = f.center
        let start = CanvasPoint(x:center.x + cos(angle)*f.width/2,y:center.y + sin(angle)*f.width/2)
        let end = CanvasPoint(x:g.x,y:g.y+g.height/2)
        let scale = Double(width) / scene.width
        var bytes = [UInt8](repeating:0,count:width*height*4)
        return bytes.withUnsafeMutableBytes { buffer in
            guard let cg = CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            cg.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            let pixels = buffer.bindMemory(to:UInt8.self)
            func sample(_ point: CanvasPoint, radius: Int, matches:(Int,Int,Int)->Bool) -> Bool {
                let px=(point.x*scale).rounded(), py=(point.y*scale).rounded()
                guard px.isFinite, py.isFinite, px >= Double(radius), py >= Double(radius),
                      px < Double(width-radius), py < Double(height-radius) else { return false }
                let x=Int(px), y=Int(py)
                for py in (y-radius)...(y+radius) {
                    for px in (x-radius)...(x+radius) {
                        let i=(py*width+px)*4
                        if matches(Int(pixels[i]),Int(pixels[i+1]),Int(pixels[i+2])) { return true }
                    }
                }
                return false
            }
            func gray(_ p: CanvasPoint) -> Bool {
                sample(p,radius:0) { r,g,b in 30 < r && r < 140 && abs(r-g)<10 && abs(g-b)<10 }
            }
            guard gray(.init(x:center.x+100*cos(angle),y:center.y+100*sin(angle))),
                  !gray(.init(x:center.x+120,y:center.y)) else { return false }
            return [0.03,0.15,0.35,0.6,0.8,0.97].allSatisfy { t in
                sample(.init(x:start.x+(end.x-start.x)*t,y:start.y+(end.y-start.y)*t),
                       radius:max(2,Int((2*scale).rounded()))) { r,g,b in r<100 && g>150 && b>150 }
            }
        }
    }

    static func main() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if CommandLine.arguments.dropFirst() == ["--check-rotation-pixels"] {
            let input = try JSONDecoder().decode(PNGInput.self,from:data)
            FileHandle.standardOutput.write(try encoder.encode(["valid":renderedRotationMatches(input)]))
        } else {
            let scene = try JSONDecoder().decode(CanvasScene.self,from:data)
            FileHandle.standardOutput.write(try encoder.encode(scene))
        }
    }
}
