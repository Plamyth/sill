import SwiftUI

struct VisionDisplayChooser: View {
    @ObservedObject var client: StreamClient
    let choose: (VisionDisplaySelection.Command) -> Void
    let cancel: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Mac 모니터 선택").font(.title2)
            Text("이 선택 창을 열면 기존 입력과 소리·마이크 전송을 중지합니다. 표시할 모니터를 직접 선택하세요.")
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(client.visionDisplaySelection.choices) { display in
                        let token = client.visionDisplaySelection.token
                        Button {
                            if let token {
                                choose(.init(requestID: UUID(), displayID: display.id, token: token))
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(display.name)
                                    Text("\(display.width) × \(display.height)").font(.caption)
                                }
                                Spacer()
                                if client.visionDisplaySelection.observedDisplay == display.id {
                                    Image(systemName: "checkmark").accessibilityLabel("Mac에서 현재 표시 중")
                                }
                            }
                        }
                        .disabled(token == nil || client.visionDisplaySelection.pending != nil)
                        .accessibilityHint("이 모니터를 명시적으로 요청합니다. 체크 표시는 Mac 목록에서 관측한 현재 모니터입니다.")
                    }
                }
            }
            .frame(maxHeight: 320)
            Text(status).foregroundStyle(.secondary)
            if client.visionDisplaySelection.inputBlocked {
                Text("원격 입력을 멈췄습니다. 완료 후 닫거나, 실패한 경우 모니터를 새로 선택하세요. 연결 해제도 사용할 수 있습니다.")
                    .font(.caption)
            }
            HStack {
                if client.visionDisplaySelection.pending != nil {
                    Button("요청 취소", action: cancel)
                }
                Spacer()
                Button("닫기", action: close)
            }
        }
        .padding(30)
        .frame(width: 620)
    }

    private var status: String {
        let code = client.visionDisplaySelection.lastResult?.code
        switch code {
        case .releasing: return "Mac이 누른 입력의 해제를 읽었는지 확인하고 있습니다."
        case .queued: return "연결의 전송 순서를 기다리고 있습니다."
        case .observing: return "요청을 전송했습니다. Mac 목록과 화면 표시가 일치하는지 기다립니다."
        case .unchanged: return "이미 이 Mac 모니터를 표시하고 있습니다."
        case .observed: return "선택한 모니터가 Mac 목록과 표시된 화면에서 확인되었습니다."
        case .timedOut: return "확인 시간이 지났습니다. 모니터를 다시 선택하거나 연결을 해제하세요."
        case .releaseFailed: return "Mac의 입력 해제 확인에 실패했습니다. 다시 선택하거나 연결을 해제하세요."
        case .cancelled, .sendCancelled: return "요청을 취소했습니다. 모니터를 다시 선택할 수 있습니다."
        case .disconnected, .peerChanged: return "Mac 연결이 바뀌었습니다. 현재 Mac 목록에서 다시 선택하세요."
        case .foregroundRequired: return "앱을 앞에 연 뒤 다시 선택하세요."
        case .windowRequired, .admissionChanged: return "현재 조작 창에서 다시 선택하세요."
        case .staleScope, .inventoryChanged, .sourceChanged: return "Mac 화면 정보가 바뀌었습니다. 최신 목록에서 다시 선택하세요."
        case .conflictingID: return "같은 요청 번호의 내용이 달라 요청을 거절했습니다. 다시 선택하세요."
        case .busy: return "진행 중인 선택을 기다리거나 취소하세요."
        case .legacyOnly: return "이전 Mac 호스트에서는 기존 전체 화면 동작을 사용하세요."
        case .unsupportedCapability: return "이 Mac의 모니터 선택 버전은 지원되지 않습니다."
        case .invalidInventory, .unknownDisplay: return "유효한 모니터 목록이 없습니다. Mac 연결 상태를 확인하세요."
        case .catalogRequired: return "Mac의 모니터 목록을 기다리고 있습니다."
        case .ready, nil:
            if client.visionDisplaySelection.catalog?.capability != 1 {
                return "이 Mac에서 모니터 선택을 사용할 수 없습니다."
            }
            return client.visionDisplaySelection.choices.isEmpty ? "유효한 모니터 목록을 기다리고 있습니다." : "Mac이 보낸 이름과 크기를 표시합니다."
        }
    }
}
