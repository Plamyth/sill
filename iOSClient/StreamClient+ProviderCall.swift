#if os(iOS)
import Foundation
import Network
import UIKit
import StreamProtocol

extension StreamClient {
    var providerCallTrustedHostKey: String? {
        desiredAudioIdentity?.pin.map { String(format: "%02x", $0) }.joined()
    }

    var providerCallRegistered: Bool {
        guard !inputPaused, let peer = connection, connected, appInForeground,
              UIApplication.shared.applicationState == .active,
              authenticatedMacAudioRoutePeer == ObjectIdentifier(peer),
              providerCallPeer == ObjectIdentifier(peer), providerCall.hostKey == providerCallTrustedHostKey,
              desiredAudio.privacy == .protected, audioForwarding.phase != .blocked,
              let context = audioForwardingContext, context == audioForwarding.context,
              let catalog = audioForwarding.catalog, catalog.role == .viewer,
              catalog.principal.id == context.device,
              catalog.bootstrap.credential.pairedDeviceId == context.device else { return false }
        return true
    }

    private func providerCallOwnsBinding(for action: ProviderCallRequest.Action) -> Bool {
        guard providerCallRegistered, !audioAdmission.forwardingFaulted,
              let context = audioForwardingContext, let snapshot = audioForwarding.snapshot,
              let binding = audioForwarding.binding, binding == snapshot.binding,
              binding.pairedDeviceId == context.device, binding.transportKind == .native,
              let durable = audioForwarding.durable, durable.device == context.device,
              binding.intentGeneration == durable.generation,
              desiredAudio.selection == durable.selection,
              snapshot.intent?.pairedDeviceId == context.device,
              snapshot.intent?.intentId == durable.intentID,
              snapshot.intent?.intentGeneration == durable.generation else { return false }
        if action == .start {
            guard (!desiredAudio.selection.microphone || desiredAudio.sessionPermits(.microphone)) &&
                  (!desiredAudio.selection.playback || desiredAudio.sessionPermits(.playback)) else { return false }
        }
        if action == .stop && binding.phase == .off { return audioForwarding.phase == .ready }
        guard binding.phase == .active, audioForwarding.phase == .active,
              let deadline = audioForwarding.mediaDeadline, audioForwardingNow < deadline else { return false }
        return true
    }

    var iPadProviderCanStart: Bool {
        providerCall.canPerform && providerCall.result?.status != .started && providerCallOwnsBinding(for: .start)
    }
    var iPadProviderCanStop: Bool {
        providerCall.canPerform && providerCall.result?.status == .started &&
            providerCall.result?.callSessionId != nil && providerCallOwnsBinding(for: .stop)
    }
    var iPadProviderCanCheckPrevious: Bool { providerCallRegistered && providerCall.canManuallyQuery }

    func performIPadProviderCall(_ action: ProviderCallRequest.Action, target: IPadCallTarget) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard target.supportsProviderCall, action == .start ? iPadProviderCanStart : iPadProviderCanStop,
              let peer = connection, let snapshot = audioForwarding.snapshot,
              let device = audioForwardingDevice,
              let request = try? ProviderCallRequest(requestId: UUID(), action: action,
                expectedLeaseRevision: snapshot.revision, pairedDeviceId: device,
                desiredInput: desiredAudio.selection.microphone, desiredOutput: desiredAudio.selection.playback,
                callSessionId: action == .stop ? providerCall.result?.callSessionId : nil),
              request.matches(snapshot), let control = providerCall.perform(request) else { return }
        sendIPadProviderCall(control, to: peer)
    }

    func checkPreviousIPadProviderCall(target: IPadCallTarget) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard target.supportsProviderCall, iPadProviderCanCheckPrevious, let peer = connection,
              let control = providerCall.manualQuery() else { return }
        providerCallQueryWake?.cancel(); providerCallQueryWake = nil
        sendIPadProviderCall(control, to: peer)
    }

    func providerCallSetConnection(_ next: NWConnection?) {
        let identity = next.map(ObjectIdentifier.init)
        guard identity != providerCallPeer else { return }
        providerCallPeer = identity
        providerCallCapability = nil
        providerCallConnection = UUID()
        providerCall.observe(connection: providerCallConnection, capability: nil, hostKey: nil)
        providerCallQueryWake?.cancel(); providerCallQueryWake = nil
    }

    func observeIPadProviderCalls(_ list: WindowList, from peer: NWConnection) {
        guard connection === peer else { return }
        providerCallCapability = list.providerCalls
        reconcileIPadProviderCall()
    }

    func reconcileIPadProviderCall() {
        dispatchPrecondition(condition: .onQueue(.main))
        providerCall.observe(connection: providerCallConnection, capability: providerCallCapability,
                             hostKey: providerCallTrustedHostKey)
        guard providerCallRegistered, let peer = connection, providerCallQueryWake == nil,
              providerCall.needsAutomaticQuery else { return }
        let generation = providerCallConnection
        let work = DispatchWorkItem { [weak self, weak peer] in
            guard let self else { return }
            self.providerCallQueryWake = nil
            guard let peer, self.connection === peer, self.providerCallConnection == generation,
                  self.providerCallRegistered, let control = self.providerCall.query() else { return }
            self.sendIPadProviderCall(control, to: peer)
        }
        providerCallQueryWake = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func sendIPadProviderCall(_ control: ProviderCallControl, to peer: NWConnection) {
        let generation = providerCallConnection
        guard connection === peer, providerCallRegistered, providerCall.connection == generation,
              let pending = providerCall.pending else { return }
        let payload = Wire.encode(control)
        guard !payload.isEmpty, payload.count <= StreamMessage.clientPayloadLimit(for: .providerCallControl) else { return }
        peer.send(content: StreamMessage(kind: .providerCallControl, timestamp: Date().timeIntervalSince1970,
            isKeyframe: false, payload: payload).serialized(), completion: .contentProcessed { [weak self, weak peer] error in
                guard let error else { return }
                DispatchQueue.main.async { [weak self, weak peer] in
                    guard let self, let peer, self.connection === peer, self.providerCallConnection == generation else { return }
                    peer.cancel()
                    self.connectionLost(peer, error: error)
                }
            })
        let remaining = max(0, pending.expiresAt - audioForwardingNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak peer] in
            guard let self, let peer, self.connection === peer, self.providerCallConnection == generation,
                  self.providerCall.timeout(pending) else { return }
            peer.cancel()
            self.connectionLost(peer, error: .posix(.ETIMEDOUT))
        }
    }

    func receiveIPadProviderCall(_ header: StreamHeader, _ data: Data, from peer: NWConnection) -> Bool {
        guard header.kind == .providerCallState else { return false }
        DispatchQueue.main.async { [weak self, weak peer] in
            guard let self, let peer, self.connection === peer,
                  data.count <= StreamMessage.hostPayloadLimit(for: .providerCallState),
                  let state = Wire.decode(ProviderCallState.self, from: data) else { return }
            if self.providerCallRegistered {
                guard self.providerCall.receive(state, from: self.providerCallConnection) else { return }
                self.reconcileIPadProviderCall()
            } else {
                _ = self.providerCall.drain(state, from: self.providerCallConnection)
            }
        }
        return true
    }
}
#endif
