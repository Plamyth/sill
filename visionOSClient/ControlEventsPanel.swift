import SwiftUI

@MainActor
struct ControlEventsPanel: View {
    @ObservedObject var controller: ControlEventsController
    @ObservedObject var enrollment: VisionControlEnrollmentController
    @State private var origin = VisionControlOrigin.publicDefault
    @State private var enrollmentCode = ""
    @State private var registeringAgain = false
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("작업 상태").font(.title2)
                    Spacer()
                    Button("다시 연결") {
                        if !enrollment.restore() { controller.reconnect() }
                    }.disabled(!controller.configured || enrollment.submitting)
                    Button("닫기", action: close)
                }
                enrollmentForm
                Text(controller.message).accessibilityIdentifier("control-events.connection-message")
                Text("원본 작업 이벤트가 도착하면 이 화면을 갱신합니다.").font(.caption)
                Text(controller.reducer.isCurrent ? "연결 서버 상태 수신 중 · 원본 관측은 아래에서 확인" : "마지막 관측 · 현재 실행 상태와 연결은 미확인")
                    .foregroundStyle(controller.reducer.isCurrent ? .primary : .secondary)
                Picker("원본 소스", selection: Binding(get: { controller.selection.provider }, set: { controller.selection.select($0) })) {
                    ForEach(ControlEventsProvider.allCases) { provider in Text(provider.label).tag(provider) }
                }.pickerStyle(.segmented)
                sourceDetails
                Picker("원본 세션 / 실행", selection: $controller.selection.workID) {
                    Text("선택 안 함").tag(Optional<ControlEventsWorkID>.none)
                    ForEach(rows) { row in
                        Text(verbatim: "\(row.title) · \(row.id.sessionID ?? "세션 미확인") · \(row.id.runID ?? "실행 미확인")")
                            .tag(Optional(row.id))
                    }
                }
                if let selected = rows.first(where: { $0.id == controller.selection.workID }) {
                    details(selected)
                } else {
                    Text(rows.isEmpty ? "이 소스의 선택 가능한 원본 세션이 제공되지 않았습니다." : "원본 세션을 선택하세요.")
                }
                if let error = controller.projection?.adapterError { Text(verbatim: error).foregroundStyle(.orange) }
                if controller.projection?.truncated == true { Text("관제 목록의 일부만 제공되었습니다.") }
                if (controller.projection?.unsupportedRows ?? 0) > 0 {
                    Text("현재 계약에서 해석할 수 없는 소스 행이 있습니다. 해당 행의 상태와 권한은 제공하지 않습니다.")
                }
                Divider()
                field("명령 권한", "미제공 · 상태 구독은 메시지 전송·실행 권한을 만들지 않습니다.")
                field("연결 서버 세대", controller.reducer.version?.generation.uuidString.lowercased())
                field("연결 서버 변경 번호", controller.reducer.version.map { String($0.revision) })
                field("연결 서버 발행 시각", controller.reducer.version?.emittedAt)
                Text("발행·접속 시각은 원본 실행 관측 시각과 다릅니다. 연결이 끊기면 이전 실행 상태를 마지막 관측으로만 보존합니다.").font(.caption)
            }.padding(24)
        }
        .frame(width: 820, height: 650)
        .onAppear { enrollment.restore(); controller.setVisible(true) }
        .onDisappear { enrollmentCode = ""; controller.setVisible(false) }
    }

    @ViewBuilder private var enrollmentForm: some View {
        Text(enrollment.message)
        if let registered = enrollment.registeredOrigin {
            field("등록된 서버", registered)
            if !registeringAgain {
                Button("다시 등록") { origin = registered; registeringAgain = true }
                    .accessibilityHint("기존 연결 정보를 유지하며 새 일회용 코드로 등록을 갱신합니다.")
            }
        }
        if enrollment.registeredOrigin == nil || registeringAgain {
            TextField("HTTPS 연결 서버 주소", text: $origin).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Mac의 1회용 등록 코드", text: $enrollmentCode)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityHint("5분 동안 한 번 쓸 수 있는 24자리 코드를 입력한 뒤 등록 버튼을 누르세요.")
            Button(enrollment.submitting ? "등록 확인 중" : "이 Vision 앱 등록") {
                let code = enrollmentCode
                enrollmentCode = ""
                Task {
                    if await enrollment.submit(origin: origin, code: code) { registeringAgain = false }
                }
            }.disabled(enrollment.submitting || !VisionControlEnrollment.hex(enrollmentCode, count: 24))
            if registeringAgain {
                Button("등록 갱신 취소") { enrollmentCode = ""; registeringAgain = false }
                    .disabled(enrollment.submitting)
            }
            Text("코드는 저장하지 않으며 직접 제출할 때만 등록 요청을 한 번 보냅니다. 연결·등록 결과가 미확인이면 자동 재제출하지 않습니다.").font(.caption)
        }
    }

    private var rows: [ControlEventsWork] {
        (controller.projection?.work ?? []).filter { $0.id.provider == controller.selection.provider }
    }

    @ViewBuilder private var sourceDetails: some View {
        if let source = controller.projection?.sources.first(where: { $0.provider == controller.selection.provider }) {
            Text(source.support.label)
            field("제공자 요약 연결값", source.connection.state)
            field("제공자 요약 관측", source.connection.observedAt)
            field("제공자 요약 연결 시작", source.connection.connectedAt)
            field("제공자 요약 담당", source.owner)
            field("제공자 요약 세션", source.sessionID)
            field("제공자 요약 실행", source.runID)
            field("제공자 요약 변경 번호", formatted(source.sourceRevision))
            field("제공자 요약 권한값", formatted(source.capabilities))
            Text("소스 연결 요약은 선택한 세션의 실행 상태나 명령 권한을 보장하지 않습니다.").font(.caption)
        } else { Text("원본 이벤트 지원 여부 미확인 · 소스 연결 정보 미제공") }
        if controller.selection.provider == .cursorDesktop {
            Text("Cursor 로컬의 열린 대화 관측은 실행 이벤트와 다릅니다. 원본이 명시한 실행 상태·출처·관측만 별도로 표시합니다.").font(.caption)
        }
    }

    private func details(_ work: ControlEventsWork) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            field("원본 소스", work.id.provider.label)
            field("원본 식별자", work.id.originalID)
            field("원본 행 키", work.id.rowKey)
            field("원본 호스트", work.id.hostID)
            field("원본 세션", work.id.sessionID)
            field("원본 실행", work.id.runID)
            field("원담당 대화", work.ownerID)
            if work.reportedOwnerID != work.ownerID {
                field("미확인 담당 보고값", work.reportedOwnerID)
            }
            field("담당 확인", work.ownerVerified.map { $0 ? "원본에서 확인됨" : "미확인" })
            field("원본 행 관측", work.recordObservedAt)
            field("원본 상태값", work.reportedStatus)
            field("에이전트 상태", work.agentStatus)
            field("상태 출처", work.statusSource)
            field("원본 변경 번호", formatted(work.sourceRevision))
            field("원본 읽기 전용", work.readOnly.map { $0 ? "예" : "아니요 · 이 앱의 명령 권한과 별도" })
            field("원본 권한 보고", formatted(work.capabilities))
            Text("권한 보고를 보존하지만 이 Vision 앱에는 실행·전송 명령 경로를 제공하지 않습니다.").font(.caption)
            if work.id.provider == .cursorCloud {
                Text("현재 응답").font(.headline)
                if let result = controller.selectedResult {
                    Text(result.isStale ? "마지막 관측 · 현재 응답 여부는 미확인" : "선택한 실행에서 관측한 응답")
                        .font(.caption).foregroundStyle(.secondary)
                    if result.text.isEmpty {
                        Text("현재 응답이 빈 문자열입니다.")
                    } else {
                        Text(verbatim: result.text).textSelection(.enabled)
                    }
                } else {
                    Text("현재 응답이 제공되지 않았거나 읽기가 허용되지 않았습니다.")
                }
                Text("선택한 실행의 응답 전체를 표시합니다. 전체 대화 이력은 제공되지 않으며, 이 앱에서는 초안 전송을 지원하지 않습니다.").font(.caption)
            }
            if work.id.provider == .codex {
                Text(!controller.reducer.isCurrent && work.sourceConnection.isCurrent ? "마지막 관측 · 개별 원본 연결의 현재 상태 미확인" : work.sourceConnection.label)
                    .accessibilityIdentifier("control-events.session-connection")
                if !controller.reducer.isCurrent || !work.sourceConnection.isCurrent {
                    Text("아래 실행 상태와 시각은 마지막 관측입니다. 제공자 요약이나 서버 접속으로 개별 연결을 확인하지 않습니다.").font(.caption)
                }
            } else {
                if !controller.reducer.isCurrent { Text("마지막 관측 · 연결 서버 재접속 전입니다.") }
                field("세션 이벤트 연결 보고값", work.connection.state)
                field("세션 이벤트 연결 관측", work.connection.observedAt)
                field("세션 이벤트 연결 시작", work.connection.connectedAt)
            }
            field("실행 상태 관측값", work.execution.state)
            field("실행 관측 시각", work.execution.observedAt)
            if let source = work.sourceConnection.observation {
                field("개별 연결 제공자", source.provider.label)
                field("실행 환경 담당", source.owner)
                field("연결 결박 세션", source.sessionID)
                field("연결 결박 실행", source.runID)
                field("개별 연결 보고값", source.connection.state)
                field("개별 연결 여부 보고", source.connected.map { $0 ? "예 · 결박 판정과 별도" : "아니요" })
                field("개별 연결 관측", source.connection.observedAt)
                field("개별 연결 시작", source.connection.connectedAt)
                field("개별 연결 변경 번호", formatted(source.sourceRevision))
                field("관측기 읽기 전용", source.readOnly.map { $0 ? "예" : "아니요 · 이 앱의 권한과 별도" })
                field("관측기 권한 보고", formatted(source.capabilities))
            }
            field("기존 행 연결 보고값", work.connection.state)
            Text("기존 행의 연결값과 명령 도우미의 행 권한은 개별 원본 연결과 관측기 권한의 확인 근거가 아닙니다.").font(.caption)
            if work.id.provider == .cursorDesktop {
                field("로컬 인스턴스", work.id.instanceID)
                field("인스턴스 시작", work.id.startedAt)
                field("작업공간 식별자", work.id.workspaceIdentity)
            }
        }
    }

    private func formatted(_ value: ControlEventsValue?) -> String? {
        guard let value, value != .null, let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func field(_ name: String, _ value: String?) -> some View {
        HStack(alignment: .top) {
            Text(name).frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
            Text(verbatim: value ?? "미확인").textSelection(.enabled)
        }.accessibilityElement(children: .combine)
    }
}
