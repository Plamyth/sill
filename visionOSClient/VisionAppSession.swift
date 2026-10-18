import SwiftUI
import Combine
import StreamProtocol

final class VisionAppSession: ObservableObject {
    let client = StreamClient()
    let input = VisionInputSession()
    let stats = ClientStatsReporter()
    @Published private(set) var windowLease: VisionWindowLease?
    var windowOwner: UUID? { windowLease?.window }
    @Published private(set) var message = "Mac 연결을 준비하고 있습니다."
    private let writer = VisionAutoConnectStatusWriter(identifier: UUID())
    private var observation: AnyCancellable?
    private var started = false
    private var foreground = false
    private var expectedPin: Data?
    private let launch: VisionCableBootstrap<FoundMac>.Launch

    init() {
        launch = .parse(CommandLine.arguments)
        client.visionCableBootstrap = VisionCableBootstrap(launch: launch)
        client.visionCableBootstrap.onChange = { [weak self] in self?.refresh() }
        let events: [AnyPublisher<Void, Never>] = [
            client.$connected.map { _ in () }.eraseToAnyPublisher(),
            client.$savedMacs.map { _ in () }.eraseToAnyPublisher(),
            client.$macInfoSaved.map { _ in () }.eraseToAnyPublisher(),
            client.$macInfo.map { _ in () }.eraseToAnyPublisher(),
            client.$macs.map { _ in () }.eraseToAnyPublisher(),
            client.$homeAsk.map { _ in () }.eraseToAnyPublisher(),
            client.$localNetworkDenied.map { _ in () }.eraseToAnyPublisher(),
            client.$pairing.map { _ in () }.eraseToAnyPublisher(),
            client.$visionInputBinding.map { _ in () }.eraseToAnyPublisher(),
            client.$visionDisplaySelection.map { _ in () }.eraseToAnyPublisher(),
            client.$active.map { _ in () }.eraseToAnyPublisher(),
            input.$moving.map { _ in () }.eraseToAnyPublisher(),
        ]
        observation = Publishers.MergeMany(events).receive(on: RunLoop.main).sink { [weak self] in
            guard let self, self.started else { return }
            if self.client.localNetworkDenied { self.client.stopVisionCableBootstrap(.permissionRequired) }
            self.refresh()
        }
    }

    func claim(_ window: UUID) {
        if windowLease == nil { windowLease = VisionWindowLease(window: window) }
        client.admitVisionDisplays(lease: windowLease, foreground: foreground)
    }

    func owns(_ lease: VisionWindowLease) -> Bool { windowLease == lease }

    func release(_ window: UUID) {
        guard windowOwner == window else { return }
        windowLease = nil
        suspendPresentation()
        input.allowed = false
    }

    func setScenePhase(_ phase: ScenePhase) {
        let scene: VisionMicrophoneAdmission.Scene
        switch phase {
        case .active: scene = .active
        case .inactive: scene = .inactive
        case .background: scene = .background
        @unknown default: scene = .background
        }
        client.microphoneSceneChanged(lease: windowLease, scene: scene)
        start(foreground: phase == .active)
    }

    func suspendPresentation() {
        client.microphoneSceneChanged(lease: nil, scene: .background)
        setForeground(false)
    }

    func start(foreground: Bool) {
        guard foreground else { setForeground(false); return }
        guard !started else { setForeground(foreground); return }
        started = true
        self.foreground = foreground
        client.visionStartupForeground = foreground
        input.bind(client)
        stats.attach(to: client)
        client.startRemote()
        expectedPin = client.visionExpectedMacPin
        client.armSavedMacAutoConnect()
        client.visionStartupStarted = true
        client.startBrowsing()
        setForeground(foreground)
    }

    func setForeground(_ active: Bool) {
        foreground = active
        client.admitVisionDisplays(lease: windowLease, foreground: active)
        client.visionStartupForeground = active
        client.visionAudio.setForeground(active)
        client.setVisionPresentationForeground(active)
        if started && !active { client.stopVisionCableBootstrap(.foregroundRequired) }
        refresh()
    }

    func refresh() {
        client.updateVisionMacAudioRoutes(lease: windowLease, foreground: foreground)
        let bootstrap = client.visionCableBootstrap
        let mode: VisionAutoConnectStatus.StartupMode
        switch launch {
        case .ordinary: mode = .coldLaunch
        case .cable: mode = .cableBootstrap
        case .invalid: mode = .invalidBootstrap
        }
        var reason: VisionCableBootstrapReason?
        var phase: VisionAutoConnectStatus.Phase
        switch bootstrap.phase {
        case .ordinary: phase = .waiting
        case .waiting(let why): phase = .waiting; reason = why
        case .attempting: phase = .bootstrapDialing
        case .asking: phase = .bootstrapAsking
        case .paired: phase = .paired
        case .stopped(let why): phase = .stopped; reason = why
        }
        if !started && !foreground { reason = .foregroundRequired }
        if client.connected { phase = .connected }
        else if client.connection != nil { phase = .connecting }
        if client.localNetworkDenied { reason = .permissionRequired }
        let expectedMatched: Bool
        if client.connected, let expectedPin, let session = client.session,
           session.macID == MacID.make(fingerprint: expectedPin),
           client.savedMac(session.macID ?? "")?.fingerprintData == expectedPin {
            if session.route.isRemote { expectedMatched = true }
            else if case .saved(let pin) = session.home, pin == expectedPin { expectedMatched = true }
            else { expectedMatched = false }
        } else { expectedMatched = false }
        let catalog = client.connected && client.visionInputBinding != .awaitingCatalog
        let presented: Bool
        if case .presented = client.visionInputBinding {
            presented = foreground && client.connected && client.active != .none
        } else { presented = false }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        writer.write(VisionAutoConnectStatus(build: build, startupMode: mode, phase: phase,
            savedMacCount: client.savedMacs.count, expectedMacMatched: expectedMatched,
            connected: client.connected, catalogReceived: catalog, presentationReady: presented,
            inputReady: presented && input.canSend, reasonFixed: reason))
        message = friendlyMessage(phase: phase, reason: reason, catalog: catalog, presented: presented)
    }

    private func friendlyMessage(phase: VisionAutoConnectStatus.Phase, reason: VisionCableBootstrapReason?, catalog: Bool, presented: Bool) -> String {
        if !foreground { return "Vision Pro를 착용하고 앱을 앞에 열어 주세요." }
        if reason == .permissionRequired { return "설정에서 CCR Sill의 로컬 네트워크 접근을 허용해 주세요." }
        if phase == .connected {
            if presented { return "Mac 화면이 준비되었습니다." }
            return catalog ? "Mac에 연결되었습니다. 표시할 화면을 선택해 주세요." : "Mac 화면 정보를 기다리고 있습니다."
        }
        switch phase {
        case .bootstrapDialing, .bootstrapAsking: return "케이블로 Mac 연결을 준비하고 있습니다."
        case .paired, .connecting: return "저장된 Mac에 연결하고 있습니다."
        case .stopped:
            if reason == .macLocked { return "Mac의 잠금을 해제한 뒤 앱을 다시 열어 주세요." }
            if reason == .keyUnavailable { return "Vision Pro의 잠금을 해제한 뒤 앱을 다시 열어 주세요." }
            return "Mac 연결을 완료하지 못했습니다. 연결 상태를 확인한 뒤 앱을 다시 열어 주세요."
        default:
            return client.savedMacs.isEmpty ? "Mac과 케이블을 연결하고 연결 준비를 마쳐 주세요." : "저장된 Mac을 찾고 있습니다."
        }
    }
}
