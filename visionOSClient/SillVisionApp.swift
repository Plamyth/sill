import SwiftUI
import UIKit
import StreamProtocol

@main
struct SillVisionApp: App {
    init() {
        guard !VisionReleaseTestContext.isTestBundle || VisionReleaseTestContext.current != nil else { return }
        VisionReleaseRuntimeWriter.write()
    }

    var body: some Scene {
        WindowGroup(id: "mac", for: VisionDisplaySelection.WindowTarget.self) { target in
            if VisionReleaseTestContext.isTestBundle && VisionReleaseTestContext.current == nil {
                Text("격리 테스트 실행 정보가 없거나 일치하지 않습니다.")
            } else {
                SillVisionWindow(target: target)
            }
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
    }
}

private struct SillVisionWindow: View {
    @StateObject private var session: VisionAppSession
    @State private var window = UUID()
    @Binding private var target: VisionDisplaySelection.WindowTarget?

    init(target: Binding<VisionDisplaySelection.WindowTarget?>) {
        _target = target
        _session = StateObject(wrappedValue: VisionAppSession(target: target.wrappedValue))
    }

    var body: some View {
        Group {
            if let lease = session.windowLease, lease.window == window {
                SillVisionWorkspace(session: session, lease: lease, target: $target).id(lease.admission)
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
    @Binding private var windowTarget: VisionDisplaySelection.WindowTarget?
    @ObservedObject private var client: StreamClient
    @Environment(\.scenePhase) private var phase
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var input: VisionInputSession
    @State private var keyboardShown = false
    @State private var keysShown = false
    @State private var recoveryShown = false
    @State private var changingSource = false
    @State private var transitions = VisionTransition()
    @State private var inputSuspended = false
    @State private var textDraft: VisionTextDraft<StreamClient.VisionTextTarget>?
    @State private var draftShown = false
    @State private var displayChooserShown = false
    @State private var newWindowChooserShown = false
    @State private var geometryProblem: String?
    @State private var macAudioShown = false
    @State private var controlEventsShown = false
    @State private var testDestinationsShown = false
    @StateObject private var testDestinationStores = VisionTestDestinationStores()

    init(session: VisionAppSession, lease: VisionWindowLease, target: Binding<VisionDisplaySelection.WindowTarget?>) {
        self._windowTarget = target
        self.session = session
        self.lease = lease
        self.client = session.client
        self.input = session.input
    }

    var body: some View {
        Group {
            if client.connected { screen }
            else { hosts.padding(20) }
        }
        .background(VisionWindowAspect(videoSize: client.videoSize, problem: $geometryProblem))
        .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) {
            ScrollView {
                workspaceControls
            }
            .frame(width: 1100, height: 220)
            .glassBackgroundEffect()
        }
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            if session.owns(lease), client.connected, client.visionSentrySnapshot.available,
               client.active != .none || client.visionSentrySnapshot.state?.control != nil {
                VisionSentryOrnament(snapshot: client.visionSentrySnapshot,
                                     allowActivation: phase == .active && !transitions.isPending, set: { desired in
                    withWindowOwnership {
                        guard phase == .active, !transitions.isPending else { return }
                        client.setVisionSentry(desired)
                    }
                }, readback: {
                    withWindowOwnership {
                        guard phase == .active, !transitions.isPending else { return }
                        client.readbackVisionSentry()
                    }
                })
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
            if shown { keysShown = false }
            updateInputAdmission()
        }
        .onChange(of: audioControlsAllowed) { _, allowed in
            if !allowed { macAudioShown = false }
        }
        .onReceive(client.visionMacAudioRoutes.$scope) { scope in
            if scope == nil { macAudioShown = false }
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
        .onChange(of: client.visionInputBinding, initial: true) { _, _ in pinCurrentWindow() }
        .onChange(of: client.visionDisplaySelection.revision) { _, _ in
            if let current = client.visionDisplaySelection.windowTarget { windowTarget = current }
            pinCurrentWindow()
        }
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
        .sheet(isPresented: $newWindowChooserShown) {
            VisionDisplayChooser(client: client, openInNewWindow: { target in
                withWindowOwnership {
                    guard phase == .active,
                          let displayID = target.resolvedDisplayID(macID: client.session?.macID, catalog: client.visionDisplaySelection.catalog),
                          client.visionDisplaySelection.windowTarget(macID: client.session?.macID, displayID: displayID) == target,
                          client.visionDisplaySelection.observedDisplay != target.displayID else { return }
                    guard let opening = VisionAppSession.issueDisplayOpening(target) else { return }
                    openWindow(id: "mac", value: opening)
                    newWindowChooserShown = false
                }
            }, choose: { _ in }, cancel: {}, close: { newWindowChooserShown = false })
        }
        .onChange(of: newWindowChooserShown) { _, _ in updateInputAdmission() }
        .sheet(isPresented: $controlEventsShown) {
            ControlEventsPanel(controller: session.controlEvents, enrollment: session.controlEnrollment, close: { controlEventsShown = false })
        }
        .sheet(isPresented: $testDestinationsShown) {
            VisionTestDestinationsView(model: $client.visionTestDestinations, stores: testDestinationStores,
                                       close: { testDestinationsShown = false })
        }
        .sheet(isPresented: $recoveryShown) { recoveryForm }
        .popover(isPresented: $macAudioShown) {
            VisionMacAudioChooser(routes: client.visionMacAudioRoutes, admit: { action in
                withWindowOwnership { if audioControlsAllowed { action() } }
            }, close: { macAudioShown = false })
        }
        .sheet(isPresented: $draftShown, onDismiss: clearDraft) {
            VisionTextDraftPanel(client: client, draft: $textDraft, close: clearDraft)
        }
        .confirmationDialog("같은 Mac에 연결된 iPad 화면도 바뀔 수 있습니다.", isPresented: $changingSource) {
            Button("Mac 전체 화면 표시") { requestTransition(.desktop) }
        }
    }

    private var workspaceControls: some View {
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
                          displayChooserShown || macAudioModalShown || transitions.isPending)
                .accessibilityHint("Codex와 Cursor의 원본 세션·실행 상태를 읽기 전용 패널에서 확인합니다.")
                Button("다른 모니터 창", action: openAdditionalDisplayChooser)
                    .disabled(!client.connected || !client.visionDisplaySelection.independentWindowsAvailable)
                    .accessibilityHint("모니터를 선택한 뒤 그 모니터에 고정된 공간 창을 엽니다.")
                Text(session.message).font(.caption).lineLimit(2)
                if client.connected {
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
                if let geometryProblem { Text(geometryProblem).foregroundStyle(.orange) }
                if !client.visionDisplaySelection.independentWindowsAvailable {
                    Text("이 Mac의 독립 모니터 창 지원을 확인하지 못했습니다.").font(.caption)
                }
                controls
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
                VisionCallControls(client: client, audio: client.visionAudio,
                                   allowStart: audioControlsAllowed, admit: withWindowOwnership,
                                   chooseDevices: openMacAudioChooser)
            }
            #if DEBUG && targetEnvironment(simulator)
            if let peer = session.remotePeer { VisionReleaseRemoteStatus(peer: peer) }
            #endif
        }
        .padding(16)
    }

    private var hosts: some View {
        VStack(spacing: 18) {
            Text("Mac 화면을 공간 창에서 사용합니다").font(.title2)
            Text(session.message)
            ForEach(client.macs.filter { session.client.visionDisplaySelection.windowTarget == nil ||
                $0.savedID == session.client.visionDisplaySelection.windowTarget?.macID }) { mac in
                Button {
                    withWindowOwnership { if let id = mac.savedID { client.connectVisionTrustedMac(id) } }
                } label: {
                    HStack { Text(mac.name); Spacer(); Text(VisionConnectionCopy.route(mac)) }
                }
                .disabled(mac.savedID.flatMap { SavedMacs.automaticTarget(client.savedMacs, preferredID: $0) } == nil)
            }
            Button("신뢰 Mac 연결 확인") { recoveryShown = true }
            Text("Mac 소리와 마이크는 연결 후 직접 켤 수 있습니다.").font(.caption)
        }
        .frame(maxWidth: 650, maxHeight: .infinity)
    }

    private var recoveryForm: some View {
        VStack(spacing: 18) {
            Text("신뢰 Mac 연결 확인").font(.title2)
            Text("저장된 신뢰 Mac만 선택할 수 있습니다. Mac과 기기 키·공개 연결 설정이 다르면 자동 등록하지 않습니다.")
            Text(session.message)
            ForEach(client.savedMacs.filter { SavedMacs.automaticTarget([$0], preferredID: $0.macID) != nil &&
                (client.visionDisplaySelection.windowTarget == nil || $0.macID == client.visionDisplaySelection.windowTarget?.macID) }) { mac in
                Button(mac.name) {
                    withWindowOwnership { client.connectVisionTrustedMac(mac.macID) }
                }
            }
            if client.savedMacs.isEmpty {
                Text("최초 소유 Mac 연결은 앱의 검증된 공개 연결 설정이 준비되어야 합니다. 설정이 없으면 연결을 중지합니다.")
            }
            if case .failed(let problem) = client.pairing { Text(VisionConnectionCopy.problem(problem)).foregroundStyle(.orange) }
            Button("닫기") { recoveryShown = false }
        }
        .padding(30)
        .frame(width: 650)
    }

    private var screen: some View {
        GeometryReader { geo in
            ZStack {
                StreamView(client: client)
                    .opacity(targetPresented ? 1 : 0)
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
                if !targetPresented {
                    Text("고정한 Mac 모니터의 화면 확인을 기다리고 있습니다.")
                } else if client.active == .none {
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

    private func pinCurrentWindow() {
        guard session.owns(lease), windowTarget == nil,
              client.visionDisplaySelection.windowTarget == nil,
              case .presented(let epoch) = client.visionInputBinding,
              let displayID = client.visionDisplaySelection.observedDisplay,
              let target = client.visionDisplaySelection.windowTarget(macID: client.session?.macID, displayID: displayID) else { return }
        var selection = client.visionDisplaySelection
        selection.windowTarget = target
        guard selection.windowTargetPresented(macID: client.session?.macID, epoch: epoch) else { return }
        windowTarget = target
        client.visionDisplaySelection = selection
    }

    private var targetPresented: Bool {
        let epoch: VideoEpoch?
        if case .presented(let value) = client.visionInputBinding { epoch = value }
        else { epoch = nil }
        return client.visionDisplaySelection.windowTargetPresented(macID: client.session?.macID, epoch: epoch)
    }

    private var audioControlsAllowed: Bool {
        session.owns(lease) && phase == .active && client.connected &&
        !transitions.isPending && !inputSuspended && !controlEventsShown && !draftShown && !recoveryShown && !changingSource && !client.visionDisplaySelection.inputBlocked && !displayChooserShown
    }

    private var inputAllowed: Bool {
        targetPresented && !newWindowChooserShown && phase == .active && client.connected && client.active != .none && !transitions.isPending && !inputSuspended && !controlEventsShown && !draftShown && !recoveryShown && !changingSource && !testDestinationsShown && !macAudioModalShown && !client.visionDisplaySelection.inputBlocked && !displayChooserShown
    }

    private var macAudioModalShown: Bool { macAudioShown }

    private func openAdditionalDisplayChooser() {
        guard session.owns(lease), phase == .active, !draftShown, !transitions.isPending,
              client.visionDisplaySelection.independentWindowsAvailable else { return }
        keysShown = false
        newWindowChooserShown = true
        releaseInput()
    }

    private func openDisplayChooser() {
        withWindowOwnership {
            guard phase == .active, client.connected, !transitions.isPending else { return }
            if client.visionDisplaySelection.legacyDesktopAllowed {
                changingSource = true
                return
            }
            clearDraft()
            keysShown = false
            macAudioShown = false
            client.setVisionDisplayModal(true)
            displayChooserShown = true
            updateInputAdmission()
            releaseInput()
        }
    }

    private func openMacAudioChooser() {
        withWindowOwnership {
            guard audioControlsAllowed else { return }
            macAudioShown = true
            keysShown = false
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
    let set: (Bool) -> Void
    let readback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("센츄리 보호 켜기", systemImage: "lock.shield") { set(true) }
                    .disabled(!allowActivation || !snapshot.canActivate)
                    .accessibilityHint("현재 Mac의 로그인 세션에서 현장 화면과 일반 입력 보호를 요청합니다. 제스처와 오디오 설정은 유지됩니다.")
                Text(snapshot.message).font(.caption)
            }
            HStack {
                Button("센츄리 보호 끄기", systemImage: "lock.open") { set(false) }
                    .disabled(!allowActivation || !snapshot.canDeactivate)
                    .accessibilityHint("현재 Mac의 원격 화면·일반 입력 보호만 해제합니다. Mac 오디오 복귀와 시스템 인증·권한은 별도입니다.")
                Button("보존 원문으로 결과 확인", systemImage: "arrow.clockwise", action: readback)
                    .disabled(!allowActivation || !snapshot.canReadback)
                    .accessibilityHint("같은 요청 원문으로 Mac의 결과만 다시 확인합니다. 새 보호 전환을 만들지 않습니다.")
            }
            if snapshot.state?.control == nil {
                Text("이 Mac은 보호 끄기를 지원하지 않습니다. 기존 보호 켜기만 사용할 수 있습니다.").font(.caption)
            }
            if let reason = snapshot.state?.reason { Text(reason).font(.caption) }
            if case .some(.rejected(.some(let reason))) = snapshot.problem { Text(reason).font(.caption) }
            Text("보호 범위는 현재 Mac 로그인 세션의 화면과 일반 키보드·마우스 입력입니다. 전원 버튼·운영체제 보안 화면·다른 로그인 세션은 보장하지 않습니다.")
                .font(.caption)
            ForEach(Array((snapshot.state?.limitations ?? []).enumerated()), id: \.offset) { _, limitation in
                Text(limitation).font(.caption)
            }
            Text("VPN·인터넷 연결의 자동 활성화는 Mac이 결정합니다. 연결을 끊어도 Mac의 보호는 해제되지 않습니다. 현장 오디오 복귀는 Mac에서 새로 시스템 인증해야 합니다. 원격 보호 끄기는 오디오 복귀·OS 로그인·화면 기록 등 TCC 권한을 승인하지 않습니다.")
                .font(.caption)
        }
        .padding(16)
        .frame(width: 620)
        .glassBackgroundEffect()
    }
}

private struct VisionCallControls: View {
    @ObservedObject var client: StreamClient
    @ObservedObject var audio: VisionAudioController
    let allowStart: Bool
    let admit: (() -> Void) -> Void
    let chooseDevices: () -> Void
    @State private var configuredAction = VisionConfiguredCraftAction()

    private var configuredContext: VisionConfiguredCraftAction.Context {
        let audioContext = client.visionAudioIntentContext
        var context = VisionConfiguredCraftAction.Context()
        context.hostKey = audioContext.hostKey
        context.scope = audioContext.scope
        context.admitted = allowStart && audioContext.admitted
        context.selection = client.visionStoredAudioSelection?.desire
        context.selectionRevision = client.visionStoredAudioSelection?.revision ?? 0
        let routes = client.visionMacAudioRoutes
        context.otherDeviceSelected = routes.hasExplicitSelection
        context.deviceRouteRevision = context.otherDeviceSelected ? routes.model.catalogToken?.revision : nil
        if context.otherDeviceSelected && (routes.scope == nil || routes.catalogInvalid || routes.model.pending != nil) {
            context.admitted = false
        }
        if let snapshot = client.visionForwarding?.providerCallSnapshot, let intent = snapshot.intent {
            let speakerReady: Bool
            switch audio.presentation.phase {
            case .waiting, .rendering: speakerReady = true
            default: speakerReady = false
            }
            context.readback = .init(desire: .init(playback: intent.outputDesired, microphone: intent.inputDesired),
                microphoneReady: audioContext.eligible && client.microphonePhase == .live &&
                    client.visionForwarding?.permits(.microphone) == true,
                speakerReady: audioContext.eligible && speakerReady && client.visionForwarding?.permits(.playback) == true,
                microphoneOff: (client.microphonePhase == .off || client.microphonePhase == .unavailable) &&
                    client.microphoneCleanupProblem == nil,
                speakerOff: audio.presentation.phase == .off && audio.cleanupProblem == nil)
        }
        // No authenticated descriptor or implemented route is connected yet.
        return context
    }

    private var call: VisionProviderCall.Controls {
        client.visionProviderCall.controls(canStart: allowStart && client.visionProviderCanStart,
            canStop: client.visionProviderCanStop, context: client.visionAudioIntentContext,
            snapshot: client.visionForwarding?.providerCallSnapshot)
    }
    private var microphoneOn: Bool { client.visionMicrophoneDesired || client.microphonePhase.canStop }
    private var speakerOn: Bool { client.visionPlaybackDesired || audio.presentation.phase.grant != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button("음성 대화", systemImage: "phone.fill", action: {})
                .onLongPressGesture(minimumDuration: VisionConfiguredCraftAction.holdDuration) {
                    admit {
                        guard allowStart else { return }
                        _ = configuredAction.begin(heldFor: VisionConfiguredCraftAction.holdDuration,
                            context: configuredContext, now: ProcessInfo.processInfo.systemUptime, issuedAt: Date())
                    }
                }
                .disabled(!configuredAction.canBegin(configuredContext))
                .accessibilityIdentifier("VisionVoiceCall")
                .accessibilityHint("0.5초 동안 길게 눌러 현재 Mac의 음성 대화를 전환합니다.")
                if client.visionProviderCall.selectedActiveCall != nil {
                    Button("기존 통화 종료", systemImage: "phone.down.fill") {
                        admit { if call.enabled && call.action == .stop { client.performVisionProviderCall(.stop) } }
                    }
                    .disabled(!call.enabled)
                }
                Toggle(isOn: Binding(get: { microphoneOn }, set: { enabled in
                    admit {
                        guard !enabled || allowStart else { return }
                        client.setVisionAudioDesired(enabled, direction: .microphone)
                    }
                })) { Label("마이크", systemImage: microphoneOn ? "mic" : "mic.slash") }
                .toggleStyle(.button)
                .disabled(!microphoneOn && (!allowStart || !client.visionAudioIntentContext.admitted ||
                    client.microphoneCleanupProblem != nil || audio.cleanupProblem != nil))
                .accessibilityLabel("Vision 마이크")
                .accessibilityIdentifier("VisionVoiceMicrophone")
                Toggle(isOn: Binding(get: { speakerOn }, set: { enabled in
                    admit {
                        guard !enabled || allowStart else { return }
                        client.setVisionAudioDesired(enabled, direction: .playback)
                    }
                })) { Label("스피커", systemImage: speakerOn ? "speaker.wave.2" : "speaker.slash") }
                .toggleStyle(.button)
                .disabled(!speakerOn && (!allowStart || !client.visionAudioIntentContext.admitted || audio.cleanupProblem != nil))
                .accessibilityLabel("Vision 스피커")
                .accessibilityIdentifier("VisionVoiceSpeaker")
                Button(action: chooseDevices) {
                    Label("장치", systemImage: "hifispeaker")
                }
                .disabled(!allowStart)
                .accessibilityIdentifier("VisionVoiceDevices")
                Spacer()
                if audio.cleanupProblem != nil {
                    Button("스피커 정리 다시 시도") { admit { audio.retryCleanup() } }
                }
                if client.microphoneCleanupProblem != nil {
                    Button("마이크 정리 다시 시도") { admit { client.toggleVisionMicrophone() } }
                }
            }
            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                Text(message).font(.caption)
            }
        }
        .onChange(of: configuredContext.fence) { _, _ in
            _ = configuredAction.advance(context: configuredContext, now: ProcessInfo.processInfo.systemUptime)
        }
        .onDisappear { configuredAction.cancel() }
    }

    private var messages: [String] {
        let commandMessage = configuredAction.message ??
            (configuredContext.fence == nil ? "공통 음성 명령 연결을 확인하지 못했습니다." : nil)
        return [client.microphoneCleanupProblem, audio.cleanupProblem, client.visionForwardingProblem,
         commandMessage, client.visionProviderCall.request != nil ? call.message : nil,
         microphoneMessage, speakerMessage].compactMap { $0 }.reduce(into: []) {
            if !$0.contains($1) { $0.append($1) }
        }
    }

    private var speakerMessage: String? {
        switch audio.presentation.phase {
        case .requesting: return "스피커 연결을 확인하고 있습니다."
        case .waiting: return "Mac 소리를 기다리고 있습니다."
        case .rendering: return nil
        case .failed(let problem): return problem
        case .off:
            switch audio.presentation.availability {
            case .disconnected: return "Mac 연결 후 스피커를 사용할 수 있습니다."
            case .unsupported: return "이 Mac 연결은 소리 전송을 지원하지 않습니다."
            case .noSource: return "Mac 화면을 선택하면 스피커를 사용할 수 있습니다."
            case .available: return nil
            }
        }
    }

    private var microphoneMessage: String? {
        switch client.microphonePhase {
        case .unavailable: return "이 Mac 연결은 마이크 입력을 지원하지 않습니다."
        case .off, .live: return nil
        case .authorizing: return "Vision 마이크 권한을 확인합니다."
        case .requesting: return "마이크 연결을 확인하고 있습니다."
        case .capturing: return "Vision 마이크를 준비합니다."
        case .stopping: return "마이크를 중지하고 있습니다."
        case .cleanupRequired: return "Mac 마이크 정리를 확인하지 못했습니다."
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
        case .notPaired: return "신뢰 확인 필요"
        case .openDoor: return "페어링 없이 연결"
        case .pairsOverCable: return "유선"
        case .updateSill: return "Mac 앱 업데이트 필요"
        }
    }

    static func problem(_ problem: PairingProblem) -> String {
        switch problem {
        case .address, .zone: return "저장된 Mac의 연결 설정을 확인하지 못했습니다."
        case .codeLength, .codeTypo, .wrongCode, .notPairing, .stopped, .homeStopped, .expired, .homeExpired:
            return "자동 연결 승인을 확인하지 못했습니다. Mac의 신뢰 상태와 공개 연결 설정을 확인하세요."
        case .proofFailed(let host):
            return "\(host)의 연결 신원이 저장된 신뢰와 일치하지 않습니다. 자동으로 신뢰를 변경하지 않습니다."
        case .homeProofFailed(let mac):
            return "\(mac)의 연결 신원을 확인하지 못했습니다. Mac 목록에서 해당 항목을 다시 선택해 주세요."
        case .proofFailedOverStream(let mac):
            return "\(mac)의 연결 신원을 확인하지 못했습니다. 저장된 신뢰를 확인하세요."
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


private struct VisionWindowAspect: UIViewRepresentable {
    let videoSize: CGSize
    @Binding var problem: String?

    func makeUIView(context: Context) -> AspectView { AspectView() }
    func updateUIView(_ view: AspectView, context: Context) {
        view.report = { problem = $0 }
        view.videoSize = videoSize
        view.applyAspect()
    }

    final class AspectView: UIView {
        var videoSize = CGSize.zero
        var report: ((String?) -> Void)?
        private var appliedScene: ObjectIdentifier?
        private var appliedRatio: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyAspect()
        }

        func applyAspect() {
            guard let scene = window?.windowScene,
                  let size = VisionWindowGeometry.size(video: videoSize, current: scene.coordinateSpace.bounds.size) else { return }
            let identity = ObjectIdentifier(scene)
            let ratio = videoSize.width / videoSize.height
            guard appliedScene != identity || appliedRatio != ratio else { return }
            appliedScene = identity
            appliedRatio = ratio
            // Resolve through this view's scene so another spatial window is never resized.
            DispatchQueue.main.async { [weak self, weak scene] in
                guard let self, let scene, self.window?.windowScene === scene,
                      self.appliedRatio == ratio else { return }
                self.report?(nil)
                scene.requestGeometryUpdate(.Vision(size: size, resizingRestrictions: .uniform)) { [weak self] _ in
                    guard let self, self.appliedRatio == ratio else { return }
                    self.report?("영상 비율에 맞춘 창 크기 변경을 적용하지 못했습니다.")
                }
            }
        }
    }
}
