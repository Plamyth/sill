import Foundation
import Network
import UIKit
import StreamProtocol

#if os(visionOS)
extension StreamClient {
    /// 호출자는 최초 자격을 원시 저장 키 정리 전에 한 번만 확보한다.
    func armOwnerBootstrap() {
        guard !VisionReleaseTestContext.isTestBundle else { return }
        ownerBootstrap.arm(savedKeyPresent: UserDefaults.standard.object(forKey: SavedMacs.defaultsKey) != nil,
                           preferredKeyPresent: UserDefaults.standard.object(forKey: Self.ownerPreferredKey) != nil,
                           hasRecords: !savedMacs.isEmpty || savedMacsSeeded,
                           explicitLaunch: CommandLine.arguments.contains { $0.hasPrefix("-Sill") } || !visionOwnerBootstrapIsOrdinary)
    }

    private var visionOwnerBootstrapIsOrdinary: Bool {
        if case .ordinary = visionCableBootstrap.launch { return true }
        return false
    }

    static var ownerPreferredKey: String { "Sill.preferredTrustedMacID" }

    func resumeOwnerBootstrapAfterForeground() {
        guard !VisionReleaseTestContext.isTestBundle, !visionWindowRetired,
              appInForeground, visionStartupForeground else { return }
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
        guard !VisionReleaseTestContext.isTestBundle, !visionWindowRetired, visionOwnerBootstrapIsOrdinary,
              ownerBootstrap.phase == .ready, appInForeground, visionStartupForeground,
              let lease = visionDisplaySelection.lease, !connected, connection == nil, reconnect == nil,
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
                status = "Vision Pro 기기 키를 읽을 수 없습니다. 잠금을 해제한 뒤 앱을 다시 활성화하세요."
                return
            }
        } catch {
            _ = ownerBootstrap.finish(token)
            status = "Vision Pro 기기 키를 사용할 수 없습니다. 잠금을 해제한 뒤 앱을 다시 활성화하세요."
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
                guard let self, let connector, self.ownerBootstrapDial === connector else {
                    winner.connection.cancel()
                    return
                }
                guard self.visionOwnerBootstrapScopeIsCurrent(lease: lease, devicePin: identity.fingerprint) else {
                    winner.connection.cancel()
                    self.cancelOwnerBootstrap()
                    return
                }
                guard self.ownerBootstrap.exchange(token) else { winner.connection.cancel(); return }
                self.ownerBootstrapDial = nil
                let exchange = OwnerBootstrapExchange(connection: winner.connection, profile: profile,
                                                      name: deviceName, model: deviceModel, queue: self.queue)
                self.ownerBootstrapExchange = exchange
                exchange.start { [weak self, weak exchange] result in
                    DispatchQueue.main.async {
                        guard let self, let exchange, self.ownerBootstrapExchange === exchange else { return }
                        guard self.visionOwnerBootstrapScopeIsCurrent(lease: lease, devicePin: identity.fingerprint) else {
                            self.cancelOwnerBootstrap()
                            return
                        }
                        guard self.ownerBootstrap.finish(token) else { return }
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

    private func visionOwnerBootstrapScopeIsCurrent(lease: VisionWindowLease, devicePin: Data) -> Bool {
        appInForeground && visionStartupForeground && !visionWindowRetired && visionDisplaySelection.lease == lease
            && DeviceIdentity.existing()?.fingerprint == devicePin && savedMacs.isEmpty
            && UserDefaults.standard.object(forKey: SavedMacs.defaultsKey) == nil
            && UserDefaults.standard.object(forKey: Self.ownerPreferredKey) == nil
            && !connected && connection == nil && reconnect == nil && remoteDial == nil
            && pairing == .idle && pairingDial == nil && homeAsk == nil && homeDialer == nil
    }

    private func saveOwnerBootstrap(_ result: PairResult, profile: OwnerMacBootstrap, lastWorked: String) {
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

