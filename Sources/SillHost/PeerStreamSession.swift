import Foundation
import CoreGraphics
import StreamProtocol

@MainActor
final class PeerStreamSession {
    private(set) var state = PeerStreamState()
    private(set) var description: PeerCaptureDescription?
    private(set) var admission = SourcePublicationAdmission()
    private let driver: any PeerCaptureDriver
    private let configuration: () -> HostConfig
    private let inventory: () -> DisplayInventory
    private var viewport: Viewport?
    private var worker: Task<Void, Never>?
    private var desired: PeerStreamState.Ticket?
    private var transportEpoch: UUID?
    private var displayIdentity: String?
    private var recoveryAttempted = false
    private var launchIntent: (UUID, String)?
    var supportsScopedInput = false
    var onChanged: (() -> Void)?
    var onScopeInvalidated: (() -> Void)?
    var prepare: ((VideoEpoch, SourcePublicationAdmission) -> Void)?
    var commit: ((VideoEpoch, SourcePublicationAdmission, @escaping () -> Void) -> Void)?
    var output: ((StreamMessage, UUID) -> Void)?
    var reset: ((UUID?) -> Void)?

    init(driver: any PeerCaptureDriver, configuration: @escaping () -> HostConfig,
         inventory: @escaping () -> DisplayInventory) {
        self.driver = driver
        self.configuration = configuration
        self.inventory = inventory
        driver.onStopped = { [weak self] in self?.captureStopped() }
    }

    var source: StreamSource { state.source }
    var epoch: VideoEpoch? { state.epoch }
    var generation: String { state.generation }
    var selectionRevision: String { state.revision }
    var incarnation: UUID { state.incarnation }
    var isClosed: Bool { state.closed }
    var softwareEncoder: Bool { driver.usesSoftwareEncoder }
    var currentDisplayID: UInt32? { state.display?.displayID }

    func select(_ request: SourceRequest) {
        let snapshot = inventory()
        let display: DisplaySelection?
        if request.source == .desktop {
            let id = state.display?.displayID ?? snapshot.infos.first(where: \.isMain)?.id
            display = id.flatMap { id in snapshot.revision.map { DisplaySelection(displayID: id, inventoryID: $0) } }
        } else { display = nil }
        select(source: request.source, display: display, origin: request.origin, revision: request.selectionRevision)
    }

    func selectDisplay(_ request: DisplaySelection) {
        select(source: .desktop, display: request, origin: request.origin, revision: request.selectionRevision)
    }

    private func select(source: StreamSource, display: DisplaySelection?, origin: SourceRequest.Origin?, revision: String?) {
        guard !state.closed else { return }
        // A repeat of the already presented source is observational; it does not replace an encoder.
        if origin != .automatic, state.pending == nil, state.epoch != nil, state.source == source,
           (source != .desktop || (state.display?.displayID == display?.displayID &&
                display.flatMap { inventory().identity(of: $0.displayID) } == displayIdentity)),
           driver.currentBounds() == description?.bounds {
            onChanged?()
            return
        }
        let snapshot = inventory()
        guard let ticket = state.request(source, display: display, origin: origin, revision: revision, inventory: snapshot) else {
            onChanged?()
            return
        }
        launchIntent = nil
        displayIdentity = display.flatMap { snapshot.identity(of: $0.displayID) }
        recoveryAttempted = false
        enqueue(ticket)
    }

    private func enqueue(_ ticket: PeerStreamState.Ticket) {
        admission.invalidate()
        admission = SourcePublicationAdmission()
        onScopeInvalidated?()
        resetTransport()
        desired = ticket
        onChanged?()
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.runSelections() }
    }

    private func resetTransport() {
        let previous = transportEpoch
        transportEpoch = nil
        reset?(previous)
    }

    private func runSelections() async {
        defer { worker = nil }
        while let ticket = desired {
            desired = nil
            await driver.stop()
            description = nil
            guard state.isCurrent(ticket) else { continue }
            if ticket.source == .none {
                _ = state.commit(ticket, epoch: nil)
                onChanged?()
                continue
            }
            let publication = admission
            do {
                let resolved = try await driver.resolve(source: ticket.source, display: ticket.display,
                    identity: displayIdentity, config: configuration(), viewport: viewport)
                guard state.isCurrent(ticket) else { continue }
                if let display = ticket.display {
                    guard inventory().identity(of: display.displayID) == displayIdentity else { throw NativePeerCaptureDriver.Failure.changed }
                }
                let rect = resolved.bounds
                let epoch = VideoEpoch(generation: UUID().uuidString, source: ticket.source,
                    geometry: .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                    width: resolved.width, height: resolved.height)
                guard epoch.isValid else { throw NativePeerCaptureDriver.Failure.invalidGeometry }
                transportEpoch = epoch.id
                prepare?(epoch, publication)
                let emit = output
                try await driver.start(resolved, epoch: epoch) { message, id in
                    publication.publish { emit?(message, id) }
                }
                guard state.isCurrent(ticket) else {
                    await driver.stop()
                    continue
                }
                guard driver.currentBounds() == resolved.bounds else { throw NativePeerCaptureDriver.Failure.changed }
                guard state.commit(ticket, epoch: epoch) else { continue }
                description = resolved
                commit?(epoch, publication, { [weak driver] in Task { @MainActor in driver?.requestKeyframe() } })
                onChanged?()
            } catch {
                await driver.stop()
                guard state.isCurrent(ticket) else { continue }
                publication.invalidate()
                admission = SourcePublicationAdmission()
                state.fail(ticket, reason: "선택한 화면을 현재 위치에서 캡처할 수 없습니다.")
                resetTransport()
                onChanged?()
            }
        }
    }

    func updateViewport(_ value: Viewport) {
        guard value.width.isFinite, value.height.isFinite, value.width > 0, value.height > 0,
              value.width <= 32768, value.height <= 32768 else { return }
        let changedFPS = (viewport?.fps ?? 60) != (value.fps ?? 60)
        viewport = value
        // Panel size and scale never resize or move a Mac window.
        if changedFPS { restartPresentedSource() }
    }

    func configurationChanged() { restartPresentedSource() }

    func catalogChanged() {
        guard !state.closed, state.pending == nil, let description else { return }
        let snapshot = inventory()
        if let id = currentDisplayID, snapshot.identity(of: id) != displayIdentity {
            select(SourceRequest(source: .none, origin: .human))
            return
        }
        guard let bounds = driver.currentBounds() else {
            select(SourceRequest(source: .none, origin: .human))
            return
        }
        if bounds != description.bounds { restartPresentedSource() }
    }

    private func restartPresentedSource() {
        guard state.pending == nil, state.source != .none else { return }
        let snapshot = inventory()
        let display = state.display.flatMap { old in snapshot.revision.map { DisplaySelection(displayID: old.displayID, inventoryID: $0) } }
        guard let ticket = state.request(state.source, display: display, origin: .human, revision: nil, inventory: snapshot) else { return }
        enqueue(ticket)
    }

    private func captureStopped() {
        guard !state.closed, state.pending == nil, state.source != .none else { return }
        if recoveryAttempted {
            select(SourceRequest(source: .none, origin: .human))
        } else {
            recoveryAttempted = true
            restartPresentedSource()
        }
    }

    func beginLaunch(_ bundle: String) -> UUID {
        let token = UUID()
        launchIntent = (token, bundle)
        return token
    }

    func finishLaunch(_ token: UUID, windowID: UInt32?) {
        guard launchIntent?.0 == token, !state.closed else { return }
        launchIntent = nil
        if let windowID { select(SourceRequest(source: .window(windowID), origin: .human)) }
    }

    func requestKeyframe() { driver.requestKeyframe() }

    func inputRect(generation: String?, epoch: UUID?) -> CGRect? {
        guard state.accepts(generation: generation, epoch: epoch), let description,
              let live = driver.currentBounds(), live == description.bounds else { return nil }
        return live
    }

    func decorate(_ list: inout WindowList) {
        let snapshot = inventory()
        list.active = state.source
        list.inputGeneration = state.generation
        list.videoEpoch = state.epoch
        list.selectionRevision = state.revision
        list.automaticDisplaySelection = 1
        list.independentStreams = 1
        list.sourceSelectionEffects = 0
        list.sourceSelectionFailure = state.failure
        list.displayInventoryID = snapshot.revision
        list.activeDisplayID = state.epoch == nil ? nil : state.display?.displayID
        list.desktopSelectionRequired = state.source != .desktop || state.epoch == nil
        list.displays = snapshot.infos
        list.microphone = nil
    }

    func invalidateForShutdown() {
        admission.invalidate()
        desired = nil
        onScopeInvalidated?()
    }

    func close() async {
        guard !state.closed else { return }
        state.close()
        launchIntent = nil
        desired = nil
        admission.invalidate()
        onScopeInvalidated?()
        resetTransport()
        await worker?.value
        await driver.stop()
        description = nil
    }
}
