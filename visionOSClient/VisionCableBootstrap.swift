import Foundation

struct VisionWindowLease: Equatable {
    let window: UUID
    let admission = UUID()

    func perform(current: VisionWindowLease?, _ action: () -> Void) {
        guard self == current else { return }
        action()
    }
}

enum VisionCableBootstrapReason: String, Codable {
    case invalidArguments, savedPairExists, occupied, foregroundRequired, duplicateService
    case waitingForService, waitingForCable, pairingUnavailable, permissionRequired
    case cancelled, pinRejected, cableRejected, keyUnavailable, noAnswer, macLocked, hostBusy, hostRefused, invalidResponse
}

final class VisionCableBootstrap<Row> {
    typealias Reason = VisionCableBootstrapReason
    final class AskPermit {
        private let lock = NSLock()
        private var live = true

        func perform(_ send: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard live else { return }
            live = false
            send()
        }

        func revoke() { lock.lock(); live = false; lock.unlock() }
    }
    struct Request: Equatable {
        let pin: Data
        let service: String
    }

    enum Launch: Equatable {
        case ordinary
        case cable(Request)
        case invalid

        static func parse(_ arguments: [String]) -> Launch {
            let pinFlag = "--ccr-cable-bootstrap-pin"
            let serviceFlag = "--ccr-cable-bootstrap-service"
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                guard flag.hasPrefix("--ccr-cable-bootstrap-") else { index += 1; continue }
                guard flag == pinFlag || flag == serviceFlag, values[flag] == nil,
                      index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { return .invalid }
                values[flag] = arguments[index + 1]
                index += 2
            }
            guard !values.isEmpty else { return .ordinary }
            guard let text = values[pinFlag], text.utf8.count == 43,
                  text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
                  let pin = Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
                  pin.count == 32,
                  pin.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == text,
                  let service = values[serviceFlag], !service.isEmpty,
                  service.utf8.count <= 255, !service.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .invalid }
            return .cable(Request(pin: pin, service: service))
        }
    }

    enum Phase: Equatable {
        case ordinary
        case waiting(Reason)
        case attempting
        case asking
        case paired
        case stopped(Reason)
    }

    struct Candidate {
        let row: Row
        let service: String?
        let network: Bool
        let pairingRequired: Bool
        let wired: Bool
    }

    struct Context {
        var savedMacCount: Int
        var occupied: Bool
        var foreground: Bool
        var permissionDenied: Bool
        var candidates: [Candidate]
    }

    let launch: Launch
    private var askPermit: AskPermit?
    var onChange: (() -> Void)?
    private(set) var phase: Phase {
        didSet { if oldValue != phase { onChange?() } }
    }

    init(launch: Launch) {
        self.launch = launch
        switch launch {
        case .ordinary: phase = .ordinary
        case .invalid: phase = .stopped(.invalidArguments)
        case .cable: phase = .waiting(.waitingForService)
        }
    }

    var isAttempting: Bool { phase == .attempting || phase == .asking }
    var request: Request? { if case .cable(let request) = launch { return request }; return nil }

    func consider(_ context: Context, begin: (Row, Data) -> Void) {
        guard case .waiting = phase, let request else { return }
        guard context.savedMacCount == 0 else { stop(.savedPairExists); return }
        guard !context.occupied else { stop(.occupied); return }
        guard context.foreground else { stop(.foregroundRequired); return }
        guard !context.permissionDenied else { stop(.permissionRequired); return }
        let matches = context.candidates.filter { $0.network && $0.service?.utf8.elementsEqual(request.service.utf8) == true }
        guard matches.count <= 1 else { stop(.duplicateService); return }
        guard let candidate = matches.first else { phase = .waiting(.waitingForService); return }
        guard candidate.pairingRequired else { stop(.pairingUnavailable); return }
        guard candidate.wired else { phase = .waiting(.waitingForCable); return }
        phase = .attempting
        begin(candidate.row, request.pin)
    }

    func authorizeAsk(peerPin: Data, cable: Bool, foreground: Bool, exclusive: Bool, send: (AskPermit) -> Void) {
        guard phase == .attempting, let request else { return }
        guard foreground else { stop(.foregroundRequired); return }
        guard exclusive else { stop(.occupied); return }
        guard peerPin == request.pin else { stop(.pinRejected); return }
        guard cable else { stop(.cableRejected); return }
        let permit = AskPermit()
        askPermit = permit
        phase = .asking
        send(permit)
    }

    func accepted() { if phase == .asking { phase = .paired } }

    func stop(_ reason: Reason) {
        askPermit?.revoke()
        switch phase {
        case .waiting, .attempting, .asking: phase = .stopped(reason)
        default: break
        }
    }
}
