import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct SceneFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }
    var scene: CanvasScene

    init(scene: CanvasScene) { self.scene = scene }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        scene = try JSONDecoder().decode(CanvasScene.self,from:data)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return FileWrapper(regularFileWithContents:try encoder.encode(scene))
    }
}

struct RenderedSceneFile: FileDocument {
    enum Failure: LocalizedError {
        case invalidImage
        var errorDescription: String? { "이미지의 형식·크기 또는 내용을 확인하지 못했습니다. 편집 원본은 그대로 유지합니다." }
    }
    enum Format {
        case png, pdf
        var contentType: UTType { self == .png ? .png : .pdf }
    }
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.png, .pdf] }
    let data: Data
    let format: Format
    let filename: String

    init(png: Data, size: CGSize, format: Format, filename: String) throws {
        guard png.count <= 32 * 1024 * 1024, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, size.width <= 16384, size.height <= 16384,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source).map({ UTType($0 as String)?.conforms(to:.png) == true }) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384,
              width * height <= 32 * 1024 * 1024 else { throw Failure.invalidImage }
        self.format = format
        self.filename = filename
        if format == .png { data = png; return }
        guard let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw CocoaError(.fileReadCorruptFile) }
        let output = NSMutableData()
        var bounds = CGRect(origin:.zero,size:size)
        guard let consumer = CGDataConsumer(data:output as CFMutableData),
              let context = CGContext(consumer:consumer,mediaBox:&bounds,nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        context.draw(image,in:bounds)
        context.endPDFPage()
        context.closePDF()
        guard output.length > 0 else { throw CocoaError(.fileWriteUnknown) }
        data = output as Data
    }

    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard configuration.contentType.conforms(to:format.contentType) else { throw CocoaError(.fileWriteUnknown) }
        return FileWrapper(regularFileWithContents:data)
    }
}
