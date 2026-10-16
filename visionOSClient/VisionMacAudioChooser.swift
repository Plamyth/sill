import SwiftUI
import StreamProtocol

struct VisionMacAudioChooser: View {
    @ObservedObject var routes: VisionMacAudioController
    let admit: (() -> Void) -> Void
    let close: () -> Void
    @State private var draft: VisionMacAudioDraft?
    @State private var presentationScope: VisionMacAudioScope?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Mac 오디오 장치").font(.title2)
            Text("Mac 전체의 기본 입력·출력 장치가 변경됩니다.")
            Text("Vision Pro의 소리 재생과 마이크 전송은 별도 설정입니다.").font(.caption)
            if !routes.catalogInvalid, let current = routes.model.state, current.available {
                Text("현재 입력: \(name(current.defaults.inputUID, in: current))")
                Text("현재 출력: \(name(current.defaults.outputUID, in: current))")
            }
            if let draft {
                Picker("입력 장치", selection: Binding(get: { self.draft?.inputUID }, set: { self.draft?.inputUID = $0 })) {
                    Text("변경하지 않음").tag(String?.none)
                    ForEach(draft.endpoints.filter(\.input), id: \.uid) { endpoint in
                        Text(endpoint.name).tag(Optional(endpoint.uid))
                    }
                }
                .disabled(routes.scope == nil || routes.catalogInvalid || routes.model.pending != nil)
                Picker("출력 장치", selection: Binding(get: { self.draft?.outputUID }, set: { self.draft?.outputUID = $0 })) {
                    Text("변경하지 않음").tag(String?.none)
                    ForEach(draft.endpoints.filter(\.output), id: \.uid) { endpoint in
                        Text(endpoint.name).tag(Optional(endpoint.uid))
                    }
                }
                .disabled(routes.scope == nil || routes.catalogInvalid || routes.model.pending != nil)
                if !routes.isCurrent(draft) {
                    Text("Mac 목록이 바뀌었습니다. 새 목록을 확인하고 다시 선택해 주세요.").foregroundStyle(.orange)
                }
            }
            Text(status).accessibilityLabel(status)
            HStack {
                Button("목록 새로고침") { admit { routes.refresh() } }
                    .disabled(!routes.canRefresh)
                Button("새 목록으로 다시 선택") { admit { resetDraft() } }
                    .disabled(routes.scope == nil || routes.draft == nil || routes.model.pending != nil)
                Spacer()
                Button("적용") {
                    admit { if let draft { routes.apply(draft) } }
                }
                .disabled(routes.scope == nil || (draft.map { !routes.canApply($0) } ?? true))
                .accessibilityHint("선택한 장치를 Mac 전체의 기본 장치로 변경하고 결과를 확인합니다.")
                Button("닫기", action: close)
            }
        }
        .padding(30)
        .frame(minWidth: 640)
        .onAppear {
            guard presentationScope == nil else { return }
            presentationScope = routes.scope
            resetDraft()
        }
        .onDisappear { admit { routes.closeChooser(expectedScope: presentationScope) } }
        .onChange(of: routes.model.pending?.requestID) { _, pending in
            if pending == nil { draft = nil }
        }
        .onChange(of: routes.scope) { _, _ in close() }
    }

    private func resetDraft() {
        draft = routes.draft
    }

    private func name(_ uid: String?, in catalog: AudioRouteState) -> String {
        guard let uid else { return "확인할 수 없음" }
        return catalog.endpoints.first { $0.uid == uid }?.name ?? "목록에 없는 현재 기본 장치"
    }

    private var status: String {
        if let problem = routes.problem { return problem }
        if routes.catalogInvalid { return "Mac 오디오 장치 정보를 읽을 수 없습니다." }
        if let outcome = routes.model.outcome { return outcome.title }
        guard let state = routes.model.state else { return "목록을 아직 받지 못했습니다." }
        return state.available ? "장치를 선택하고 적용을 눌러 주세요." : "Mac 오디오 장치 정보를 읽을 수 없습니다."
    }
}
