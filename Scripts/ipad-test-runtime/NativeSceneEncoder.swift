import Foundation

@main
struct NativeSceneEncoder {
    static func main() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let scene = try JSONDecoder().decode(CanvasScene.self, from: data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(scene))
    }
}
