import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

@main struct Checks {
    static func bitmap(_ draw: (CGContext) -> Void) -> Data {
        let context = CGContext(data:nil,width:64,height:32,bitsPerComponent:8,bytesPerRow:256,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return Data(bytes:context.data!,count:8192)
    }
    static func main() throws {
        let source = CGContext(data:nil,width:64,height:32,bitsPerComponent:8,bytesPerRow:256,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        source.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1)); source.fill(CGRect(x:0,y:0,width:32,height:32))
        source.setFillColor(CGColor(red:0,green:0,blue:1,alpha:1)); source.fill(CGRect(x:32,y:0,width:32,height:32))
        source.setFillColor(CGColor(red:0,green:1,blue:0,alpha:1)); source.fill(CGRect(x:0,y:16,width:32,height:16))
        let image = source.makeImage()!, bytes = NSMutableData()
        let writer = CGImageDestinationCreateWithData(bytes,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(writer,image,nil); precondition(CGImageDestinationFinalize(writer))
        let png = bytes as Data, size = CGSize(width:64,height:32)
        let imageExport = try RenderedSceneFile(png:png,size:size,format:.png,filename:"own-r1")
        precondition(imageExport.data == png && imageExport.format.contentType == .png)
        let export = try RenderedSceneFile(png:png,size:size,format:.pdf,filename:"own-r1")
        precondition(export.format.contentType == .pdf && export.filename == "own-r1")
        let folder = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let path = folder.appendingPathComponent("own-export.pdf")
        try export.data.write(to:path,options:.atomic)
        let reopened = try Data(contentsOf:path)
        precondition(reopened == export.data)
        let pdf = PDFDocument(url:path)!
        precondition(pdf.pageCount == 1 && pdf.page(at:0)!.bounds(for:.mediaBox) == CGRect(origin:.zero,size:size))
        precondition((pdf.string ?? "").isEmpty,"flattened image must not claim editable text")
        let original = bitmap { $0.draw(image,in:CGRect(origin:.zero,size:size)) }
        let rendered = bitmap { pdf.page(at:0)!.draw(with:.mediaBox,to:$0) }
        for (x,y) in [(8,8),(8,24),(48,8),(48,24)] {
            for channel in 0..<3 {
                let index = y * 256 + x * 4 + channel
                precondition(abs(Int(original[index])-Int(rendered[index])) <= 2,"PDF orientation or colors changed")
            }
        }
        for (data,bounds) in [(Data("bad".utf8),size),(png,CGSize(width:0,height:32)),
                              (png,CGSize(width:Double.nan,height:32)),(png,CGSize(width:20000,height:32))] {
            var refused = false
            do { _ = try RenderedSceneFile(png:data,size:bounds,format:.pdf,filename:"bad") }
            catch { refused = true }
            precondition(refused)
        }
        precondition(png == bytes as Data,"input PNG changed")
        print("PASS original PNG, one-page PDF, dimensions, pixel orientation/color, file reopen and invalid inputs")
    }
}
