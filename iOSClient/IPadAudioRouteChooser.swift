#if os(iOS)
import SwiftUI
import AVFoundation
import AVKit
import StreamProtocol

struct IPadAudioRouteChooser: View {
    @ObservedObject var client: StreamClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = IPadAudioRoutePolicy.Selection()
    @State private var selectionEdited = false
    @State private var context: IPadAudioRoutePolicy.Context?
    @State private var acknowledgedMac: IPadAudioRouteAcknowledgments.Identity?
    @State private var problem: String?
    @State private var operation: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var preparingCall = false
    @State private var devicesPresented = false
    @State private var macProblem: String?
    @State private var macCatalogWaitExpired = false
    @State private var inputPorts = "입력 경로 미확인"
    @State private var outputPorts = "출력 경로 미확인"

    private var callTarget: IPadCallTarget { client.providerCall.target }
    private var busy: Bool {
        operationID != nil || client.audioRouteAuthorization != nil || client.providerCall.pending != nil ||
        client.macAudioRoutes.pending != nil || [.submitting, .quiescing].contains(client.audioForwardingPhase)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if preparingCall {
                        ProgressView("통화 준비 중…")
                        Button("준비 취소", role: .cancel) { cancelOperation(stopPreparingAudio: true) }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("iPadProviderCallCancelPreparation")
                    } else if client.providerCall.selectedActiveCall != nil {
                        Button(role: .destructive) {
                            client.performIPadProviderCall(.stop, target: callTarget)
                        } label: {
                            Label("통화 종료", systemImage: "phone.down.fill")
                                .font(.title2).frame(maxWidth: .infinity, minHeight: 64)
                        }
                        .disabled(busy || !client.iPadProviderCanStop)
                        .accessibilityIdentifier("iPadProviderCallStop")
                    } else {
                        Button(action: startCall) {
                            Label("통화 시작", systemImage: "phone.fill")
                                .font(.title2).frame(maxWidth: .infinity, minHeight: 64)
                        }
                        .disabled(busy || !client.iPadProviderCanPrepareCall)
                        .accessibilityIdentifier("iPadProviderCallStart")
                    }
                    if callTarget == .grokBot {
                        Text("Grok Bot 통화 시작·종료는 아직 지원하지 않습니다.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("iPadGrokBotCallUnsupported")
                    } else if client.providerCall.pending != nil || client.providerCall.selectedResult != nil ||
                                !client.providerCall.targetSupported {
                        Text(client.providerCall.message)
                            .accessibilityIdentifier("iPadProviderCallStatus")
                    }
                    if client.providerCall.request != nil && client.providerCall.pending == nil &&
                        (client.providerCall.selectedResult?.status == .unknown || client.providerCall.canManuallyQuery) {
                        Button("이전 통화 요청 확인") { client.checkPreviousIPadProviderCall(target: callTarget) }
                            .disabled(busy || !client.iPadProviderCanCheckPrevious)
                            .accessibilityIdentifier("iPadProviderCallCheckPrevious")
                    }
                    if let history = client.providerCall.historicalMessage {
                        Text(history).foregroundStyle(.secondary)
                            .accessibilityIdentifier("iPadProviderCallHistoricalResult")
                    }
                }
                Section {
                    Toggle(isOn: Binding(get: { selection.input != .off }, set: {
                        selectionEdited = true
                        selection.input = $0 ? .iPadMicrophone : .off
                        applySelection()
                    })) { Label("마이크 사용", systemImage: selection.input == .off ? "mic.slash" : "mic") }
                        .disabled(busy || context == nil || (selection.input == .off && !client.audioRouteCapabilities.microphone))
                        .accessibilityIdentifier("iPadCallMicrophone")
                    Toggle(isOn: Binding(get: { selection.output != .off }, set: {
                        selectionEdited = true
                        selection.output = $0 ? .iPadPlayback : .off
                        applySelection()
                    })) { Label("스피커 사용", systemImage: selection.output == .off ? "speaker.slash" : "speaker.wave.2") }
                        .disabled(busy || context == nil || (selection.output == .off && !client.audioRouteCapabilities.playback))
                        .accessibilityIdentifier("iPadCallSpeaker")
                    routeStatus
                    Button { devicesPresented = true } label: {
                        Label("기기", systemImage: "hifispeaker")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("iPadCallDevices")
                }
            }
            .navigationTitle("통화")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기", action: close) }
            }
            .sheet(isPresented: $devicesPresented) { deviceSheet }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            context = client.audioRouteContext
            acknowledgedMac = client.audioRoutePresentation?.identity
            selection = client.audioRouteSelection
            selectionEdited = selection != .init() || client.providerCall.activeCall != nil
            readPorts()
        }
        .onDisappear {
            cancelOperation(stopPreparingAudio: true)
        }
        .onChange(of: client.audioRouteContext) { _, next in
            cancelOperation(stopPreparingAudio: false)
            context = next
            acknowledgedMac = client.audioRouteTrustedMac
            selection = client.audioRouteSelection
            selectionEdited = selection != .init() || client.providerCall.activeCall != nil
            problem = "연결이나 화면이 바뀌었습니다. 현재 연결에서 다시 시작하세요."
        }
        .onChange(of: client.providerCall.target) { _, _ in cancelOperation(stopPreparingAudio: true) }
        .onChange(of: client.providerCallConnection) { _, _ in cancelOperation(stopPreparingAudio: true) }
        .onChange(of: scenePhase) { _, next in
            if next != .active { cancelOperation(stopPreparingAudio: true) }
        }
        .onChange(of: client.audioForwardingPhase) { _, next in
            if next == .blocked && preparingCall {
                cancelOperation(stopPreparingAudio: true)
                problem = "음성 연결 준비가 중단되어 통화를 시작하지 않았습니다."
            }
        }
        .onChange(of: client.macAudioRoutes.peer) { _, _ in
            macProblem = nil
            macCatalogWaitExpired = false
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in readPorts() }
    }

    @ViewBuilder private var routeStatus: some View {
        if operationID != nil && !preparingCall { ProgressView("입출력 변경 중…") }
        if client.audioRouteAuthorization != nil { ProgressView("마이크 권한 확인 중…") }
        switch client.microphonePhase {
        case .authorizing, .requesting, .capturing, .stopping:
            Text("마이크 연결 처리 중…").foregroundStyle(.secondary)
        case .failed(let reason): Text(reason).foregroundStyle(.red)
        default: EmptyView()
        }
        switch client.remoteAudioStatus {
        case .requesting, .starting: Text("스피커 연결 처리 중…").foregroundStyle(.secondary)
        case .failed(let reason): Text(reason).foregroundStyle(.red)
        default: EmptyView()
        }
        if let cleanup = client.microphoneCleanupProblem { Text(cleanup).foregroundStyle(.red) }
        if let problem { Text(problem).foregroundStyle(.red).accessibilityIdentifier("audioRouteProblem") }
        if !client.connected {
            Text("Mac 연결이 끊어졌습니다.").foregroundStyle(.secondary)
        } else if !client.audioRouteCapabilities.microphone || !client.audioRouteCapabilities.playback ||
                    client.audioForwardingPhase == .blocked {
            if let reason = client.audioRoutePlaybackUnavailableReason { Text(reason).foregroundStyle(.secondary) }
        }
    }

    private var deviceSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("통화 대상", selection: Binding(get: { callTarget },
                        set: { _ = client.selectIPadProviderCallTarget($0) })) {
                        ForEach(IPadCallTarget.allCases) { target in Text(target.title).tag(target) }
                    }
                    .disabled(busy || !client.providerCall.canChangeTarget)
                    .accessibilityIdentifier("iPadCallTarget")
                }
                Section("이 iPad") {
                    LabeledContent("마이크", value: inputPorts)
                    LabeledContent("스피커·연결된 출력", value: outputPorts)
                    HStack {
                        Text("출력 기기")
                        Spacer()
                        IPadSystemOutputPicker().frame(width: 44, height: 44)
                    }
                    .disabled(busy)
                }
                macRoutes
            }
            .navigationTitle("기기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { devicesPresented = false } }
            }
            .onAppear { client.fetchMacAudioRoutes() }
            .task(id: client.macAudioRoutes.peer) {
                macCatalogWaitExpired = false
                guard client.macAudioRoutes.peer != nil else { return }
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled && client.macAudioRoutes.state == nil { macCatalogWaitExpired = true }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var macRoutes: some View {
        Section {
            if client.authenticatedMacAudioRoutePeer == nil {
                Text("이 연결에서는 Mac 장치 목록을 사용할 수 없습니다.").foregroundStyle(.secondary)
            } else if let state = client.macAudioRoutes.state, state.available {
                let displayed = MacAudioRouteSession.CatalogToken(revision: state.revision, defaults: state.defaults)
                Picker("입력", selection: Binding(get: { state.defaults.inputUID ?? "" }, set: {
                    selectMacDevice(inputUID: $0, outputUID: nil, displayed: displayed)
                })) {
                    if state.defaults.inputUID == nil || !state.endpoints.contains(where: { $0.uid == state.defaults.inputUID && $0.input }) {
                        Text("현재 입력 미확인").tag(state.defaults.inputUID ?? "")
                    }
                    ForEach(state.endpoints.filter(\.input), id: \.uid) { Text($0.name).tag($0.uid) }
                }
                .disabled(busy || client.macAudioRoutes.catalogToken != displayed)
                .accessibilityIdentifier("macAudioInput")
                Picker("출력", selection: Binding(get: { state.defaults.outputUID ?? "" }, set: {
                    selectMacDevice(inputUID: nil, outputUID: $0, displayed: displayed)
                })) {
                    if state.defaults.outputUID == nil || !state.endpoints.contains(where: { $0.uid == state.defaults.outputUID && $0.output }) {
                        Text("현재 출력 미확인").tag(state.defaults.outputUID ?? "")
                    }
                    ForEach(state.endpoints.filter(\.output), id: \.uid) { Text($0.name).tag($0.uid) }
                }
                .disabled(busy || client.macAudioRoutes.catalogToken != displayed)
                .accessibilityIdentifier("macAudioOutput")
            } else {
                Text(client.macAudioRoutes.state?.available == false ? "Mac 장치 목록을 읽을 수 없습니다."
                     : macCatalogWaitExpired ? "Mac 장치 목록을 받지 못했습니다." : "Mac 장치 목록을 확인 중입니다.")
                    .foregroundStyle(.secondary)
            }
            if client.macAudioRoutes.pending != nil { ProgressView("Mac 장치 변경 중…") }
            if let outcome = client.macAudioRoutes.outcome, !outcome.isSuccess {
                Text(outcome.title).foregroundStyle(.secondary).accessibilityIdentifier("macAudioRouteResult")
            }
            if let macProblem { Text(macProblem).foregroundStyle(.red) }
            if macCatalogWaitExpired || macProblem != nil || client.macAudioRoutes.state?.available == false ||
                (client.macAudioRoutes.outcome != nil && client.macAudioRoutes.outcome?.isSuccess == false && client.macAudioRoutes.pending == nil) {
                Button("Mac 장치 다시 확인") { client.fetchMacAudioRoutes() }
                    .disabled(busy || client.authenticatedMacAudioRoutePeer == nil)
                    .accessibilityIdentifier("fetchMacAudioRoutes")
            }
        } header: { Text("Mac 기본 장치") }
    }

    private func selectMacDevice(inputUID: String?, outputUID: String?, displayed: MacAudioRouteSession.CatalogToken) {
        guard !busy else { return }
        do {
            try client.selectMacAudioRoutes(inputUID: inputUID, outputUID: outputUID, displayed: displayed)
            macProblem = nil
        } catch { macProblem = error.localizedDescription }
    }

    private func startCall() {
        guard !busy, client.iPadProviderCanPrepareCall else { return }
        let chosen = selectionEdited || selection != .init() ? selection
            : IPadAudioRoutePolicy.Selection(input: .iPadMicrophone, output: .iPadPlayback)
        let displayed = context, target = callTarget
        selection = chosen
        client.acknowledgeAudioRoutes(identity: acknowledgedMac, context: displayed)
        let id = UUID()
        operationID = id
        preparingCall = true
        problem = nil
        operation = Task { @MainActor in
            defer {
                if operationID == id { operationID = nil; operation = nil; preparingCall = false }
            }
            do {
                try await client.prepareAndStartIPadProviderCall(chosen, context: displayed, target: target)
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                problem = error.localizedDescription
            }
        }
    }

    private func applySelection() {
        guard !busy else { return }
        let chosen = selection, displayed = context
        client.acknowledgeAudioRoutes(identity: acknowledgedMac, context: displayed)
        let id = UUID()
        operationID = id
        problem = nil
        operation = Task { @MainActor in
            defer { if operationID == id { operationID = nil; operation = nil } }
            do {
                try Task.checkCancellation()
                try await client.applyAudioRoutes(chosen, context: displayed)
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                selection = client.audioRouteSelection
                problem = error.localizedDescription
            }
        }
    }

    private func cancelOperation(stopPreparingAudio: Bool) {
        let wasPreparing = preparingCall
        operation?.cancel()
        operation = nil
        operationID = nil
        preparingCall = false
        if client.audioRouteAuthorization?.context == context { client.audioRouteAuthorization = nil }
        if stopPreparingAudio && wasPreparing && context == client.audioRouteContext {
            client.cancelDesiredAudioRequest()
        }
    }

    private func close() {
        cancelOperation(stopPreparingAudio: true)
        client.acknowledgeAudioRoutes(identity: acknowledgedMac, context: context)
        dismiss()
    }

    private func readPorts() {
        let route = AVAudioSession.sharedInstance().currentRoute
        inputPorts = route.inputs.isEmpty ? "입력 경로 미확인" : route.inputs.map(\.portName).joined(separator: ", ")
        outputPorts = route.outputs.isEmpty ? "출력 경로 미확인" : route.outputs.map(\.portName).joined(separator: ", ")
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
