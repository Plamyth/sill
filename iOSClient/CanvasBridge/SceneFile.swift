import SwiftUI
import UniformTypeIdentifiers

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
