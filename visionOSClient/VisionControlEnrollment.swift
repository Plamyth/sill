import Foundation
import Combine

@MainActor
final class VisionControlEnrollmentController: ObservableObject {
    @Published private(set) var message = "현재 신뢰 Mac의 안전한 연결을 기다립니다."
    @Published private(set) var registeredOrigin: String?
    private weak var client: StreamClient?
    private let events: ControlEventsController
    private var credential: IPadEnrollmentProtocol.Credential?
    private var generation = UUID()
    private var expiry: DispatchWorkItem?
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void

    init(events: ControlEventsController, client: StreamClient,
         now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.events = events; self.client = client
        self.now = now; self.schedule = schedule
        client.ownerEnrollmentChanged = { [weak self] result in
            MainActor.assumeIsolated { self?.receive(result) }
        }
    }

    func reconnect() { client?.resumeOwnerEnrollment() }

    func receive(_ result: Result<IPadEnrollmentProtocol.Credential, Error>?) {
        guard let result else { invalidate(); return }
        switch result {
        case .success(let grant):
            guard client?.ownerEnrollmentCredential == grant else { invalidate(); return }
            guard credential != grant || !events.configured else { return }
            credential = grant
            generation = UUID()
            events.configure(gateway(grant, generation: generation))
            registeredOrigin = IPadEnrollmentProtocol.origin
            message = "현재 신뢰 Mac과 이 Vision Pro의 기기 키로 자동 등록했습니다. 작업 상태만 구독합니다."
            scheduleExpiry(grant, generation: generation)
        case .failure(let error):
            invalidate()
            if case IPadEnrollmentFailure.server(_, let reason) = error,
               ["DEVICE_REVOKED", "OWNER_TRUST_DENIED"].contains(reason) {
                message = "Mac 신뢰 또는 기기 등록이 철회되어 자동 연결을 중지했습니다."
            } else {
                message = "자동 등록을 확인하지 못했습니다. Mac 연결·공개 연결 설정·기기 잠금을 확인하세요. 다른 Mac으로 자동 전환하지 않습니다."
            }
        }
    }

    private func invalidate() {
        expiry?.cancel(); expiry = nil
        generation = UUID(); credential = nil; registeredOrigin = nil
        events.configure(nil)
        message = "현재 신뢰 Mac의 안전한 연결을 기다립니다. 저장된 수동 등록 정보는 자동 인증에 사용하지 않습니다."
    }

    private func gateway(_ grant: IPadEnrollmentProtocol.Credential, generation: UUID) -> ControlEventsGateway {
        var gateway = ControlEventsGateway(eventsURL: URL(string: IPadEnrollmentProtocol.origin + "/v1/events")!,
            credentialHeader: "Authorization", authenticatedRequest: { [weak self] in
                try MainActor.assumeIsolated {
                    guard let self, self.generation == generation, self.credential == grant,
                          self.client?.ownerEnrollmentCredential == grant, let client = self.client else {
                        throw IPadEnrollmentFailure.stale
                    }
                    return try client.ownerEnrollmentAuthorizedRequest(path: "/v1/events", method: "GET")
                }
            })
        gateway.recoverAuthentication = { [weak self] refusal, allowRenewal in
            guard let self, self.generation == generation, self.credential == grant,
                  refusal.authorization == grant.authorizationValue, let client = self.client else { return nil }
            self.expiry?.cancel(); self.expiry = nil
            let result: Result<IPadEnrollmentProtocol.Credential, Error> = await withCheckedContinuation { continuation in
                client.ownerEnrollmentUnauthorized(grant, status: refusal.status, body: refusal.body, allowRenewal: allowRenewal) {
                    continuation.resume(returning: $0)
                }
            }
            guard self.generation == generation, self.credential == grant else { return nil }
            if !allowRenewal {
                if case .failure = result { self.receive(result) }
                else { self.invalidate() }
                return nil
            }
            guard case .success(let renewed) = result, renewed != grant,
                  client.ownerEnrollmentCredential == renewed else {
                self.receive(result)
                return nil
            }
            self.credential = renewed
            self.registeredOrigin = IPadEnrollmentProtocol.origin
            self.message = "기기 등록 갱신을 확인했습니다. 작업 상태에 한 번 다시 연결합니다."
            self.scheduleExpiry(renewed, generation: generation)
            return self.gateway(renewed, generation: generation)
        }
        return gateway
    }

    private func scheduleExpiry(_ grant: IPadEnrollmentProtocol.Credential, generation: UUID) {
        expiry?.cancel()
        let enrollment = client?.ownerEnrollment
        let remaining = max(0, Double(grant.expiresAt) / 1000 - now())
        let work = DispatchWorkItem { [weak self, weak enrollment] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.credential == grant else { return }
                guard let client = self.client, let enrollment, client.ownerEnrollmentIsCurrent(enrollment) else {
                    self.invalidate(); return
                }
                self.expiry = nil
                self.events.configure(nil)
                self.credential = nil
                self.client?.resumeOwnerEnrollment()
            }
        }
        expiry = work
        schedule(remaining, work)
    }
}
