import SwiftUI

private struct IPadAppUpdateActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openIPadAppUpdate: () -> Void {
        get { self[IPadAppUpdateActionKey.self] }
        set { self[IPadAppUpdateActionKey.self] = newValue }
    }
}

struct IPadAppUpdateView: View {
    @ObservedObject var controller: IPadAppUpdateController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section("현재 실행 중인 앱") {
                    LabeledContent("버전", value: controller.installed.version.isEmpty ? "미확인" : controller.installed.version)
                    LabeledContent("빌드", value: controller.installed.build.isEmpty ? "미확인" : controller.installed.build)
                    source("소스 커밋", value: controller.installed.sourceCommit)
                    source("소스 트리", value: controller.installed.sourceTree)
                }
                Section("공식 업데이트") {
                    Text(controller.message)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("iPadAppUpdateStatus")
                    if controller.isChecking { ProgressView("업데이트 확인 중") }
                    Button("업데이트 확인 및 설치", systemImage: "arrow.down.app") {
                        controller.checkAndInstall { url in
                            await withCheckedContinuation { continuation in
                                openURL(url) { accepted in continuation.resume(returning: accepted) }
                            }
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(!controller.canCheck)
                    .accessibilityHint("최신 승인을 새로 조회한 뒤 Apple 설치 화면을 엽니다. 설치 확인은 OS에서 진행합니다.")
                    .accessibilityIdentifier("iPadAppUpdateInstall")
                    if controller.canCancel {
                        Button("작업 대기 취소", role: .cancel) { controller.cancel() }.frame(minHeight: 44)
                    }
                    Text("다운로드·패키지 서명 검증·설치는 Apple이 담당합니다. Apple 화면이 열려도 설치 완료를 뜻하지 않습니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("TestFlight 초대와 CCR 앱 ID의 관계는 승인 발행자가 확인합니다. 앱은 URL만으로 그 관계를 독자 검증하지 않습니다. 참여 자격·최종 빌드·설치는 Apple에서 확인합니다. 개발 배포채널은 지원하지 않습니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("iPad 앱 업데이트")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { controller.cancel(); dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { controller.readback() }
        .onDisappear { controller.cancel() }
        .onChange(of: controller.state) { _, _ in
            AccessibilityNotification.Announcement(controller.message).post()
        }
    }

    private func source(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            Text(IPadAppUpdatePolicy.isSHA(value) ? value : "미확인")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
