MUTANTS = [
    ('cancel-before-enqueue', 'iOSClient/SessionLink.swift', [
        ('guard outcome == nil, !claimed else { return false }', 'guard !claimed else { return false }'),
        ('guard outcome == nil else { lock.unlock(); return false }', 'if false { lock.unlock(); return false }'),
    ], 'cancel before enqueue refuses actual send'),
    ('duplicate-ticket', 'iOSClient/SessionLink.swift', [
        ('guard outcome == nil, !claimed else { return false }', 'guard outcome == nil else { return false }'),
    ], 'ticket cannot be enqueued twice'),
    ('terminal-once', 'iOSClient/SessionLink.swift', [
        ('guard outcome == nil else { lock.unlock(); return }', 'guard outcome != .cancelled else { lock.unlock(); return }'),
    ], 'submitted ticket cannot be cancelled or notified twice'),
    ('specific-cancel', 'iOSClient/SessionLink.swift', [
        ('discardWaitingLocked { $0.submission === submission }', 'discardWaitingLocked { $0.submission != nil }'),
    ], 'specific cancellation removes only own input count'),
    ('peer-refusal', 'iOSClient/SessionLink.swift', [
        ('guard current === expected else { submission?.cancel(); return false }', ''),
    ], 'peer refusal reports false immediately'),
    ('permit-refusal', 'iOSClient/SessionLink.swift', [
        ('guard permit == nil || permit == inputPermit else { submission?.cancel(); return false }', ''),
    ], 'permit refusal reports false immediately'),
    ('marked-review', 'visionOSClient/VisionTextDraft.swift', [
        ('!value.marked, value.composition.canReview', 'value.composition.canReview'),
    ], 'marked Korean composition blocks review'),
    ('editor-generation', 'visionOSClient/VisionTextDraft.swift', [
        ('mutating func observe(_ value: VisionDraftObservation) {\n        guard case .editing(let editor) = phase, editor.id == value.editorID,',
         'mutating func observe(_ value: VisionDraftObservation) {\n        guard case .editing = phase,'),
    ], 'new editor generation excludes late callbacks'),
    ('dictation-ended', 'visionOSClient/VisionTextDraft.swift', [
        ('mutating func ended() { unresolved = true }', 'mutating func ended() {}'),
    ], 'end before result never implies completion'),
    ('cluster-limit', 'visionOSClient/VisionTextDraft.swift', [
        ('String($0).utf16.count <= 16', 'String($0).utf16.count <= 64'),
    ], 'over sixteen UTF16 units in a Character refused'),
    ('final-validator', 'Client.swift', [
        ('guard VisionDraftText.accepts(text), captureVisionTextTarget() == target,',
         'guard captureVisionTextTarget() == target,'),
    ], 'final client boundary refuses invalid text without send'),
    ('target-label', 'Client.swift', [
        ('&& lhs.permit == rhs.permit && lhs.scope == rhs.scope',
         '&& lhs.permit == rhs.permit && lhs.scope == rhs.scope && lhs.label == rhs.label'),
    ], 'human label does not grant or revoke authority'),
    ('foreground-cancel', 'Client.swift', [
        ('if !foreground { revokeVisionTextDrafts() }', 'if false { revokeVisionTextDrafts() }'),
    ], 'foreground false cancels queued text even on legacy host'),
    ('scope-reuse', 'Client.swift', [
        ('&& lhs.permit == rhs.permit && lhs.scope == rhs.scope', '&& lhs.permit == rhs.permit'),
    ], 'foreground return never restores old scope'),
    ('request-reuse', 'Client.swift', [
        ('guard visionTextRequest != requestID else { return }', ''),
    ], 'duplicate client request emits one matching terminal and one message'),
]
