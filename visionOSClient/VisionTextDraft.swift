import Foundation

enum VisionDraftText {
    static func accepts(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 256, text.utf8.count <= 2048 else { return false }
        guard !text.unicodeScalars.contains(where: {
            switch $0.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return true
            case .format: return $0.value != 0x200C && $0.value != 0x200D
            default: return false
            }
        }) else { return false }
        return text.allSatisfy { String($0).utf16.count <= 16 }
    }
}

/// Evidence observed from UIKit, never a claim that Dictation has stopped recording.
struct VisionDraftComposition: Equatable {
    private(set) var placeholders: Set<UUID> = []
    private(set) var unresolved = false
    mutating func placeholder(_ id: UUID) { placeholders.insert(id) }
    mutating func removed(_ id: UUID?, willInsert: Bool) {
        guard let id, placeholders.remove(id) != nil else { unresolved = true; return }
        if willInsert { unresolved = true }
    }
    mutating func ended() { unresolved = true }
    mutating func failed() { unresolved = true }
    // Public hooks do not correlate insertion and placeholders. A fresh explicit editor is recovery.
    var canReview: Bool { placeholders.isEmpty && !unresolved }
}

struct VisionDraftObservation {
    let editorID: UUID
    let revision: UInt64
    let text: String
    let marked: Bool
    let composition: VisionDraftComposition
}

struct VisionTextDraft<Target: Equatable> {
    struct Editor {
        let id: UUID
        let seed: String
    }
    struct Review {
        let id: UUID
        let editorID: UUID
        let revision: UInt64
        let text: String
        let target: Target
    }
    enum Phase {
        case editing(Editor)
        case reviewing(Review)
        case submitting(Review, requestID: UUID)
        case submitted
        case notSent
        case stale
    }
    let id = UUID()
    let target: Target
    private(set) var phase: Phase
    private(set) var observation: VisionDraftObservation?

    init(target: Target) {
        self.target = target
        phase = .editing(Editor(id: UUID(), seed: ""))
    }

    mutating func observe(_ value: VisionDraftObservation) {
        guard case .editing(let editor) = phase, editor.id == value.editorID,
              observation == nil || value.revision >= observation!.revision else { return }
        observation = value
    }

    @discardableResult
    mutating func review(_ value: VisionDraftObservation) -> Bool {
        guard case .editing(let editor) = phase, editor.id == value.editorID,
              observation == nil || value.revision >= observation!.revision,
              !value.marked, value.composition.canReview, VisionDraftText.accepts(value.text) else { return false }
        phase = .reviewing(Review(id: UUID(), editorID: editor.id, revision: value.revision,
                                  text: value.text, target: target))
        observation = nil
        return true
    }

    mutating func editAgain() {
        guard case .reviewing(let review) = phase else { return }
        phase = .editing(Editor(id: UUID(), seed: review.text))
        observation = nil
    }

    /// Recovery is explicit and creates a new editor; it never resolves the old speech lifecycle.
    mutating func recover(_ value: VisionDraftObservation) {
        guard case .editing(let editor) = phase, editor.id == value.editorID else { return }
        phase = .editing(Editor(id: UUID(), seed: value.text))
        observation = nil
    }

    mutating func beginSubmission(currentTarget: Target?) -> (Review, UUID)? {
        guard case .reviewing(let review) = phase else { return nil }
        guard currentTarget == target, VisionDraftText.accepts(review.text) else {
            invalidate(); return nil
        }
        let request = UUID()
        phase = .submitting(review, requestID: request)
        return (review, request)
    }

    mutating func finish(reviewID: UUID, requestID: UUID, submitted: Bool) {
        guard case .submitting(let review, let request) = phase,
              review.id == reviewID, request == requestID else { return }
        phase = submitted ? .submitted : .notSent
    }

    mutating func invalidate() { observation = nil; phase = .stale }
}
