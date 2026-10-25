    enum MoveKind { case fromDirect, fromRemote, toCable, toWifi }
    struct Move { let connection: NWConnection }
    var moving: Move?
    var visionMovePreparation: UUID?
    let visionInputSession: MemoryMoveInput? = MemoryMoveInput()
    var inputDrain: (() -> Void)?
    func cancelVisionInputs(completion: @escaping () -> Void) { inputDrain = completion }
    var connectedDirectly = false
    var sessionDead = false
    var resumeSource: MemorySource?
    var active = MemorySource.screen
    let pointerFeed = MemoryPointerFeed()
    var failedUps: Int?
    var homeMoveName: String?
    var hostName = "검사 Mac"
    var homeMoveTrust: Int?
    var homeMoveRow: Int?
    var remoteRoute: Int?
    var homeInfo = DiscoveryPolicy.HomeMoveInfo()
    var failedHomeMoves: Int?
    struct PathSignals {}
    var pathSignals = PathSignals()
    var lastPongAt: Double = 0
    var status = ""
    let settings = MemoryMoveSettings()
    var settingsProblem: Int?
    var settingsExpiry: DispatchWorkItem?
    var lastRttMaxMs: Int?
    var connectedAt: Date?
    var lastAutoDesktop = Date.distantPast
    var lastViewport: Int? = 1
    var homeMoveViewport: Int?
    static let fenceTimeout: Double = 180
    enum MoveInputBinding { case awaitingCatalog }
    var visionInputBinding = MoveInputBinding.awaitingCatalog
    var peerResets = 0
    func resetVisionPeerStreams() { peerResets += 1 }
    func bindVisionSentry(to: NWConnection) {}
    func bindVisionDisplays(to: NWConnection) {}
    func bindVisionTestDestinations(to: NWConnection) {}
    func resetVisionAudio() {}
    func persistSavedMacs() {}
    func setRoute(from: Int, fresh: Bool) {}
    func startMeasuring(_ connection: NWConnection, remote: Bool) {}
    func deliver(_ header: StreamHeader, _ data: Data, from: NWConnection) {}
    func startReading(_ connection: NWConnection) {}
    let viewportBytes = Data([0x7f, 0x11])
    func sendViewport(_ value: Int) { link.send(viewportBytes) }
    var menuPeers: [ObjectIdentifier] = []
    func menusMoved() { if let connection { menuPeers.append(ObjectIdentifier(connection)) } }
    func closeSoon(_ peers: [NWConnection]) { peers.forEach { $0.cancel() } }
    func fenceEnded(_ peer: NWConnection, _ released: SessionLink.Released, why: String) { closeSoon(released.close) }
    func updateDiscovery() {}
    func followBestPath() {}
