#if os(iOS)
import SwiftUI
import AVFoundation
import AVKit
import StreamProtocol

struct IPadAudioRouteChooser: View {
    @ObservedObject var client: StreamClient
    @Environment(\.dismiss) private var dismiss
    @State private var selection = IPadAudioRoutePolicy.Selection()
    @State private var context: IPadAudioRoutePolicy.Context?
    @State private var problem: String?
    @State private var macProblem: String?
    @State private var macInputUID = ""
    @State private var macOutputUID = ""
    @State private var macCatalogToken: MacAudioRouteSession.CatalogToken?
    @State private var macCatalogWaitExpired = false
    @State private var inputPorts = "iPad가 선택한 마이크"
    @State private var outputPorts = "iPad가 선택한 출력 장치"

    private var mac: String { client.macName.isEmpty ? "연결된 Mac" : client.macName }

    var body: some View {
        NavigationStack {
            Form {
                macRoutes
                Section {
                    Text("iPad 마이크 전송과 Mac 소리 재생은 이 iPad의 별도 동의입니다. Mac 시스템 기본 장치 선택과 관계없이 각각 적용합니다.")
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
                    LabeledContent("iPad 마이크 상태", value: microphoneStatus)
                    if !client.audioRouteCapabilities.microphone {
                        Text("현재 연결에서는 iPad 마이크 전송을 지원하지 않습니다.")
                            .foregroundStyle(.secondary)
                    }
                    if let cleanup = client.microphoneCleanupProblem {
                        Text(cleanup).foregroundStyle(.red)
                    }
                } header: { Text("iPad 마이크 전송") }
                Section {
                    LabeledContent("소리 소스", value: mac)
                    Picker("출력 대상", selection: $selection.output) {
                        ForEach(client.audioRouteCapabilities.outputs) { output in
                            Text(output.title).tag(output)
                        }
                    }
                    .accessibilityIdentifier("audioRouteOutput")
                    LabeledContent("현재 iPad 출력", value: outputPorts)
                    LabeledContent("Mac 소리 재생 상태", value: playbackStatus)
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
                } header: { Text("iPad 오디오 재생") }
                Section {
                    Text("실제 마이크와 출력 장치는 iPad의 현재 오디오 경로를 사용합니다. 일부 Bluetooth 장치는 입력을 바꾸면 출력도 함께 바뀝니다.")
                        .foregroundStyle(.secondary)
                    Text("이 화면을 닫거나 연결이 바뀌어도 마이크와 재생을 자동으로 켜지 않습니다.")
                        .foregroundStyle(.secondary)
                    if let problem { Text(problem).foregroundStyle(.red).accessibilityIdentifier("audioRouteProblem") }
                }
                Section {
                    Button("iPad 전송·재생 동의 적용") {
                        do {
                            try client.applyAudioRoutes(selection, context: context)
                            problem = nil
                        } catch { problem = error.localizedDescription }
                    }
                    .disabled(context == nil)
                    .accessibilityIdentifier("applyAudioRoutes")
                    Button("닫기") { dismiss() }
                        .disabled(client.macAudioRoutes.pending != nil)
                }
            }
            .navigationTitle("오디오 입력·출력")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                        .disabled(client.macAudioRoutes.pending != nil)
                }
            }
        }
        .interactiveDismissDisabled(client.macAudioRoutes.pending != nil)
        .preferredColorScheme(.dark)
        .onAppear {
            context = client.audioRouteContext
            selection = client.audioRouteSelection
            macCatalogToken = client.macAudioRoutes.catalogToken
            readPorts()
            client.fetchMacAudioRoutes()
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
        .onChange(of: client.macAudioRoutes.peer) { _, _ in
            macInputUID = ""
            macOutputUID = ""
            macCatalogToken = nil
            macProblem = nil
            macCatalogWaitExpired = false
        }
        .onChange(of: client.macAudioRoutes.catalogToken) { _, next in
            macInputUID = ""
            macOutputUID = ""
            macCatalogToken = next
        }
        .onChange(of: client.macAudioRoutes.pending?.requestID) { previous, current in
            if previous != nil && current == nil {
                macInputUID = ""
                macOutputUID = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in readPorts() }
        .task(id: client.macAudioRoutes.peer) {
            macCatalogWaitExpired = false
            guard client.macAudioRoutes.peer != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled && client.macAudioRoutes.state == nil { macCatalogWaitExpired = true }
        }
    }

    private var macRoutes: some View {
        Section {
            Text("Mac 전체의 기본 입력과 출력을 각각 바꿉니다. 목록에는 Mac의 물리 장치만 표시됩니다.")
                .foregroundStyle(.secondary)
            if client.authenticatedMacAudioRoutePeer == nil {
                Text("이 연결에서는 인증된 Mac 오디오 장치 목록을 사용할 수 없습니다.")
                    .foregroundStyle(.secondary)
            } else if let state = client.macAudioRoutes.state, state.available {
                LabeledContent("현재 Mac 기본 입력", value: defaultLabel(state.defaults.inputUID, in: state))
                LabeledContent("현재 Mac 기본 출력", value: defaultLabel(state.defaults.outputUID, in: state))
                Picker("Mac 시스템 입력", selection: $macInputUID) {
                    Text("현재 기본값 유지").tag("")
                    ForEach(state.endpoints.filter(\.input), id: \.uid) { endpoint in
                        Text(endpoint.name).tag(endpoint.uid)
                    }
                }
                .accessibilityIdentifier("macAudioInput")
                Picker("Mac 시스템 출력", selection: $macOutputUID) {
                    Text("현재 기본값 유지").tag("")
                    ForEach(state.endpoints.filter(\.output), id: \.uid) { endpoint in
                        Text(endpoint.name).tag(endpoint.uid)
                    }
                }
                .accessibilityIdentifier("macAudioOutput")
                Button("Mac 기본 장치 적용") {
                    do {
                        guard let macCatalogToken else { throw MacAudioRouteSession.Problem.catalogChanged }
                        try client.selectMacAudioRoutes(inputUID: macInputUID.isEmpty ? nil : macInputUID,
                                                        outputUID: macOutputUID.isEmpty ? nil : macOutputUID,
                                                        displayed: macCatalogToken)
                        macProblem = nil
                    } catch { macProblem = error.localizedDescription }
                }
                .disabled(client.macAudioRoutes.pending != nil || macCatalogToken == nil || !macHasChange(state))
                .accessibilityIdentifier("applyMacAudioRoutes")
            } else {
                Text(client.macAudioRoutes.state?.available == false
                     ? "Mac 오디오 장치 정보를 읽을 수 없습니다."
                     : macCatalogWaitExpired
                     ? "Mac 장치 목록을 받지 못했습니다. 현재 Mac의 Sill 버전에서 지원하지 않을 수 있습니다."
                     : "Mac 오디오 장치 목록을 기다리는 중입니다.")
                    .foregroundStyle(.secondary)
            }
            Button("Mac 장치 새로고침") { client.fetchMacAudioRoutes() }
                .disabled(client.authenticatedMacAudioRoutePeer == nil || client.macAudioRoutes.pending != nil)
                .accessibilityIdentifier("fetchMacAudioRoutes")
            if let outcome = client.macAudioRoutes.outcome {
                Text(outcome.title)
                    .foregroundStyle(outcome.isSuccess ? Color.secondary : Color.red)
                    .accessibilityIdentifier("macAudioRouteResult")
            }
            if let macProblem { Text(macProblem).foregroundStyle(.red) }
        } header: { Text("Mac 시스템 기본 장치") }
    }

    private func defaultLabel(_ uid: String?, in state: AudioRouteState) -> String {
        guard let uid else { return "확인할 수 없음" }
        return state.endpoints.first(where: { $0.uid == uid })?.name ?? "목록 밖 장치 (\(uid))"
    }

    private func macHasChange(_ state: AudioRouteState) -> Bool {
        (!macInputUID.isEmpty && macInputUID != state.defaults.inputUID) ||
        (!macOutputUID.isEmpty && macOutputUID != state.defaults.outputUID)
    }

    private var microphoneStatus: String {
        switch client.microphonePhase {
        case .unavailable: "사용할 수 없음"
        case .off: "꺼짐"
        case .requesting: "Mac 동의 대기 중"
        case .capturing: "마이크 준비 중"
        case .live: "전송 중"
        case .stopping: "중지 중"
        case .failed(let reason): "실패: \(reason)"
        }
    }

    private var playbackStatus: String {
        switch client.remoteAudioStatus {
        case .unavailable: "사용할 수 없음"
        case .off: "꺼짐"
        case .requesting: "Mac 동의 대기 중"
        case .listening: "재생 중"
        case .failed(let reason): "실패: \(reason)"
        }
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
