import Foundation
import PencilKit

@main struct InkRecognizerCapabilityProbe {
    @MainActor static func main() async throws {
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let bytes = try Data(contentsOf: file)
        let drawing = try PKDrawing(data: bytes)
        let supported = PKStrokeRecognizer.supportedLanguages
        let preferred = [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "ko-KR")]
            .filter { wanted in supported.contains(where: { $0.languageCode == wanted.languageCode }) }
        let recognizer = PKStrokeRecognizer(preferredLanguages: preferred.isEmpty ? nil : preferred)
        await recognizer.updateDrawing(drawing)
        let retained = await recognizer.drawing
        let languages = await recognizer.languages
        let fullText = await recognizer.recognizedText()
        let filteredText = await recognizer.recognizedText(strokeIDs: Set(drawing.strokes.map(\.id)))
        let result: [String: Any] = [
            "schema": "ccr.ink-recognizer-capability/v1", "pid": ProcessInfo.processInfo.processIdentifier,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? NSNull(),
            "supportedLanguageCodes": supported.compactMap { $0.languageCode?.identifier }.sorted(),
            "requestedLanguageCodes": preferred.compactMap { $0.languageCode?.identifier },
            "effectiveLanguageCodes": languages.compactMap { $0.languageCode?.identifier },
            "preferredSystemLanguages": Locale.preferredLanguages,
            "recognitionVersion": PKStrokeRecognizer.recognitionVersion,
            "inputStrokeCount": drawing.strokes.count, "recognizerDrawingStrokeCount": retained.strokes.count,
            "recognizerDrawingEqualsInput": retained == drawing,
            "fullTextWithoutStrokeFilter": fullText ?? NSNull(),
            "textWithAllInputStrokeIDs": filteredText ?? NSNull(),
            "evidenceInjected": false, "providerInstall": false, "deviceHostChanges": false
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print(String(decoding: try Data(contentsOf: output), as: UTF8.self))
    }
}
