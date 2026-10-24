#if os(iOS)
import Foundation
import Network
import Security
import StreamProtocol

final class IPadEnrollmentHTTPPost: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private var done: ((Result<IPadDeviceEnrollment.HTTPReply, Error>) -> Void)?

    static func post(_ route: IPadDeviceEnrollment.Route, body: Data,
                     done: @escaping (Result<IPadDeviceEnrollment.HTTPReply, Error>) -> Void) -> IPadDeviceEnrollment.Cancel {
        let operation = IPadEnrollmentHTTPPost()
        operation.done = done
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 10
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        let session = URLSession(configuration: configuration, delegate: operation, delegateQueue: nil)
        operation.session = session
        let url = URL(string: IPadEnrollmentProtocol.origin + route.rawValue)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let task = session.dataTask(with: request); operation.task = task; task.resume()
        return { session.invalidateAndCancel() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              response.url == dataTask.originalRequest?.url,
              response.expectedContentLength <= 4096 else { completionHandler(.cancel); return }
        self.response = response; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= 4096 else { task?.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let callback = done; done = nil
        if error == nil, let response {
            callback?(.success(.init(status: response.statusCode,
                contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "", body: bytes)))
        } else { callback?(.failure(IPadEnrollmentFailure.unavailable)) }
        session.finishTasksAndInvalidate(); self.session = nil; self.task = nil
    }
}

final class IPadOwnerReceiptTransport {
    private let queue: DispatchQueue
    private let profile: OwnerMacBootstrap
    private let identity: RemoteIdentity
    private let binding: IPadEnrollmentProtocol.Binding
    private let current: () -> Bool
    private var connector: RemoteConnector?
    private var exchange: IPadOwnerReceiptExchange?
    private var completion: ((Result<Data, Error>) -> Void)?
    private var deadline: DispatchWorkItem?
    private var stopped = false
    init(queue: DispatchQueue, profile: OwnerMacBootstrap, identity: RemoteIdentity,
         binding: IPadEnrollmentProtocol.Binding, current: @escaping () -> Bool) {
        self.queue = queue; self.profile = profile; self.identity = identity; self.binding = binding; self.current = current
    }
    func start(_ challenge: IPadEnrollmentProtocol.Challenge, name: String, model: String,
               done: @escaping (Result<Data, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard !stopped, completion == nil, current() else { done(.failure(IPadEnrollmentFailure.stale)); return }
        completion = done
        do {
            let request = try IPadEnrollmentProtocol.ownerRequest(challenge, binding: binding, name: name, model: model)
            let candidates = profile.addresses.map { RemoteDialPolicy.Candidate(host: $0, port: profile.remotePort, kind: MacAddress.vpn, via: "Tailscale") }
            let dial = RemoteConnector(candidates: candidates, mode: .ownerBootstrap(pin: binding.hostPin), identity: identity, queue: queue)
            connector = dial
            let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(IPadEnrollmentFailure.unavailable)) }
            self.deadline = deadline; DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: deadline)
            dial.onWinner = { [weak self] winner in
                DispatchQueue.main.async {
                    guard let self, !self.stopped, self.current(), winner.fingerprint == self.binding.hostPin else { winner.connection.cancel(); return }
                    self.connector = nil
                    let exchange = IPadOwnerReceiptExchange(connection: winner.connection, pin: self.binding.hostPin,
                        request: request, queue: self.queue)
                    self.exchange = exchange
                    exchange.start { [weak self] reply in
                        DispatchQueue.main.async {
                            guard let self, !self.stopped, self.current() else { return }
                            do { self.finish(.success(try IPadEnrollmentProtocol.ownerReply(reply.get(), binding: self.binding))) }
                            catch { self.finish(.failure(error)) }
                        }
                    }
                }
            }
            dial.onFailed = { [weak self] _ in DispatchQueue.main.async { self?.finish(.failure(IPadEnrollmentFailure.unavailable)) } }
            dial.start()
        } catch { finish(.failure(error)) }
    }
    func cancel() {
        precondition(Thread.isMainThread)
        finish(.failure(IPadEnrollmentFailure.cancelled))
    }
    private func finish(_ result: Result<Data, Error>) {
        guard !stopped else { return }; stopped = true
        deadline?.cancel(); deadline = nil; connector?.cancel(); connector = nil; exchange?.cancel(); exchange = nil
        let done = completion; completion = nil; done?(result)
    }
}

final class IPadOwnerReceiptExchange {
    private let connection: NWConnection
    private let pin: Data
    private let request: Data
    private let queue: DispatchQueue
    private let permit = OwnerBootstrapSendPermit()
    private var started = false
    private var finished = false
    private var completion: ((Result<Data, Error>) -> Void)?
    private var deadline: DispatchWorkItem?
    init(connection: NWConnection, pin: Data, request: Data, queue: DispatchQueue) {
        self.connection = connection; self.pin = pin; self.request = request; self.queue = queue
    }
    func cancel() { permit.cancel(); queue.async { [self] in finish(.failure(IPadEnrollmentFailure.cancelled)) } }
    func start(_ done: @escaping (Result<Data, Error>) -> Void) {
        queue.async { [self] in
            guard !started, !finished else { return }; started = true; completion = done
            guard RemoteTLS.negotiatedALPN(connection) == OwnerMacBootstrap.alpn, RemoteTLS.peerFingerprint(connection) == pin else {
                finish(.failure(IPadEnrollmentFailure.invalid)); return
            }
            let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(IPadEnrollmentFailure.unavailable)) }
            deadline = timeout; queue.asyncAfter(deadline: .now() + 5, execute: timeout)
            connection.stateUpdateHandler = { [weak self] state in
                switch state { case .failed, .cancelled, .waiting: self?.finish(.failure(IPadEnrollmentFailure.unavailable)); default: break }
            }
            let message = StreamMessage(kind: .pairRequest, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: request)
            guard permit.sendIfAllowed({
                connection.send(content: message.serialized(), completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.finish(.failure(IPadEnrollmentFailure.unavailable)) }
                })
            }) else { finish(.failure(IPadEnrollmentFailure.cancelled)); return }
            if !finished { readHeader() }
        }
    }
    private func readHeader() {
        connection.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [self] data, _, ended, error in
            guard !finished else { return }
            guard error == nil, !ended, let data, let header = StreamMessage.parseHeader(data),
                  data.count == StreamMessage.headerLength, data[data.startIndex + 9] == 0,
                  header.kind == .pairResult, header.timestamp.isFinite, !header.isKeyframe, header.payloadLength > 0,
                  header.payloadLength <= StreamMessage.maxPairingPayload else { finish(.failure(IPadEnrollmentFailure.invalid)); return }
            connection.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { [self] data, _, _, error in
                guard !finished else { return }
                guard error == nil, let data, data.count == header.payloadLength,
                      RemoteTLS.negotiatedALPN(connection) == OwnerMacBootstrap.alpn,
                      RemoteTLS.peerFingerprint(connection) == pin else { finish(.failure(IPadEnrollmentFailure.invalid)); return }
                finish(.success(data))
            }
        }
    }
    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }; finished = true
        permit.cancel(); deadline?.cancel(); deadline = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        let done = completion; completion = nil; done?(result)
    }
}
#endif
