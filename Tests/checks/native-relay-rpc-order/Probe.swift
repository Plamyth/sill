extension LocalAudioRelay {
    func checkedCall(_ method: String, until deadline: ContinuousClock.Instant) async -> Int? {
        let reply: Reply<Int>? = await call(method, payload: Empty(), until: deadline)
        return reply?.result
    }
}
