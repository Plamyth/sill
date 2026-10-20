extension LocalAudioRelay {
    func checkedCall(_ method: String, until deadline: ContinuousClock.Instant, admission: (@MainActor () -> Bool)? = nil) async -> Int? {
        let reply: Reply<Int>? = await call(method, payload: Empty(), until: deadline, admission: admission)
        return reply?.result
    }
    var checkPending: Bool { pending != nil }
    var checkWaiting: Int { waiting.count }
    var checkSequence: UInt64 { sequence }
    var checkConnected: Bool { if case .connected = state { true } else { false } }
    var checkClosed: Bool { if case .closed = state { true } else { false } }
    var checkDrained: Bool { pending == nil && waiting.isEmpty && activeCall == nil && buffer.isEmpty }
    func checkSetSequence(_ value: UInt64) { sequence = value }
}
