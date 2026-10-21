import Foundation
import Network
import UIKit
import StreamProtocol

#if os(iOS)
extension StreamClient {
    /// 호출자는 최초 자격을 원시 저장 키 정리 전에 한 번만 확보한다.
    func armOwnerBootstrap() {
        ownerBootstrap.arm(savedKeyPresent: UserDefaults.standard.object(forKey: SavedMacs.defaultsKey) != nil,
                           preferredKeyPresent: UserDefaults.standard.object(forKey: Self.ownerPreferredKey) != nil,
                           hasRecords: !savedMacs.isEmpty || savedMacsSeeded,
                           explicitLaunch: CommandLine.arguments.contains { $0.hasPrefix("-Sill") })
    }

    static var ownerPreferredKey: String { "Sill.preferredTrustedMacID" }

    func resumeOwnerBootstrapAfterForeground() {
        ownerBootstrap.foreground(savedKeyPresent: UserDefaults.standard.object(forKey: SavedMacs.defaultsKey) != nil,
                                  preferredKeyPresent: UserDefaults.standard.object(forKey: Self.ownerPreferredKey) != nil,
                                  hasRecords: !savedMacs.isEmpty)
        if ownerBootstrap.phase == .ready { startOwnerBootstrap() }
    }

    func cancelOwnerBootstrap(resumable: Bool = false) {
        if resumable { ownerBootstrap.pause() } else { ownerBootstrap.cancel() }
        ownerBootstrapDial?.cancel()
        ownerBootstrapDial = nil
        ownerBootstrapExchange?.cancel()
        ownerBootstrapExchange = nil
    }

    /// 준비 단계에서만 기다린다. 실패 후에는 활성화 또는 재실행 전까지 재발행하지 않는다.
    func startOwnerBootstrap() {
        guard ownerBootstrap.phase == .ready, appInForeground, !connected, connection == nil, reconnect == nil,
              remoteDial == nil, pairing == .idle, pairingDial == nil, homeAsk == nil,
              overlayAskDialer == nil, overlayAskShown == nil, pendingLink == nil else { return }
        guard savedMacs.isEmpty,
              UserDefaults.standard.object(forKey: SavedMacs.defaultsKey) == nil,
              UserDefaults.standard.object(forKey: Self.ownerPreferredKey) == nil else {
            cancelOwnerBootstrap()
            return
        }
        guard let token = ownerBootstrap.begin() else { return }
        guard let url = Bundle.main.url(forResource: OwnerMacBootstrap.resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let profile = OwnerMacBootstrap.decodeResource(data) else {
            _ = ownerBootstrap.finish(token)
            status = "소유 Mac 연결 설정이 준비되지 않았습니다."
            return
        }
        let identity: RemoteIdentity
        do {
            if let existing = DeviceIdentity.existing() { identity = existing }
            else if DeviceIdentity.knownMissing() { identity = try DeviceIdentity.loadOrCreate() }
            else {
                _ = ownerBootstrap.finish(token)
                status = "iPad 기기 키를 읽을 수 없습니다. 잠금을 해제한 뒤 앱을 다시 활성화하세요."
                return
            }
        } catch {
            _ = ownerBootstrap.finish(token)
            status = "iPad 기기 키를 사용할 수 없습니다. 잠금을 해제한 뒤 앱을 다시 활성화하세요."
            return
        }
        let candidates = profile.addresses.map {
            RemoteDialPolicy.Candidate(host: $0, port: profile.remotePort, kind: MacAddress.vpn, via: "Tailscale")
        }
        let connector = RemoteConnector(candidates: candidates, mode: .ownerBootstrap(pin: profile.fingerprintData),
                                        identity: identity, queue: queue)
        ownerBootstrapDial = connector
        status = "소유 Mac에 안전하게 연결하는 중…"
        let deviceName = UIDevice.current.name
        let deviceModel = ClientStatsReporter.hardwareIdentifier
        connector.onWinner = { [weak self, weak connector] winner in
            DispatchQueue.main.async {
                guard let self, let connector, self.ownerBootstrapDial === connector,
                      self.appInForeground, self.ownerBootstrap.exchange(token) else { winner.connection.cancel(); return }
                self.ownerBootstrapDial = nil
                let exchange = OwnerBootstrapExchange(connection: winner.connection, profile: profile,
                                                      name: deviceName, model: deviceModel, queue: self.queue)
                self.ownerBootstrapExchange = exchange
                exchange.start { [weak self, weak exchange] result in
                    DispatchQueue.main.async {
                        guard let self, let exchange, self.ownerBootstrapExchange === exchange,
                              self.appInForeground, self.ownerBootstrap.finish(token) else { return }
                        self.ownerBootstrapExchange = nil
                        guard let result, self.savedMacs.isEmpty,
                              UserDefaults.standard.object(forKey: SavedMacs.defaultsKey) == nil,
                              UserDefaults.standard.object(forKey: Self.ownerPreferredKey) == nil,
                              OwnerBootstrapState.accepts(result, profile: profile, peerPin: winner.fingerprint,
                                                          alpn: OwnerMacBootstrap.alpn) else {
                            self.status = "소유 Mac의 자동 연결 승인을 확인하지 못했습니다. 앱을 다시 활성화하면 재시도합니다."
                            return
                        }
                        self.saveOwnerBootstrap(result, profile: profile, lastWorked: winner.candidate.key)
                    }
                }
            }
        }
        connector.onFailed = { [weak self, weak connector] _ in
            DispatchQueue.main.async {
                guard let self, let connector, self.ownerBootstrapDial === connector,
                      self.ownerBootstrap.finish(token) else { return }
                self.ownerBootstrapDial = nil
                self.status = "소유 Mac에 연결하지 못했습니다. Tailscale 연결을 확인한 뒤 앱을 다시 활성화하세요."
            }
        }
        connector.start()
    }

    func saveOwnerBootstrap(_ result: PairResult, profile: OwnerMacBootstrap, lastWorked: String) {
        // 주소·포트는 응답에서 만들지 않는다. 정식 세션의 SignedMacInfo만 이후 갱신할 수 있다.
        let label = SafeText.label(result.name ?? "소유 Mac")
        let mac = SavedMac(macID: profile.macID, fingerprint: profile.fingerprint,
                           name: label.isEmpty ? "소유 Mac" : label, recognitionKey: result.recognitionKey!,
                           remotePort: profile.remotePort,
                           addresses: profile.addresses.map { MacAddress(host: $0, kind: MacAddress.vpn, via: "Tailscale") },
                           infoIssuedAt: 0, lastWorked: lastWorked, pairedAt: Date(), method: OwnerMacBootstrap.method,
                           homeTLS: true)
        savedMacs = SavedMacs.adding(mac, to: savedMacs)
        persistSavedMacs()
        rememberPreferredMac(mac.macID)
        dialSaved(mac.macID, why: .afterPairing)
    }
}
#endif

/// 실제 등록 교환 소켓은 dial winner와 별도로 소유한다. 모든 소켓 작업은 network queue에서 직렬화한다.
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
