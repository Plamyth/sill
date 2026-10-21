import Foundation
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    var writable = true
    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    func set(_ value: Any, forKey key: String) { if writable { values[key] = value } }
    func synchronize() -> Bool { writable }
}
@MainActor final class Privacy {
    var calls = 0
    var answer = false
    var release: CheckedContinuation<Bool, Never>?
    var hold = false
    func requestLocalReturn() async -> Bool {
        calls += 1
        if hold { return await withCheckedContinuation { release = $0 } }
        return answer
    }
}
@MainActor final class Model {
    let localAudioReturnBootID = UUID()
    var audioPrivacy: Privacy? = Privacy()
    var localAudioReturnPending = false
    var localAudioReturnUnavailableReason: String?
    var localAudioReturnNotice = ""
    // METHODS
}
@main struct Checks {
    @MainActor static func main() async {
        var count = 0
        func check(_ value: Bool) { precondition(value); count += 1 }
        func result(_ id: UUID) -> [String: Any] { UserDefaults.standard.dictionary(forKey: "CCRLocalAudioReturnResults.v1")?[id.uuidString] as? [String: Any] ?? [:] }
        func settle(_ predicate: () -> Bool) async {
            for _ in 0..<1000 { if predicate() { return }; await Task.yield() }
            preconditionFailure("비활성 요청 처리 대기 초과")
        }
        let m = Model(), id = UUID()
        m.audioPrivacy!.hold = true
        m.requestLocalAudioReturn(requestID: id)
        await settle { m.audioPrivacy!.release != nil }
        check(result(id)["phase"] as? String == "authenticating" && result(id)["restored"] as? Bool == false)
        check(result(id)["completedAt"] == nil)
        m.requestLocalAudioReturn(requestID: id)
        let busy = UUID(); m.requestLocalAudioReturn(requestID: busy)
        check(m.audioPrivacy!.calls == 1 && result(busy)["phase"] as? String == "blocked")
        m.audioPrivacy!.release!.resume(returning: true)
        await settle { !m.localAudioReturnPending }
        check(result(id)["phase"] as? String == "restored" && result(id)["restored"] as? Bool == true)
        check(result(id)["requestID"] as? String == id.uuidString && result(id)["hostBootID"] as? String == m.localAudioReturnBootID.uuidString)
        check(result(id)["completedAt"] != nil)
        m.requestLocalAudioReturn(requestID: id)
        check(m.audioPrivacy!.calls == 1)
        m.audioPrivacy!.hold = false
        let denied = UUID(); m.requestLocalAudioReturn(requestID: denied)
        await settle { !m.localAudioReturnPending }
        check(result(denied)["restored"] as? Bool == false && result(denied)["phase"] as? String == "blocked")
        m.localAudioReturnUnavailableReason = "미지원"
        for _ in 0..<40 { m.requestLocalAudioReturn(requestID: UUID()) }
        check(UserDefaults.standard.dictionary(forKey: "CCRLocalAudioReturnResults.v1")!.count == 32)
        UserDefaults.standard.writable = false
        m.requestLocalAudioReturn(requestID: UUID())
        check(m.localAudioReturnNotice.contains("저장하지 못했습니다"))
        print("PASS \(count) actual local return request/result checks; authentication, preferences and HAL are inert")
    }
}
