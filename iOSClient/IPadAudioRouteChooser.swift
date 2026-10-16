#if os(iOS)
import SwiftUI
import AVFoundation
import AVKit

struct IPadAudioRouteChooser: View {
    @ObservedObject var client: StreamClient
    @Environment(\.dismiss) private var dismiss
    @State private var selection = IPadAudioRoutePolicy.Selection()
    @State private var context: IPadAudioRoutePolicy.Context?
    @State private var problem: String?
    @State private var inputPorts = "iPad가 선택한 마이크"
    @State private var outputPorts = "iPad가 선택한 출력 장치"

    private var mac: String { client.macName.isEmpty ? "연결된 Mac" : client.macName }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("연결된 Mac과 이 iPad 사이의 입력과 출력을 각각 선택하세요. 전송과 재생은 ‘선택 적용’을 눌러 변경합니다.")
                }
                Section {
                    Picker("입력 소스", selection: $selection.input) {
                        ForEach(client.audioRouteCapabilities.inputs) { input in
                            Text(input.title).tag(input)
                        }
                    }
                    .accessibilityIdentifier("audioRouteInput")
                    LabeledContent("전달 대상", value: mac)
                    LabeledContent("현재 iPad 입력", value: inputPorts)
                    if !client.audioRouteCapabilities.microphone {
                        Text("현재 연결에서는 iPad 마이크 전송을 지원하지 않습니다.")
                            .foregroundStyle(.secondary)
                    }
                    if let cleanup = client.microphoneCleanupProblem {
                        Text(cleanup).foregroundStyle(.red)
                    }
                } header: { Text("마이크 입력") }
                Section {
                    LabeledContent("소리 소스", value: mac)
                    Picker("출력 대상", selection: $selection.output) {
                        ForEach(client.audioRouteCapabilities.outputs) { output in
                            Text(output.title).tag(output)
                        }
                    }
                    .accessibilityIdentifier("audioRouteOutput")
                    LabeledContent("현재 iPad 출력", value: outputPorts)
                    if client.audioRouteCapabilities.playback {
                        HStack {
                            Text("시스템 출력 장치 선택")
                            Spacer()
                            IPadSystemOutputPicker()
                                .frame(width: 44, height: 44)
                        }
                    } else {
                        Text("현재 연결에서는 Mac 오디오 재생을 지원하지 않습니다.")
                            .foregroundStyle(.secondary)
                    }
                } header: { Text("오디오 출력") }
                Section {
                    Text("실제 마이크와 출력 장치는 iPad의 현재 오디오 경로를 사용합니다. 일부 Bluetooth 장치는 입력을 바꾸면 출력도 함께 바뀝니다.")
                        .foregroundStyle(.secondary)
                    Text("이 화면을 닫거나 연결이 바뀌어도 마이크와 재생을 자동으로 켜지 않습니다.")
                        .foregroundStyle(.secondary)
                    if let problem { Text(problem).foregroundStyle(.red).accessibilityIdentifier("audioRouteProblem") }
                }
                Section {
                    Button("선택 적용") {
                        do {
                            try client.applyAudioRoutes(selection, context: context)
                            dismiss()
                        } catch { problem = error.localizedDescription }
                    }
                    .disabled(context == nil)
                    .accessibilityIdentifier("applyAudioRoutes")
                    Button("선택 취소", role: .cancel) { dismiss() }
                }
            }
            .navigationTitle("오디오 입력·출력")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            context = client.audioRouteContext
            selection = client.audioRouteSelection
            readPorts()
        }
        .onChange(of: client.audioRouteContext) { _, next in
            context = next
            selection = IPadAudioRoutePolicy.Selection()
            problem = "연결이나 화면이 바뀌어 선택을 초기화했습니다. 다시 선택하세요."
        }
        .onChange(of: client.audioRouteCapabilities) { _, next in
            if !next.microphone { selection.input = .off }
            if !next.playback { selection.output = .off }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in readPorts() }
    }

    private func readPorts() {
        let route = AVAudioSession.sharedInstance().currentRoute
        inputPorts = route.inputs.isEmpty ? "iPad가 선택한 마이크" : route.inputs.map(\.portName).joined(separator: ", ")
        outputPorts = route.outputs.isEmpty ? "iPad가 선택한 출력 장치" : route.outputs.map(\.portName).joined(separator: ", ")
    }
}

private struct IPadSystemOutputPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .white
        view.accessibilityLabel = "시스템 출력 장치 선택"
        view.accessibilityHint = "iPad가 지원하는 출력 경로를 표시합니다."
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
