import Foundation
import Network
import StreamProtocol

final class OwnerBootstrapExchange {
    private let connection: NWConnection
    private let profile: OwnerMacBootstrap
    private let name: String
    private let model: String
    private let queue: DispatchQueue
    private let sendPermit = OwnerBootstrapSendPermit()
    private var finished = false
    private var started = false
    private var deadline: DispatchWorkItem?
    private var completion: ((PairResult?) -> Void)?

    init(connection: NWConnection, profile: OwnerMacBootstrap, name: String, model: String, queue: DispatchQueue) {
        self.connection = connection; self.profile = profile; self.name = name; self.model = model; self.queue = queue
    }

    func cancel() {
        sendPermit.cancel()
        queue.async { [self] in finish(nil, report: false) }
    }

    func start(done: @escaping (PairResult?) -> Void) {
        queue.async { [self] in
            guard !finished, !started else { return }
            started = true
            completion = done
            guard RemoteTLS.negotiatedALPN(connection) == OwnerMacBootstrap.alpn,
                  RemoteTLS.peerFingerprint(connection) == profile.fingerprintData else { finish(nil); return }
            let timeout = DispatchWorkItem { [weak self] in self?.finish(nil) }
            deadline = timeout
            queue.asyncAfter(deadline: .now() + RemoteDialPolicy.pairingReplyDeadline, execute: timeout)
            connection.stateUpdateHandler = { [weak self] state in
                switch state { case .failed, .cancelled, .waiting: self?.finish(nil); default: break }
            }
            let request = PairRequest(v: OwnerMacBootstrap.requestVersion, method: OwnerMacBootstrap.method,
                                      proof: "", name: name, model: model)
            let message = StreamMessage(kind: .pairRequest, timestamp: Date().timeIntervalSince1970,
                                        isKeyframe: false, payload: Wire.encode(request))
            guard sendPermit.sendIfAllowed({
                connection.send(content: message.serialized(), completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.finish(nil) }
                })
            }) else { finish(nil, report: false); return }
            if !finished { readHeader() }
        }
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [self] data, _, ended, error in
            guard !finished else { return }
            guard error == nil, !ended, let data, let header = StreamMessage.parseHeader(data),
                  header.kind == .pairResult, header.payloadLength > 0,
                  header.payloadLength <= StreamMessage.maxPairingPayload else { finish(nil); return }
            connection.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { [self] data, _, _, error in
                guard !finished else { return }
                guard error == nil, let data, data.count == header.payloadLength,
                      let result = Wire.decode(PairResult.self, from: data),
                      let pin = RemoteTLS.peerFingerprint(connection),
                      OwnerBootstrapState.accepts(result, profile: profile, peerPin: pin,
                                                  alpn: RemoteTLS.negotiatedALPN(connection)) else { finish(nil); return }
                finish(result)
            }
        }
    }

    private func finish(_ result: PairResult?, report: Bool = true) {
        guard !finished else { return }
        finished = true
        sendPermit.cancel()
        deadline?.cancel(); deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let done = completion
        completion = nil
        if report { done?(result) }
    }
}
