import SwiftUI
import UIKit

@MainActor
final class VisionDraftEditorHandle {
    weak var view: VisionDraftTextView?
    func sample() -> VisionDraftObservation? { view?.sample() }
}

@MainActor
final class VisionDraftTextView: UITextView {
    var editorID = UUID()
    var observation: ((VisionDraftObservation) -> Void)?
    private var revision: UInt64 = 0
    private var composition = VisionDraftComposition()
    private var placeholders: [(object: AnyObject, id: UUID)] = []

    func sample() -> VisionDraftObservation {
        revision &+= 1
        return VisionDraftObservation(editorID: editorID, revision: revision, text: text ?? "",
                                      marked: markedTextRange != nil, composition: composition)
    }

    func publish() { observation?(sample()) }

    override func insertText(_ text: String) {
        super.insertText(text)
        publish()
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        super.setMarkedText(markedText, selectedRange: selectedRange)
        publish()
    }

    override func unmarkText() {
        super.unmarkText()
        publish()
    }

    override func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        super.insertDictationResult(dictationResult)
        publish()
    }

    override func dictationRecordingDidEnd() {
        super.dictationRecordingDidEnd()
        composition.ended()
        publish()
    }

    override func dictationRecognitionFailed() {
        super.dictationRecognitionFailed()
        composition.failed()
        publish()
    }

    override var insertDictationResultPlaceholder: Any {
        let placeholder = super.insertDictationResultPlaceholder
        let id = UUID()
        placeholders.append((placeholder as AnyObject, id))
        composition.placeholder(id)
        publish()
        return placeholder
    }

    override func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {
        let index = placeholders.firstIndex { $0.object === (placeholder as AnyObject) }
        let id = index.map { placeholders.remove(at: $0).id }
        super.removeDictationResultPlaceholder(placeholder, willInsertResult: willInsertResult)
        composition.removed(id, willInsert: willInsertResult)
        publish()
    }
}

@MainActor
struct VisionDraftEditor: UIViewRepresentable {
    let editorID: UUID
    let seed: String
    let handle: VisionDraftEditorHandle
    let observed: (VisionDraftObservation) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> VisionDraftTextView {
        let view = VisionDraftTextView()
        view.editorID = editorID
        view.text = seed
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityLabel = "Mac 입력 초안"
        view.accessibilityHint = "여기서 편집하거나 시스템 키보드 받아쓰기를 사용한 뒤 검토하세요. 아직 Mac으로 보내지 않습니다."
        view.delegate = context.coordinator
        view.observation = observed
        handle.view = view
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window != nil, view.observation != nil else { return }
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ view: VisionDraftTextView, context: Context) {
        view.observation = observed
    }

    static func dismantleUIView(_ view: VisionDraftTextView, coordinator: Coordinator) {
        view.observation = nil
        view.delegate = nil
        view.resignFirstResponder()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        func textViewDidChange(_ textView: UITextView) { (textView as? VisionDraftTextView)?.publish() }
        func textViewDidChangeSelection(_ textView: UITextView) { (textView as? VisionDraftTextView)?.publish() }
        func textViewDidEndEditing(_ textView: UITextView) { (textView as? VisionDraftTextView)?.publish() }
    }
}

@MainActor
struct VisionTextDraftPanel: View {
    typealias Draft = VisionTextDraft<StreamClient.VisionTextTarget>
    @ObservedObject var client: StreamClient
    @Binding var draft: Draft?
    let close: () -> Void
    @State private var editor = VisionDraftEditorHandle()
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mac 입력 초안").font(.title2)
            if let draft {
                Text(draft.target.label).font(.headline)
                Text("Mac에서 입력할 칸을 먼저 선택하세요. 위 표시는 Mac과 화면만 구분하며 입력 칸을 확인하지 않습니다.")
                    .font(.caption)
                if draft.target.binding.isLegacy {
                    Text("이전 Mac 호환 모드 · 화면 세대 확인을 지원하지 않습니다.").font(.caption)
                }
                content(draft)
            }
            if let problem { Text(problem).foregroundStyle(.orange).accessibilityLabel(problem) }
            Button("닫고 초안 지우기", action: close)
        }
        .padding(24)
        .frame(width: 600, height: 520)
    }

    @ViewBuilder
    private func content(_ value: Draft) -> some View {
        switch value.phase {
        case .editing(let session):
            VisionDraftEditor(editorID: session.id, seed: session.seed, handle: editor) { observation in
                guard draft?.id == value.id else { return }
                draft?.observe(observation)
            }
            .id(session.id)
            Text("한 줄, 최대 256자입니다. 줄바꿈·탭·제어 문자는 보낼 수 없습니다.").font(.caption)
            HStack {
                Button("검토") {
                    guard let observation = editor.sample(), draft?.id == value.id else { return }
                    if draft?.review(observation) == true {
                        editor.view?.resignFirstResponder()
                        problem = nil
                    } else {
                        if observation.composition.unresolved {
                            problem = "받아쓰기 결과 순서를 확인할 수 없습니다. ‘보이는 글만 새 편집으로’를 선택한 뒤 내용을 확인하고 다시 검토하세요. 기다려도 이 상태는 해제되지 않습니다."
                        } else {
                            problem = "조합 중이거나 받아쓰기 결과가 아직 남아 있으면 검토할 수 없습니다. 비어 있거나 길이 제한을 넘는 문장, 제어 문자도 보낼 수 없습니다."
                        }
                    }
                }
                Button("보이는 글만 새 편집으로") {
                    guard let observation = editor.sample(), draft?.id == value.id else { return }
                    draft?.recover(observation)
                    problem = "이전 받아쓰기의 늦은 결과는 포함되지 않을 수 있습니다. 새 편집에서 내용을 확인한 뒤 검토하세요."
                }
                .accessibilityHint("미확인 받아쓰기를 완료로 간주하지 않고 현재 보이는 글만 새 편집으로 복사합니다.")
            }
        case .reviewing(let review):
            ScrollView { Text(verbatim: review.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Text("이 글 그대로 입력합니다. Enter는 추가하지 않습니다. 입력 뒤 원래 Mac 화면에서 결과를 확인하세요.").font(.caption)
            HStack {
                Button("다시 편집") { draft?.editAgain(); problem = nil }
                Button("Mac 입력") { submit(value) }
                    .accessibilityHint("검토한 글을 선택한 Mac 화면의 현재 입력 칸으로 한 번 전송합니다.")
            }
        case .submitting:
            ProgressView("전송 대기 중")
            Text("연결이나 화면이 바뀌면 대기 중인 전송을 취소합니다.")
        case .submitted:
            Text("전송 경로에 전달했습니다. 원래 Mac 화면에서 입력 결과를 확인하세요.")
        case .notSent:
            Text("전송하지 않았습니다. Mac 화면과 연결을 확인한 뒤 새 초안을 여세요.")
        case .stale:
            Text("화면 또는 연결 상태가 바뀌어 초안을 지웠습니다. 현재 Mac에서 입력할 칸을 다시 선택하세요.")
        }
    }

    private func submit(_ value: Draft) {
        guard draft?.id == value.id,
              let (review, request) = draft?.beginSubmission(currentTarget: client.captureVisionTextTarget()) else { return }
        client.submitVisionText(review.text, target: review.target, requestID: request) { outcome in
            guard draft?.id == value.id else { return }
            draft?.finish(reviewID: review.id, requestID: request, submitted: outcome == .submitted)
        }
    }
}
