import Foundation
import StreamProtocol

/// 생성·호출·취소·저장은 main queue에서 처리한다. 비동기 경계마다 세대와 현재 신뢰를 재검사한다.
final class IPadDeviceEnrollment {
    typealias ProtocolContract = IPadEnrollmentProtocol
    typealias Credential = ProtocolContract.Credential
    typealias Completion = (Result<Credential, Error>) -> Void
    typealias Cancel = () -> Void
    enum Route: String { case challenge = "/v1/devices/challenge", enroll = "/v1/devices/enroll"
        case readbackChallenge = "/v1/devices/readback/challenge", readback = "/v1/devices/readback" }
    enum Phase { case idle, requesting, ready, waiting, renewalRequired, denied }
    final class Refusals {
        var tokenHashes: Set<String> = []
        var terminal = ""
        var lastAccepted: (id: String, expiresAt: Int64, tokenHash: String)?
    }
    struct HTTPReply { let status: Int; let contentType: String; let body: Data }
    struct IO {
        var load: () throws -> Data?
        var compareAndSwap: (Data?, Data) throws -> Void
        var post: (Route, Data, @escaping (Result<HTTPReply, Error>) -> Void) -> Cancel
        var ownerReceipt: (ProtocolContract.Challenge, @escaping (Result<Data, Error>) -> Void) -> Cancel
        var sign: (Data) throws -> Data
        var current: () -> Bool
        var now: () -> Int64
    }
    let binding: ProtocolContract.Binding
    private let io: IO
    private let refusals: Refusals
    private var epoch: UInt64 = 0
    private var step: UInt64 = 0
    private var running = false
    private var cancellation: Cancel?
    private var waiters: [Completion] = []
    private var raw: Data?
    private var journal: Journal?
    private var cached: Credential?
    private(set) var phase: Phase = .idle

    init(binding: ProtocolContract.Binding, io: IO, refusals: Refusals = Refusals()) {
        self.binding = binding; self.io = io; self.refusals = refusals
    }

    var credential: Credential? {
        precondition(Thread.isMainThread)
        guard io.current(), phase == .ready, refusals.terminal.isEmpty, let cached,
              !refusals.tokenHashes.contains(cached.tokenHash), cached.expiresAt > io.now() else { return nil }
        return cached
    }

    func authorizedRequest(path: String, method: String, body: Data? = nil) throws -> URLRequest {
        precondition(Thread.isMainThread)
        let read: Set<String> = ["/v1/catalog", "/v1/thread", "/v1/snapshot", "/v1/history", "/v1/events"]
        let write: Set<String> = ["/v1/unified-command", "/v1/send"]
        let generation = epoch
        guard (method == "GET" && read.contains(path) && body == nil) || (method == "POST" && write.contains(path)),
              let grant = credential, grant.binding == binding,
              let url = URL(string: ProtocolContract.origin + path), url.absoluteString == ProtocolContract.origin + path,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw IPadEnrollmentFailure.stale }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(grant.authorizationValue, forHTTPHeaderField: "Authorization")
        guard generation == epoch, io.current(), grant.expiresAt > io.now() else { throw IPadEnrollmentFailure.stale }
        return request
    }

    func ensure(_ done: @escaping Completion) {
        precondition(Thread.isMainThread)
        guard io.current() else { done(.failure(IPadEnrollmentFailure.stale)); return }
        waiters.append(done)
        if running { return }
        running = true; phase = .requesting; epoch &+= 1
        do {
            if !refusals.terminal.isEmpty { phase = .denied }
            try reload()
            guard var journal else { throw IPadEnrollmentFailure.storage }
            if !refusals.terminal.isEmpty, journal.terminal != refusals.terminal {
                journal.terminal = refusals.terminal; try save(journal)
            }
            if let saved = try journal.credential(binding: binding), refusals.tokenHashes.contains(saved.tokenHash),
               journal.rejectedHash != saved.tokenHash {
                journal.rejectedHash = saved.tokenHash
                journal.pending = try pendingWithMode(journal.pending, mode: "readback")
                try save(journal)
            }
            guard journal.terminal.isEmpty else {
                refusals.terminal = journal.terminal; phase = .denied; throw IPadEnrollmentFailure.unavailable
            }
            guard !journal.renewalRequired else { phase = .renewalRequired; throw IPadEnrollmentFailure.unavailable }
            if let saved = try journal.credential(binding: binding), saved.expiresAt > io.now(),
               journal.rejectedHash != saved.tokenHash, !refusals.tokenHashes.contains(saved.tokenHash) {
                finish(.success(saved)); return
            }
            if journal.pending != .null { try redeem() } else { try requestChallenge() }
        } catch { finish(.failure(error)) }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        epoch &+= 1; step &+= 1
        let cancel = cancellation; cancellation = nil
        running = false; cached = nil; phase = .idle
        let pending = waiters; waiters = []
        cancel?()
        pending.forEach { $0(.failure(IPadEnrollmentFailure.cancelled)) }
    }

    /// 원 작업의 확정 만료가 보존된 후에만 명시적인 현재 신뢰 갱신을 허용한다.
    func trustedRenew(_ done: @escaping Completion) {
        precondition(Thread.isMainThread)
        guard !running, io.current(), refusals.terminal.isEmpty else { done(.failure(IPadEnrollmentFailure.stale)); return }
        do {
            try reload()
            guard var next = journal, next.renewalRequired, next.terminal.isEmpty,
                  next.pending == .null, next.saved == .null, !next.history.isEmpty else { throw IPadEnrollmentFailure.unavailable }
            next.renewalRequired = false
            try save(next)
            ensure(done)
        } catch { done(.failure(error)) }
    }

    /// 반드시 해당 HTTP 요청에 사용한 자격을 전달한다. 늦은 옛 401은 새 자격을 거절하지 않는다.
    func unauthorized(_ refused: Credential, status: Int, body: Data, done: @escaping Completion) {
        precondition(Thread.isMainThread)
        do {
            guard io.current(), !running else { throw IPadEnrollmentFailure.stale }
            let error = try ProtocolContract.error(body, status: status)
            guard case .server(let code, let reason) = error,
                  code == 401 || code == 403 && ["DEVICE_REVOKED", "OWNER_TRUST_DENIED"].contains(reason) else { throw error }
            guard refused.binding == binding else { throw IPadEnrollmentFailure.stale }
            if let current = credential, current != refused { done(.success(current)); return }
            if let accepted = refusals.lastAccepted {
                guard accepted == (refused.id, refused.expiresAt, refused.tokenHash) else { throw IPadEnrollmentFailure.stale }
                quarantine(refused, status: code, reason: reason)
            }
            try reload()
            guard var next = journal else { throw IPadEnrollmentFailure.storage }
            guard try next.credential(binding: binding) == refused else { ensure(done); return }
            quarantine(refused, status: code, reason: reason)
            if code == 403 && ["DEVICE_REVOKED", "OWNER_TRUST_DENIED"].contains(reason) {
                next.terminal = reason; try save(next)
                done(.failure(error)); return
            }
            guard code == 401 else { throw error }
            next.rejectedHash = refused.tokenHash
            if next.pending != .null { next.pending = try pendingWithMode(next.pending, mode: "readback") }
            try save(next)
            ensure(done)
        } catch { done(.failure(error)) }
    }

    private func quarantine(_ refused: Credential, status: Int, reason: String) {
        cached = nil
        if status == 401 { refusals.tokenHashes.insert(refused.tokenHash); phase = .waiting }
        else { refusals.terminal = reason; phase = .denied }
    }

    private func reload() throws {
        guard io.current() else { throw IPadEnrollmentFailure.stale }
        let loaded = try io.load()
        let decoded = try loaded.map { try Journal($0, binding: binding, now: io.now()) } ?? Journal(binding: binding)
        guard io.current() else { throw IPadEnrollmentFailure.stale }
        raw = loaded; journal = decoded
    }
    private func save(_ next: Journal) throws {
        guard io.current() else { throw IPadEnrollmentFailure.stale }
        let bytes = try next.json.bytes()
        _ = try Journal(bytes, binding: binding, now: io.now())
        try io.compareAndSwap(raw, bytes)
        guard io.current(), try io.load() == bytes else { throw IPadEnrollmentFailure.storage }
        raw = bytes; journal = next
    }
    private func checked() throws {
        guard running, io.current() else { throw IPadEnrollmentFailure.stale }
    }
    private func requestChallenge() throws {
        try checked()
        guard journal?.saved == .null else { throw IPadEnrollmentFailure.invalid }
        let request = try IPadEnrollmentJSON.object(["devicePublicKey": .string(Base64URL.encode(binding.deviceSPKI))]).bytes()
        post(.challenge, body: request) { [self] bytes in
            let challenge = try ProtocolContract.Challenge(bytes, binding: binding, now: io.now())
            let token = epoch; step &+= 1; let operation = step
            cancellation = io.ownerReceipt(challenge) { [weak self] result in
                self?.deliver(token, operation: operation) {
                    guard let self else { return }
                    let rawReceipt = try result.get()
                    let receipt = try ProtocolContract.Receipt(rawReceipt, challenge: challenge, binding: self.binding, now: self.io.now())
                    try self.checked()
                    let signature = try self.io.sign(receipt.proofMessage)
                    let body = try ProtocolContract.enroll(receipt, challenge: challenge, binding: self.binding, signature: signature)
                    var next = self.journal!
                    guard next.pending == .null, next.saved == .null else { throw IPadEnrollmentFailure.storage }
                    next.pending = .object(["challenge": .string(Base64URL.encode(bytes)), "body": .string(Base64URL.encode(body)),
                        "digest": .string(try ProtocolContract.requestDigest(body)), "preparedAt": .integer(self.io.now()),
                        "mode": .string("enroll"), "acceptedTokenHash": .string("")])
                    try self.save(next)
                    try self.redeem()
                }
            }
        }
    }
    private func redeem() throws {
        try checked()
        guard let journal else { throw IPadEnrollmentFailure.storage }
        let pending = try Pending(journal.pending, binding: binding, now: io.now())
        if pending.mode == "readback" || !pending.acceptedHash.isEmpty || !journal.rejectedHash.isEmpty ||
            io.now() >= min(pending.challenge.expiresAt, pending.receipt.expiresAt) {
            try readback(pending); return
        }
        post(.enroll, body: pending.body, recover: true) { [self] response in try accept(response, pending: pending) }
    }
    private func readback(_ pending: Pending) throws {
        try checked()
        var next = journal!
        next.pending = try pendingWithMode(next.pending, mode: "readback")
        if next.pending != journal!.pending { try save(next) }
        let body = try IPadEnrollmentJSON.object(["challengeId": .string(pending.challenge.id),
            "devicePublicKey": .string(Base64URL.encode(binding.deviceSPKI))]).bytes()
        post(.readbackChallenge, body: body, expiresOriginal: true) { [self] response in
            let challenge = try ProtocolContract.Readback(response, challenge: pending.challenge, digest: pending.digest, binding: binding, now: io.now())
            try checked()
            let sig = try io.sign(challenge.message)
            guard try ProtocolContract.publicKey(binding.deviceSPKI).isValidSignature(ProtocolContract.signature(sig), for: challenge.message),
                  challenge.expiresAt > io.now() else { throw IPadEnrollmentFailure.invalid }
            let request = try IPadEnrollmentJSON.object(["schema": .string("ccr.device-readback/v1"),
                "challengeId": .string(pending.challenge.id), "readbackId": .string(challenge.id),
                "devicePublicKey": .string(Base64URL.encode(binding.deviceSPKI)), "signature": .string(Base64URL.encode(sig))]).bytes()
            post(.readback, body: request, expiresOriginal: true) { [self] bytes in
                guard challenge.expiresAt > io.now() else { throw IPadEnrollmentFailure.invalid }
                try accept(bytes, pending: pending)
            }
        }
    }
    private func accept(_ bytes: Data, pending: Pending) throws {
        try checked()
        let now = io.now()
        let grant = try Credential(bytes, binding: binding, observedAt: now)
        guard pending.acceptedHash.isEmpty || pending.acceptedHash == grant.tokenHash else { throw IPadEnrollmentFailure.invalid }
        guard refusals.terminal.isEmpty, !refusals.tokenHashes.contains(grant.tokenHash),
              journal!.rejectedHash != grant.tokenHash else { throw IPadEnrollmentFailure.unavailable }
        var next = journal!
        var p = try next.pending.fields(Pending.keys)
        p["acceptedTokenHash"] = .string(grant.tokenHash)
        next.pending = .object(p)
        next.saved = .object(["response": .string(Base64URL.encode(bytes)), "observedAt": .integer(now)])
        next.rejectedHash = ""
        try save(next)
        guard try journal!.credential(binding: binding) == grant else { throw IPadEnrollmentFailure.storage }
        guard grant.expiresAt > io.now() else { throw IPadEnrollmentFailure.stale }
        finish(.success(grant))
    }
    private func post(_ route: Route, body: Data, recover: Bool = false, expiresOriginal: Bool = false,
                      success: @escaping (Data) throws -> Void) {
        do {
            try checked()
            guard try io.load() == raw else { throw IPadEnrollmentFailure.storage }
        } catch { finish(.failure(error)); return }
        let token = epoch; step &+= 1; let operation = step
        cancellation = io.post(route, body) { [weak self] result in
            self?.deliver(token, operation: operation) {
                guard let self else { return }
                let reply = try result.get()
                guard reply.body.count <= 4096,
                      reply.contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
                    throw IPadEnrollmentFailure.invalid
                }
                if reply.status == 200 { try success(reply.body); return }
                let failure = try ProtocolContract.error(reply.body, status: reply.status)
                if case .server(let status, let code) = failure {
                    if status == 403 && ["DEVICE_REVOKED", "OWNER_TRUST_DENIED"].contains(code) {
                        self.refusals.terminal = code; self.cached = nil; self.phase = .denied
                        var next = self.journal!; next.terminal = code
                        try self.save(next)
                    } else if expiresOriginal && status == 401 && code == "CREDENTIAL_EXPIRED" {
                        var next = self.journal!
                        next.history.append(.object(["pending": next.pending, "credential": next.saved,
                            "rejectedTokenHash": .string(next.rejectedHash), "expiredAt": .integer(self.io.now())]))
                        next.pending = .null; next.saved = .null; next.rejectedHash = ""; next.renewalRequired = true
                        try self.save(next); self.phase = .renewalRequired
                    } else if recover && ((status == 409 && ["CHALLENGE_CONFLICT", "ENROLLMENT_READBACK_REQUIRED"].contains(code)) ||
                                           status == 410 && code == "ENROLLMENT_CHALLENGE_EXPIRED") {
                        let pending = try Pending(self.journal!.pending, binding: self.binding, now: self.io.now())
                        try self.readback(pending); return
                    }
                }
                throw failure
            }
        }
    }
    private func deliver(_ token: UInt64, operation: UInt64, action: @escaping () throws -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.epoch == token, self.step == operation else { return }
            self.cancellation = nil; self.step &+= 1
            do { try self.checked(); try action() } catch { self.finish(.failure(error)) }
        }
    }
    private func finish(_ result: Result<Credential, Error>) {
        let cancel = cancellation; cancellation = nil; running = false
        switch result {
        case .success(let grant):
            refusals.lastAccepted = (grant.id, grant.expiresAt, grant.tokenHash)
            cached = grant; phase = .ready
        case .failure: cached = nil; if phase != .denied && phase != .renewalRequired { phase = .waiting }
        }
        let callbacks = waiters; waiters = []
        cancel?(); callbacks.forEach { $0(result) }
    }
    private func pendingWithMode(_ pending: IPadEnrollmentJSON, mode: String) throws -> IPadEnrollmentJSON {
        var fields = try pending.fields(Pending.keys); fields["mode"] = .string(mode); return .object(fields)
    }

    private struct Pending {
        static let keys: Set<String> = ["challenge", "body", "digest", "preparedAt", "mode", "acceptedTokenHash"]
        let body: Data
        let challenge: ProtocolContract.Challenge
        let receipt: ProtocolContract.Receipt
        let digest: String, mode: String, acceptedHash: String
        init(_ json: IPadEnrollmentJSON, binding: ProtocolContract.Binding, now: Int64) throws {
            let f = try json.fields(Self.keys)
            let prepared = try f.integer("preparedAt")
            guard prepared > 0, prepared <= now + ProtocolContract.skew else { throw IPadEnrollmentFailure.invalid }
            challenge = try ProtocolContract.Challenge(ProtocolContract.decode(f.text("challenge"), maximum: 4096), binding: binding, now: prepared)
            body = try ProtocolContract.decode(f.text("body"), maximum: 16_384)
            digest = try f.text("digest"); mode = try f.text("mode"); acceptedHash = try f.text("acceptedTokenHash")
            guard ["enroll", "readback"].contains(mode), acceptedHash.isEmpty || ProtocolContract.hex64(acceptedHash),
                  try digest == ProtocolContract.requestDigest(body) else { throw IPadEnrollmentFailure.invalid }
            let request = try IPadEnrollmentJSON.parse(body, limit: 16_384).fields(["schema", "challengeId", "devicePublicKey", "signature", "ownerReceipt"])
            guard try request.text("challengeId") == challenge.id,
                  try request.text("devicePublicKey") == Base64URL.encode(binding.deviceSPKI), let envelope = request["ownerReceipt"] else { throw IPadEnrollmentFailure.invalid }
            receipt = try ProtocolContract.Receipt(envelope.bytes(), challenge: challenge, binding: binding, now: prepared)
            guard try ProtocolContract.publicKey(binding.deviceSPKI).isValidSignature(
                ProtocolContract.signature(ProtocolContract.decode(request.text("signature"), maximum: 72)), for: receipt.proofMessage) else {
                throw IPadEnrollmentFailure.invalid
            }
        }
    }
    private struct Journal {
        let bindingJSON: IPadEnrollmentJSON
        var pending: IPadEnrollmentJSON = .null
        var saved: IPadEnrollmentJSON = .null
        var history: [IPadEnrollmentJSON] = []
        var rejectedHash = ""
        var terminal = ""
        var renewalRequired = false
        var json: IPadEnrollmentJSON { .object(["schema": .string("ccr.ipad-enrollment-store/v1"), "binding": bindingJSON,
            "pending": pending, "credential": saved, "history": .array(history), "rejectedTokenHash": .string(rejectedHash),
            "terminal": .string(terminal), "renewalRequired": .bool(renewalRequired)]) }
        init(binding: ProtocolContract.Binding) { bindingJSON = binding.json }
        init(_ raw: Data, binding: ProtocolContract.Binding, now: Int64) throws {
            let f = try IPadEnrollmentJSON.parse(raw, limit: 1_048_576).fields(["schema", "binding", "pending", "credential", "history", "rejectedTokenHash", "terminal", "renewalRequired"])
            guard try f.text("schema") == "ccr.ipad-enrollment-store/v1", f["binding"] == binding.json,
                  case .array(let history)? = f["history"],
                  case .bool(let renewal)? = f["renewalRequired"] else { throw IPadEnrollmentFailure.storage }
            bindingJSON = binding.json; pending = f["pending"]!; saved = f["credential"]!
            self.history = history; renewalRequired = renewal
            rejectedHash = try f.text("rejectedTokenHash"); terminal = try f.text("terminal")
            guard rejectedHash.isEmpty || ProtocolContract.hex64(rejectedHash),
                  ["", "DEVICE_REVOKED", "OWNER_TRUST_DENIED"].contains(terminal) else { throw IPadEnrollmentFailure.storage }
            try validate(pending: pending, saved: saved, rejected: rejectedHash, binding: binding, now: now)
            if renewal { guard pending == .null, saved == .null, !history.isEmpty else { throw IPadEnrollmentFailure.storage } }
            for item in history {
                let row = try item.fields(["pending", "credential", "rejectedTokenHash", "expiredAt"])
                let time = try row.integer("expiredAt")
                guard time > 0, time <= now + ProtocolContract.skew, row["pending"] != .null else { throw IPadEnrollmentFailure.storage }
                try validate(pending: row["pending"]!, saved: row["credential"]!, rejected: row.text("rejectedTokenHash"), binding: binding, now: now)
            }
        }
        func credential(binding: ProtocolContract.Binding) throws -> Credential? {
            guard saved != .null else { return nil }
            let f = try saved.fields(["response", "observedAt"])
            return try Credential(ProtocolContract.decode(f.text("response"), maximum: 4096), binding: binding, observedAt: f.integer("observedAt"))
        }
        private func validate(pending: IPadEnrollmentJSON, saved: IPadEnrollmentJSON, rejected: String,
                              binding: ProtocolContract.Binding, now: Int64) throws {
            if pending == .null {
                guard saved == .null, rejected.isEmpty else { throw IPadEnrollmentFailure.storage }; return
            }
            let p = try Pending(pending, binding: binding, now: now)
            guard rejected.isEmpty || ProtocolContract.hex64(rejected) else { throw IPadEnrollmentFailure.storage }
            if saved != .null {
                let f = try saved.fields(["response", "observedAt"])
                let observed = try f.integer("observedAt")
                guard observed <= now + ProtocolContract.skew else { throw IPadEnrollmentFailure.storage }
                let grant = try Credential(ProtocolContract.decode(f.text("response"), maximum: 4096), binding: binding, observedAt: observed)
                guard p.acceptedHash == grant.tokenHash else { throw IPadEnrollmentFailure.storage }
            } else if !p.acceptedHash.isEmpty || !rejected.isEmpty { throw IPadEnrollmentFailure.storage }
        }
    }
}
