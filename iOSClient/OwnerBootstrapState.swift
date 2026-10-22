import Foundation
import StreamProtocol

/// 최초 저장소 여부는 정리 전 원시 키로 고정한다. 재시도는 명시적인 활성화 경계에서만 열린다.
struct OwnerBootstrapState {
    enum Phase: Equatable {
        case unarmed, ready, dialing(UInt64), exchanging(UInt64), finished, stopped
    }
    private(set) var phase: Phase = .unarmed
    private var generation: UInt64 = 0
    private var initiallyEmpty = false
    var wasInitiallyEmpty: Bool { initiallyEmpty }

    mutating func arm(savedKeyPresent: Bool, preferredKeyPresent: Bool, hasRecords: Bool, explicitLaunch: Bool) {
        guard phase == .unarmed else { return }
        initiallyEmpty = !savedKeyPresent && !preferredKeyPresent && !hasRecords && !explicitLaunch
        phase = initiallyEmpty ? .ready : .finished
    }

    mutating func foreground(savedKeyPresent: Bool, preferredKeyPresent: Bool, hasRecords: Bool) {
        guard initiallyEmpty, phase == .finished, !savedKeyPresent, !preferredKeyPresent, !hasRecords else { return }
        phase = .ready
    }

    mutating func begin() -> UInt64? {
        guard phase == .ready else { return nil }
        generation += 1
        phase = .dialing(generation)
        return generation
    }

    mutating func exchange(_ token: UInt64) -> Bool {
        guard phase == .dialing(token) else { return false }
        phase = .exchanging(token)
        return true
    }

    mutating func finish(_ token: UInt64) -> Bool {
        guard phase == .dialing(token) || phase == .exchanging(token) else { return false }
        phase = .finished
        return true
    }

    /// 사용자 취소·다른 연결 선택은 같은 앱 실행에서 다시 열지 않는다.
    mutating func cancel() { phase = .stopped }

    /// OS 비활성화는 진행 중 연결만 닫고 다음 foreground 재시도를 허용한다.
    mutating func pause() {
        switch phase {
        case .dialing, .exchanging: phase = .finished
        default: break
        }
    }

    static func accepts(_ result: PairResult, profile: OwnerMacBootstrap, peerPin: Data, alpn: String?) -> Bool {
        guard alpn == OwnerMacBootstrap.alpn, peerPin == profile.fingerprintData,
              result.ok, result.method == OwnerMacBootstrap.method, result.proof == nil,
              result.macID == profile.macID, let recognition = result.recognitionKey,
              let key = Base64URL.decode(recognition), key.count == 32,
              Base64URL.encode(key) == recognition else { return false }
        return true
    }
}

final class OwnerBootstrapSendPermit {
    private let lock = NSRecursiveLock()
    private var available = true

    func sendIfAllowed(_ send: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard available else { return false }
        available = false
        send()
        return true
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        available = false
    }
}
