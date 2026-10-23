import SwiftUI
import StreamProtocol

@main
struct SillVisionApp: App {
    init() {
        guard !VisionReleaseTestContext.isTestBundle || VisionReleaseTestContext.current != nil else { return }
        VisionReleaseRuntimeWriter.write()
    }

    var body: some Scene {
        WindowGroup(id: "mac") {
            if VisionReleaseTestContext.isTestBundle && VisionReleaseTestContext.current == nil {
                Text("격리 테스트 실행 정보가 없거나 일치하지 않습니다.")
            } else {
                SillVisionWindow()
            }
        }
        .defaultSize(width: 1280, height: 800)
    }
}

private struct SillVisionWindow: View {
    @StateObject private var session = VisionAppSession()
    @State private var window = UUID()

    var body: some View {
        Group {
            if let lease = session.windowLease, lease.window == window {
                SillVisionWorkspace(session: session, lease: lease).id(lease.admission)
            }
            else {
                VStack(spacing: 16) {
                    ProgressView("Mac 연결을 준비하고 있습니다.")
                }.padding(30)
            }
        }
        .onAppear { session.claim(window) }
        .onDisappear { session.release(window) }
    }
}

struct SillVisionWorkspace: View {
    @ObservedObject var session: VisionAppSession
    let lease: VisionWindowLease
    @ObservedObject private var client: StreamClient
    @Environment(\.scenePhase) private var phase
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var input: VisionInputSession
    @State private var keyboardShown = false
    @State private var keysShown = false
    @State private var code = ""
    @State private var address = ""
    @State private var addMac = false
    @State private var recoveryShown = false
    @State private var changingSource = false
    @State private var transitions = VisionTransition()
    @State private var inputSuspended = false
    @State private var textDraft: VisionTextDraft<StreamClient.VisionTextTarget>?
    @State private var draftShown = false
    @AppStorage("ccrVisionAudioOfferAnswered") private var audioOfferAnswered = false
    @State private var audioOfferShown = false
    @State private var audioOfferScope: VisionAudioScope?
    @State private var displayChooserShown = false
    @State private var macAudioShown = false
    @State private var macAudioOfferShown = false
    @State private var controlEventsShown = false
    @State private var testDestinationsShown = false
    @StateObject private var testDestinationStores = VisionTestDestinationStores()

    init(session: VisionAppSession, lease: VisionWindowLease) {
        self.session = session
        self.lease = lease
        self.client = session.client
        self.input = session.input
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(client.macName.isEmpty ? "CCR Sill" : client.macName).font(.headline)
                Spacer()
                Button("작업 상태") {
                    withWindowOwnership {
                        guard phase == .active, !draftShown, !transitions.isPending else { return }
                        keysShown = false
                        controlEventsShown = true
                        updateInputAdmission()
                        releaseInput()
                    }
                }
                .disabled(phase != .active || draftShown || recoveryShown || changingSource || testDestinationsShown ||
                          displayChooserShown || macAudioModalShown || audioOfferShown || transitions.isPending)
                .accessibilityHint("Codex와 Cursor의 원본 세션·실행 상태를 읽기 전용 패널에서 확인합니다.")
                Button("Mac 창 추가") { openWindow(id: "mac") }
                    .accessibilityHint("현재 창을 유지하고 Mac 화면을 사용할 새 창을 엽니다.")
                Text(session.message).font(.caption).lineLimit(2)
                if client.connected {
                    Menu("오디오") {
                        Button("Mac 오디오 장치") {
                            openMacAudioChooser()
                        }
                        .disabled(!audioControlsAllowed)
                        Button(client.visionAudio.presentation.phase.grant != nil || client.visionPlaybackDesired
                               ? "Mac 소리 중지" : "Mac 소리 켜기") {
                            withWindowOwnership {
                                if client.visionAudio.presentation.phase.grant != nil || client.visionPlaybackDesired {
                                    client.setVisionAudioDesired(false, direction: .playback)
                                } else if audioControlsAllowed { client.setVisionAudioDesired(true, direction: .playback) }
                            }
                        }
                        .disabled(!client.visionPlaybackDesired && client.visionAudio.presentation.phase.grant == nil &&
                                  (!audioControlsAllowed || !client.visionAudioIntentContext.admitted))
                        Text(client.visionAudioPrivacyMessage)
                        Text("마이크는 아래 마이크 전송 설정에서 확인하세요.")
                    }
                    Button("프로젝트 테스트 화면") {
                        withWindowOwnership {
                            guard phase == .active, !transitions.isPending else { return }
                            client.reconcileVisionTestDestinationAuthentication()
                            clearDraft()
                            keysShown = false
                            testDestinationsShown = true
                            updateInputAdmission()
                            releaseInput()
                        }
                    }
                    .accessibilityHint("연결된 Mac에서 등록한 테스트 화면을 이 기기에서 엽니다.")
                    Button("연결 해제") { requestTransition(.disconnect) }
                }
            }
            if inputSuspended {
                Text("Mac의 입력 해제 수신을 확인하지 못해 원격 입력을 중지했습니다.").foregroundStyle(.orange)
            }
            if client.connected {
                if let failure = client.visionSourceSelectionFailure {
                    Text(failure).foregroundStyle(.orange).accessibilityLabel(failure)
                }
                screen
                controls
                Text("한 번 집기: 클릭 · 빠르게 두 번 집기: 더블클릭 · 집고 이동: 가로·세로 스크롤 · 유지했다 놓기: 오른쪽 클릭\n두 손 벌리기·모으기: 화면 확대·축소 · 두 손 좌우 회전 후 놓기: Mac 모니터 한 칸 전환\n보조 키를 선택하고 길게 집은 뒤 이동하면 드래그합니다.")
                    .font(.caption).multilineTextAlignment(.center)
                HStack {
                    Button("전체 화면", action: openDisplayChooser)
                        .accessibilityHint("연결된 Mac의 모니터를 선택합니다. 이전 호스트는 기존 전체 화면 동작을 사용합니다.")
                    if client.visionDisplaySelection.pending != nil {
                        Button("모니터 요청 취소") { withWindowOwnership { client.cancelVisionDisplaySelection() } }
                    } else if client.visionDisplaySelection.inputBlocked && !displayChooserShown {
                        Text("입력 중지 · 모니터를 다시 선택하거나 연결을 해제하세요.").font(.caption)
                    }
                }
                HStack {
                    Button("누른 입력 해제") { withWindowOwnership { input.releaseAll() } }
                        .accessibilityHint("이 Vision 앱이 누른 키와 드래그를 해제합니다.")
                    Spacer()
                    if input.moving { Text("연결 경로 전환 중").font(.caption) }
                    else if client.visionInputBinding.isModern && !client.visionInputBinding.isConfirmed {
                        Text("현재 Mac 화면의 표시 준비를 기다리는 중입니다.").font(.caption)
                    }
                    else if client.visionInputBinding.isLegacy {
                        Text("이전 Mac 호환 모드입니다. 화면 세대 확인은 지원되지 않습니다.").font(.caption)
                    }
                    else if client.visionInputBinding == .awaitingCatalog {
                        Text("Mac 화면 정보를 기다리는 중입니다. 입력은 확인 후 사용할 수 있습니다.").font(.caption)
                    }
                }
                VisionAudioControls(client: client, audio: client.visionAudio,
                                    allowStart: audioControlsAllowed,
                                    admit: withWindowOwnership)
                VisionMicrophoneControls(client: client,
                                         allowStart: audioControlsAllowed,
                                         admit: withWindowOwnership)
                HStack {
                    Button("통화 시작") {
                        withWindowOwnership { if audioControlsAllowed { client.performVisionProviderCall(.start) } }
                    }
                    .disabled(!audioControlsAllowed || !client.visionProviderCanStart)
                    Button("통화 종료") {
                        withWindowOwnership { if audioControlsAllowed { client.performVisionProviderCall(.stop) } }
                    }
                    .disabled(!audioControlsAllowed || !client.visionProviderCanStop)
                    Text(client.visionProviderCall.message).font(.caption)
                }
            } else {
                hosts
            }
            #if DEBUG && targetEnvironment(simulator)
            if let peer = session.remotePeer { VisionReleaseRemoteStatus(peer: peer) }
            #endif
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 500)
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            if session.owns(lease), client.connected, client.active != .none, client.visionSentrySnapshot.available {
                VisionSentryOrnament(snapshot: client.visionSentrySnapshot,
                                     allowActivation: phase == .active && !transitions.isPending) {
                    withWindowOwnership {
                        guard phase == .active, !transitions.isPending else { return }
                        client.activateVisionSentry()
                    }
                }
            }
        }
        .task {
            guard session.owns(lease) else { return }
            session.setScenePhase(phase); updateInputAdmission()
        }
        .onChange(of: inputAllowed) { _, _ in updateInputAdmission() }
        .onChange(of: recoveryShown) { _, _ in updateInputAdmission() }
        .onChange(of: changingSource) { _, _ in updateInputAdmission() }
        .onChange(of: macAudioModalShown) { _, shown in
            if shown {
                audioOfferShown = false
                audioOfferScope = nil
                keysShown = false
            }
            updateInputAdmission()
        }
        .onChange(of: audioControlsAllowed) { _, allowed in
            if !allowed {
                audioOfferShown = false; audioOfferScope = nil
                macAudioShown = false; macAudioOfferShown = false
            } else { offerMacAudioChooser() }
        }
        .onReceive(client.visionMacAudioRoutes.$scope) { scope in
            if scope == nil { macAudioShown = false; macAudioOfferShown = false }
        }
        .onReceive(client.visionMacAudioRoutes.$model) { _ in
            DispatchQueue.main.async { offerMacAudioChooser() }
        }
        .onChange(of: audioOfferShown) { _, shown in if !shown { offerMacAudioChooser() } }
        .onReceive(client.visionAudio.$presentation) { state in
            DispatchQueue.main.async {
                guard session.owns(lease),
                      client.visionAudio.presentation.availability == state.availability else { return }
                if case .available(let scope) = state.availability,
                   state.canEnable, audioControlsAllowed,
                   !client.visionPlaybackDesired, !audioOfferAnswered, !audioOfferShown, !macAudioShown, !macAudioOfferShown {
                    audioOfferScope = scope
                    audioOfferShown = true
                } else if state.availability != audioOfferScope.map(VisionAudioState.Availability.available) {
                    audioOfferShown = false
                    audioOfferScope = nil
                }
            }
        }
        .onChange(of: phase, initial: true) { _, value in
            guard session.owns(lease) else { return }
            session.setScenePhase(value)
            if value != .active { clearDraft(); releaseInput() }
        }
        .onChange(of: client.connected) { _, connected in
            releaseInput()
            transitions.cancel()
            if connected { inputSuspended = false; client.rememberAuthenticatedMac() }
        }
        .onChange(of: client.visionTestDestinations.storageEpoch, initial: true) { _, epoch in
            testDestinationStores.synchronize(epoch)
        }
        .onChange(of: controlEventsShown) { _, _ in updateInputAdmission() }
        .onChange(of: testDestinationsShown) { _, _ in updateInputAdmission() }
        .onChange(of: client.videoSize) { _, _ in releaseInput() }
        .onChange(of: client.active) { _, _ in releaseInput() }
        .onChange(of: client.visionTextScope) { _, _ in
            if let textDraft, client.captureVisionTextTarget() != textDraft.target { clearDraft() }
        }
        .onDisappear {
            guard session.owns(lease) else { return }
            clearDraft()
            session.suspendPresentation()
            releaseInput()
        }
        .sheet(isPresented: $displayChooserShown, onDismiss: {
            withWindowOwnership {
                client.cancelVisionDisplaySelection()
                client.setVisionDisplayModal(false)
                updateInputAdmission()
            }
        }) {
            VisionDisplayChooser(client: client, choose: { command in
                withWindowOwnership {
                    guard phase == .active, !transitions.isPending else { return }
                    clearDraft()
                    _ = client.selectVisionDisplay(command)
                    updateInputAdmission()
                }
            }, cancel: { withWindowOwnership { client.cancelVisionDisplaySelection() } },
               close: { displayChooserShown = false })
        }
        .sheet(isPresented: $controlEventsShown) {
            ControlEventsPanel(controller: session.controlEvents, enrollment: session.controlEnrollment, close: { controlEventsShown = false })
        }
        .sheet(isPresented: $testDestinationsShown) {
            VisionTestDestinationsView(model: $client.visionTestDestinations, stores: testDestinationStores,
                                       close: { testDestinationsShown = false })
        }
        .sheet(isPresented: $recoveryShown) { recoveryForm }
        .sheet(isPresented: $macAudioShown) {
            VisionMacAudioChooser(routes: client.visionMacAudioRoutes, admit: { action in
                withWindowOwnership { if audioControlsAllowed { action() } }
            }, close: { macAudioShown = false })
        }
        .confirmationDialog("Mac 오디오 장치를 선택할까요?", isPresented: $macAudioOfferShown) {
            Button("장치 선택", action: openMacAudioChooser)
            Button("현재 장치 유지", role: .cancel) {}
        } message: {
            Text("목록을 열어 입력·출력 장치를 선택한 뒤 적용을 눌러야 Mac의 기본 장치가 변경됩니다.")
        }
        .sheet(isPresented: $draftShown, onDismiss: clearDraft) {
            VisionTextDraftPanel(client: client, draft: $textDraft, close: clearDraft)
        }
        .confirmationDialog("Mac 소리를 Vision Pro에서도 재생할까요?", isPresented: $audioOfferShown) {
            Button("Vision Pro에서도 재생") {
                withWindowOwnership {
                    guard audioControlsAllowed, !macAudioModalShown, let scope = audioOfferScope,
                          client.visionAudio.presentation.availability == .available(scope),
                          client.visionAudio.presentation.canEnable else { return }
                    if client.setVisionAudioDesired(true, direction: .playback, expectedScope: scope) { audioOfferAnswered = true }
                }
                audioOfferScope = nil
            }
            Button("나중에", role: .cancel) {
                withWindowOwnership { audioOfferAnswered = true }
                audioOfferScope = nil
            }
        } message: {
            Text(client.visionAudioPrivacyMessage)
        }
        .confirmationDialog("같은 Mac에 연결된 iPad 화면도 바뀔 수 있습니다.", isPresented: $changingSource) {
            Button("Mac 전체 화면 표시") { requestTransition(.desktop) }
        }
    }

    private var hosts: some View {
        VStack(spacing: 18) {
            Text("Mac 화면을 공간 창에서 사용합니다").font(.title2)
            Text(session.message)
            ForEach(client.macs) { mac in
                Button {
                    withWindowOwnership { client.connect(to: mac) }
                } label: {
                    HStack { Text(mac.name); Spacer(); Text(VisionConnectionCopy.route(mac)) }
                }
                .disabled(mac.savedID.flatMap { SavedMacs.automaticTarget(client.savedMacs, preferredID: $0) } == nil)
            }
            Button("연결 문제 해결 / 다른 Mac") { recoveryShown = true }
            Text("Mac 소리와 마이크는 연결 후 직접 켤 수 있습니다.").font(.caption)
        }
        .frame(maxWidth: 650, maxHeight: .infinity)
    }

    private var recoveryForm: some View {
        VStack(spacing: 18) {
            Text("연결 문제 해결 / 다른 Mac").font(.title2)
            Text("연결할 Mac을 선택하세요. Vision Pro는 자체 키로 새로 페어링합니다.")
            ForEach(client.macs) { mac in
                Button {
                    withWindowOwnership { client.connect(to: mac) }
                } label: {
                    HStack { Text(mac.name); Spacer(); Text(VisionConnectionCopy.route(mac)) }
                }
            }
            if let ask = client.homeAsk {
                Text("\(ask.name)에 표시된 12자리 코드를 입력하세요.")
                TextField("페어링 코드", text: $code).textContentType(.oneTimeCode)
                HStack {
                    Button("페어링") { withWindowOwnership { client.pairHome(code: code) }; code = "" }
                    Button("취소") { withWindowOwnership { client.cancelHomeAsk() }; code = "" }
                }
            }
            if case .failed(let problem) = client.pairing { Text(VisionConnectionCopy.problem(problem)).foregroundStyle(.orange) }
            Button("주소로 Mac 추가") { addMac = true }
            Button("닫기") { withWindowOwnership { client.cancelHomeAsk() }; code = ""; recoveryShown = false }
        }
        .padding(30)
        .frame(width: 650)
        .sheet(isPresented: $addMac) { pairingForm }
    }

    private var screen: some View {
        GeometryReader { geo in
            ZStack {
                StreamView(client: client)
                    .scaleEffect(input.viewport.scale, anchor: .center)
                    .offset(input.viewport.offset)
                #if DEBUG && targetEnvironment(simulator)
                if let provider = VisionReleaseFixture.current {
                    VisionReleaseProviderDisplay(provider: provider)
                }
                #endif
                InputOverlay(videoSize: client.videoSize, send: { event in withWindowOwnership { input.overlayInput(event) } },
                             setOwnPointer: { point, origin in withWindowOwnership { client.setOwnPointer(point, from: origin) } }, proxy: input.keyboard,
                             isKeyboardShown: $keyboardShown, latchedModifiers: input.latched,
                             onModifiersConsumed: { withWindowOwnership { input.consumeLatch() } })
                    .allowsHitTesting(false)
                VisionSpatialInput(input: input,
                                   geometry: VisionPointer.Geometry(bounds: CGRect(origin: .zero, size: geo.size), video: client.videoSize),
                                   admit: withWindowOwnership)
                if client.active == .none {
                    Button("Mac 전체 화면 표시", action: openDisplayChooser)
                }
            }
        }
        .background(.black)
        .allowsHitTesting(!draftShown)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("화면 배율 초기화") { withWindowOwnership { input.resetViewport() } }
                .disabled(input.viewport.scale == 1)
                .accessibilityHint("Mac 앱의 배율은 바꾸지 않고 이 화면만 원래 크기로 돌립니다.")
            Button("키보드") { withWindowOwnership { input.keyboard.view?.toggleKeyboard() } }
            Button("입력 초안") { openDraft() }
                .accessibilityHint("Mac 입력을 잠시 멈추고 로컬 초안을 편집합니다. 시스템 키보드 받아쓰기도 사용할 수 있습니다.")
            Button("Esc") { withWindowOwnership { input.press(.escape) } }
            Button("Mac 키") { keysShown.toggle() }
                .popover(isPresented: $keysShown) {
                    VisionKeyPalette(input: input, desktop: client.active == .desktop, admit: withWindowOwnership)
                        .disabled(!client.visionInputBinding.isConfirmed)
                }
            if let measured = client.linkStats {
                Text("\(measured.fps) fps · RTT \(measured.rtt.map { String($0.median) } ?? "측정 전") ms")
                    .font(.caption.monospacedDigit())
            }
        }
        .disabled(!input.canSend || draftShown)
    }

    private var pairingForm: some View {
        VStack(spacing: 16) {
            Text("Mac 주소로 페어링").font(.title2)
            TextField("Mac 주소", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("12자리 코드", text: $code).textContentType(.oneTimeCode)
            if case .failed(let problem) = client.pairing { Text(VisionConnectionCopy.problem(problem)).foregroundStyle(.orange) }
            Button("페어링") { withWindowOwnership { client.pairTyped(code: code, address: address, overlay: false) }; code = "" }
            Button("닫기") { withWindowOwnership { client.cancelPairing() }; code = ""; addMac = false }
        }.padding(30).frame(width: 550)
    }

    private var audioControlsAllowed: Bool {
        session.owns(lease) && phase == .active && client.connected &&
        !transitions.isPending && !inputSuspended && !controlEventsShown && !draftShown && !recoveryShown && !changingSource && !client.visionDisplaySelection.inputBlocked && !displayChooserShown
    }

    private var inputAllowed: Bool {
        phase == .active && client.connected && client.active != .none && !transitions.isPending && !inputSuspended && !controlEventsShown && !draftShown && !recoveryShown && !changingSource && !testDestinationsShown && !audioOfferShown && !macAudioModalShown && !client.visionDisplaySelection.inputBlocked && !displayChooserShown
    }

    private var macAudioModalShown: Bool { macAudioShown || macAudioOfferShown }

    private func openDisplayChooser() {
        withWindowOwnership {
            guard phase == .active, client.connected, !transitions.isPending else { return }
            if client.visionDisplaySelection.legacyDesktopAllowed {
                changingSource = true
                return
            }
            clearDraft()
            keysShown = false
            audioOfferShown = false; audioOfferScope = nil
            macAudioShown = false; macAudioOfferShown = false
            client.setVisionDisplayModal(true)
            displayChooserShown = true
            updateInputAdmission()
            releaseInput()
        }
    }

    private func openMacAudioChooser() {
        withWindowOwnership {
            guard audioControlsAllowed else { return }
            audioOfferShown = false
            audioOfferScope = nil
            macAudioOfferShown = false
            macAudioShown = true
            keysShown = false
            updateInputAdmission()
        }
    }

    private func offerMacAudioChooser() {
        guard session.owns(lease), audioControlsAllowed, !audioOfferShown,
              !macAudioShown, !macAudioOfferShown else { return }
        if client.visionMacAudioRoutes.takeOffer() {
            macAudioOfferShown = true
            updateInputAdmission()
        }
    }

    private func updateInputAdmission() {
        guard session.owns(lease) else { return }
        input.allowed = inputAllowed
        client.visionAudioIntentModal = macAudioModalShown || displayChooserShown || transitions.isPending ||
            inputSuspended || draftShown || testDestinationsShown || recoveryShown || changingSource
        session.refresh()
    }

    private func withWindowOwnership(_ action: () -> Void) {
        lease.perform(current: session.windowLease, action)
    }

    private func releaseInput() { if session.owns(lease) { input.releaseAll() } }

    private func openDraft() {
        guard session.owns(lease), input.canSend else { return }
        keysShown = false
        draftShown = true
        updateInputAdmission()
        releaseInput()
        _ = input.keyboard.view?.resignFirstResponder()
        guard let target = client.captureVisionTextTarget() else { clearDraft(); return }
        textDraft = VisionTextDraft(target: target)
    }

    private func clearDraft() {
        if let phase = textDraft?.phase, case .submitting(_, let request) = phase { client.cancelVisionText(request) }
        textDraft = nil
        draftShown = false
        updateInputAdmission()
    }

    private func requestTransition(_ action: VisionTransition.Action) {
        guard session.owns(lease) else { return }
        if action == .disconnect && client.visionDisplaySelection.inputBlocked {
            clearDraft()
            client.cancelVisionDisplaySelection()
            transitions.cancel()
            releaseInput()
            client.disconnect()
            return
        }
        if action == .desktop && !client.visionDisplaySelection.legacyDesktopAllowed {
            openDisplayChooser()
            return
        }
        if action == .disconnect { client.cancelVisionDisplaySelection() }
        clearDraft()
        client.revokeVisionTextDrafts()
        client.visionAudio.stop()
        guard let ticket = transitions.request(action) else { return }
        let expected = client.connection
        updateInputAdmission()
        releaseInput()
        client.afterVisionInputRelease { readByHost in
            guard session.owns(lease) else { transitions.cancel(); return }
            guard client.connection === expected else {
                _ = transitions.settle(ticket, confirmed: false)
                inputSuspended = true
                updateInputAdmission()
                return
            }
            let next = transitions.settle(ticket, confirmed: readByHost)
            guard next != nil || !readByHost else { return }
            inputSuspended = !readByHost
            defer { updateInputAdmission() }
            switch next {
            case .desktop: client.select(.desktop)
            case .disconnect: client.disconnect()
            case nil: break
            }
        }
    }
}

private struct VisionSentryOrnament: View {
    let snapshot: VisionSentryController.Snapshot
    let allowActivation: Bool
    let activate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("센츄리 보호 켜기", systemImage: "lock.shield", action: activate)
                    .disabled(!allowActivation || !snapshot.canActivate)
                    .accessibilityHint("현재 Mac의 로그인 세션에서 현장 화면과 일반 입력 보호를 요청합니다. 제스처와 오디오 설정은 유지됩니다.")
                Text(snapshot.message).font(.caption)
            }
            if let reason = snapshot.state?.reason { Text(reason).font(.caption) }
            if case .some(.rejected(.some(let reason))) = snapshot.problem { Text(reason).font(.caption) }
            Text("보호 범위는 현재 Mac 로그인 세션의 화면과 일반 키보드·마우스 입력입니다. 전원 버튼·운영체제 보안 화면·다른 로그인 세션은 보장하지 않습니다.")
                .font(.caption)
            ForEach(Array((snapshot.state?.limitations ?? []).enumerated()), id: \.offset) { _, limitation in
                Text(limitation).font(.caption)
            }
            Text("VPN·인터넷 연결의 자동 활성화는 Mac이 결정합니다. 연결을 끊어도 Mac의 보호는 해제되지 않습니다. 현장 복귀는 Mac에서 새로 시스템 인증해야 합니다.")
                .font(.caption)
        }
        .padding(16)
        .frame(width: 620)
        .glassBackgroundEffect()
    }
}

private struct VisionAudioControls: View {
    @ObservedObject var client: StreamClient
    @ObservedObject var audio: VisionAudioController
    let allowStart: Bool
    let admit: (() -> Void) -> Void

    var body: some View {
        HStack(spacing: 12) {
            let running = audio.presentation.phase.grant != nil || client.visionPlaybackDesired
            Button(running ? "Mac 소리 중지" : "Mac 소리 켜기",
                   systemImage: running ? "speaker.slash" : "speaker.wave.2") {
                admit {
                    if running { client.setVisionAudioDesired(false, direction: .playback) }
                    else if allowStart { client.setVisionAudioDesired(true, direction: .playback) }
                }
            }
            .disabled(!running && (!client.visionAudioIntentContext.admitted || !allowStart || audio.cleanupProblem != nil))
            .accessibilityHint(running ? "즉시 소리를 중지합니다." : "이 버튼은 Mac 소리 수신만 켭니다. 마이크 전송은 별도입니다.")
            Text(message).font(.caption).lineLimit(2)
            if audio.cleanupProblem != nil {
                Button("오디오 정리 다시 시도", systemImage: "arrow.clockwise") { admit { audio.retryCleanup() } }
                    .accessibilityHint("남아 있는 오디오 세션만 정리합니다. 소리나 마이크를 다시 켜지 않습니다.")
            }
            Spacer()
        }
    }

    private var message: String {
        if let problem = audio.cleanupProblem { return "오디오 정리가 필요합니다. " + problem }
        if let problem = client.visionForwardingProblem { return problem }
        switch audio.presentation.phase {
        case .requesting: return "Mac의 소리 전송 확인을 기다립니다."
        case .waiting: return "소리 데이터를 기다립니다."
        case .rendering: return "Mac 소리 재생 중"
        case .failed(let problem): return problem
        case .off:
            switch audio.presentation.availability {
            case .disconnected: return "Mac 연결 후 사용할 수 있습니다."
            case .unsupported: return "현재 Mac 호스트는 소리 전송을 지원하지 않습니다."
            case .noSource: return "Mac 화면을 선택하면 소리를 켤 수 있습니다."
            case .available: return client.visionAudioPrivacyMessage
            }
        }
    }
}

private struct VisionMicrophoneControls: View {
    @ObservedObject var client: StreamClient
    let allowStart: Bool
    let admit: (() -> Void) -> Void

    var body: some View {
        HStack(spacing: 12) {
            let stopping = client.microphonePhase.canStop || client.visionMicrophoneDesired
            let cleanup = client.microphoneCleanupProblem != nil
            Button(cleanup ? "마이크 정리 다시 시도" : stopping ? "Vision 마이크 중지" : "Vision 마이크 보내기",
                   systemImage: stopping ? "mic.slash" : "mic") {
                admit {
                    if cleanup { client.toggleVisionMicrophone() }
                    else if stopping { client.setVisionAudioDesired(false, direction: .microphone) }
                    else if allowStart { client.setVisionAudioDesired(true, direction: .microphone) }
                }
            }
            .disabled(!cleanup && !stopping && (!allowStart || !client.visionAudioIntentContext.admitted || client.visionAudio.cleanupProblem != nil))
            .accessibilityHint(cleanup ? "기존 마이크 자원만 정리합니다. 다시 녹음하지 않습니다." :
                stopping ? "즉시 음성 전송을 중지합니다." : "직접 허용하면 Vision 마이크를 현재 선택한 Mac으로 전송합니다.")
            Button("수신 확인", systemImage: "checkmark.circle") {
                admit { client.requestVisionMicrophoneReceipt() }
            }
            .disabled(cleanup || client.microphonePhase != .live)
            .accessibilityHint("현재 Mac의 음성 수신량을 한 번 확인합니다. 실제 통화 입력은 별도 확인이 필요합니다.")
            Text(message).font(.caption).lineLimit(2)
            Spacer()
        }
    }

    private var message: String {
        if let problem = client.microphoneCleanupProblem { return problem }
        if let problem = client.visionForwardingProblem { return problem }
        switch client.microphonePhase {
        case .unavailable: return "이 Mac 연결은 마이크 입력을 지원하지 않습니다."
        case .off: return "Vision 마이크 꺼짐"
        case .authorizing: return "Vision 마이크 권한을 확인합니다."
        case .requesting: return "선택한 Mac의 마이크 입력 허용을 기다립니다."
        case .capturing: return "Vision 마이크를 준비합니다."
        case .live:
            return (client.microphoneReceipt?.admittedPackets ?? 0) > 0 ?
                "마지막 조회에서 Mac 수신 확인 · 실제 통화 입력은 별도 확인" : "전송 허용됨 · 수신 확인을 눌러 조회하세요."
        case .stopping: return "음성 전송을 중지했습니다. Mac의 정리 확인을 기다립니다."
        case .cleanupRequired: return "Mac 마이크 정리가 확인되지 않았습니다. 화면 목록을 새로고침하거나 다시 연결한 뒤 직접 시작하세요."
        case .failed(let problem):
            return problem == "iPad 마이크 권한이 필요합니다." ? "Vision 마이크 권한이 필요합니다." : problem
        }
    }
}

private enum VisionConnectionCopy {
    static func route(_ mac: FoundMac) -> String {
        if mac.route == .remote { return "원격" }
        switch mac.homeWord {
        case .method(let method):
            switch method {
            case .wired: return "유선"
            case .wifi: return "와이파이"
            case .direct: return "직접 무선 연결"
            case nil: return ""
            }
        case .notPaired: return "페어링 필요"
        case .openDoor: return "페어링 없이 연결"
        case .pairsOverCable: return "유선"
        case .updateSill: return "Mac 앱 업데이트 필요"
        }
    }

    static func problem(_ problem: PairingProblem) -> String {
        switch problem {
        case .address: return "올바른 Mac 주소를 입력해 주세요."
        case .zone: return "주소에서 % 뒤의 부분을 지워 주세요. 해당 표시는 같은 네트워크에서만 사용할 수 있습니다."
        case .codeLength: return "페어링 코드는 12자리입니다."
        case .codeTypo: return "코드를 확인해 주세요. Mac에 표시된 코드와 일치해야 합니다."
        case .wrongCode(let left): return "코드가 일치하지 않습니다. 남은 시도는 \(left)회입니다."
        case .notPairing(let mac): return "\(mac)에서 CCR Sill의 기기 페어링을 먼저 시작해 주세요."
        case .stopped(let mac), .homeStopped(let mac): return "시도 횟수를 초과했습니다. \(mac)에서 새 페어링을 시작해 주세요."
        case .expired: return "코드가 만료됐습니다. Mac에서 새 페어링을 시작해 주세요."
        case .homeExpired(let mac): return "코드가 만료됐습니다. \(mac) 항목을 다시 선택하면 새 코드를 받을 수 있습니다."
        case .proofFailed(let host):
            return "\(host)의 연결 신원을 확인하지 못했습니다. Mac과 같은 네트워크에서 다시 페어링하거나 페어링 코드를 스캔해 주세요."
        case .homeProofFailed(let mac):
            return "\(mac)의 연결 신원을 확인하지 못했습니다. Mac 목록에서 해당 항목을 다시 선택해 주세요."
        case .proofFailedOverStream(let mac):
            return "\(mac)의 연결 신원을 확인하지 못했습니다. 페어링을 다시 시도해 주세요."
        case .nothingAnswered(let host), .homeNoAnswer(let host), .noAnswerOverStream(let host):
            return "\(host)에서 응답하지 않습니다. 주소와 Mac의 CCR Sill 실행 상태를 확인해 주세요."
        case .notSill(let host): return "\(host)의 앱이 CCR Sill인지, 최신 버전인지 확인해 주세요."
        case .localNetwork(let host): return "\(host)에 연결하려면 설정에서 CCR Sill의 로컬 네트워크 접근을 허용해 주세요."
        case .notALink: return "CCR Sill 페어링 링크가 아닙니다."
        case .noKey: return "Vision Pro의 연결 키를 사용할 수 없습니다. 잠금을 해제한 뒤 앱을 다시 열어 주세요."
        case .homeClosed(let mac): return "\(mac)의 페어링이 종료됐습니다. Mac에서 다시 시작해 주세요."
        case .macSaid(let words): return words
        }
    }
}
