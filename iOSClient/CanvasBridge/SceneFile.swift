import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import CoreText

struct SceneFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }
    var scene: CanvasScene
    var document: CanvasDocument? = nil

    init(scene: CanvasScene) { self.scene = scene }
    init(document: CanvasDocument) { self.scene = document.activePage; self.document = document }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoded = try CanvasDocument.decode(data)
        let fields = try JSONSerialization.jsonObject(with:data) as? [String:Any]
        scene = decoded.activePage
        if fields?["format"] != nil || fields?["pages"] != nil || fields?["version"] != nil { document = decoded }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return FileWrapper(regularFileWithContents:try document.map { try $0.bytes() } ?? encoder.encode(scene))
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

    init(outlineRows: [CanvasOutlinePDF.Row], filename: String) async throws {
        data = try await CanvasOutlinePDF.render(outlineRows)
        format = .pdf
        self.filename = filename
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard configuration.contentType.conforms(to:format.contentType) else { throw CocoaError(.fileWriteUnknown) }
        return FileWrapper(regularFileWithContents:data)
    }
}

enum CanvasOutlinePDF {
    struct Row {
        let id: UUID
        let depth: Int
        let text: String
        let reference: String?
        let isGroup: Bool
    }
    enum Failure: LocalizedError {
        case invalidOutline, cannotPaginate
        var errorDescription: String? {
            switch self {
            case .invalidOutline: return "표시할 개요가 없거나 계층을 확인하지 못했습니다. 원본은 그대로 유지합니다."
            case .cannotPaginate: return "개요의 페이지를 구성하지 못했습니다. 파일을 내보내지 않고 원본을 유지합니다."
            }
        }
    }
    static func render(_ rows: [Row]) async throws -> Data {
        guard !rows.isEmpty, Set(rows.map(\.id)).count == rows.count else { throw Failure.invalidOutline }
        let text = NSMutableAttributedString(string:"")
        let font = CTFontCreateUIFontForLanguage(.system,14,"ko" as CFString) ?? CTFontCreateWithName("Helvetica" as CFString,14,nil)
        var previousDepth = -1
        for row in rows {
            try Task.checkCancellation()
            guard row.depth >= 0, row.depth <= previousDepth + 1 else { throw Failure.invalidOutline }
            previousDepth = row.depth
            var indent = CGFloat(min(row.depth,12)) * 18, spacing: CGFloat = 8
            let style = withUnsafePointer(to:&indent) { indentPointer in
                withUnsafePointer(to:&spacing) { spacingPointer in
                    let settings = [
                        CTParagraphStyleSetting(spec:.firstLineHeadIndent,valueSize:MemoryLayout<CGFloat>.size,value:indentPointer),
                        CTParagraphStyleSetting(spec:.headIndent,valueSize:MemoryLayout<CGFloat>.size,value:indentPointer),
                        CTParagraphStyleSetting(spec:.paragraphSpacing,valueSize:MemoryLayout<CGFloat>.size,value:spacingPointer)
                    ]
                    return CTParagraphStyleCreate(settings,settings.count)
                }
            }
            let body = (row.isGroup ? "그룹 · 기존 순서\n" : "") + (row.text.isEmpty ? "이름 없는 요소" : row.text) +
                (row.reference.map { "\n" + $0 } ?? "") + "\n"
            text.append(NSAttributedString(string:body,attributes:[
                NSAttributedString.Key(kCTFontAttributeName as String):font,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String):style
            ]))
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let output = NSMutableData()
        var bounds = CGRect(x:0,y:0,width:595,height:842)
        let pageText = bounds.insetBy(dx:42,dy:42)
        guard let consumer = CGDataConsumer(data:output as CFMutableData),
              let context = CGContext(consumer:consumer,mediaBox:&bounds,nil) else { throw Failure.cannotPaginate }
        var offset = 0
        while offset < text.length {
            try Task.checkCancellation()
            let frame = CTFramesetterCreateFrame(framesetter,CFRange(location:offset,length:0),CGPath(rect:pageText,transform:nil),nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.location == offset, visible.length > 0, visible.length <= text.length - offset else {
                throw Failure.cannotPaginate
            }
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            CTFrameDraw(frame,context)
            context.endPDFPage()
            offset += visible.length
            await Task.yield()
        }
        context.closePDF()
        try Task.checkCancellation()
        guard output.length > 0 else { throw Failure.cannotPaginate }
        return output as Data
    }
}
