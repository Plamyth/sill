import Foundation
import PencilKit
import AppKit

@main struct RenderOwnFixture {
    static func main() throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let drawing = try PKDrawing(data: Data(contentsOf: input))
        let bounds = drawing.bounds.insetBy(dx: -10, dy: -10)
        let bitmap = NSBitmapImageRep(data: drawing.image(from: bounds, scale: 2).tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: output, options: .atomic)
    }
}
