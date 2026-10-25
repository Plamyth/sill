import Foundation
import StreamProtocol

@main struct Checks {
    static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { print("FAIL \(name)"); exit(1) }
        count += 1
        print("PASS \(name)")
    }
    final class Peer {}

    static func main() {
        let aObject = Peer(), bObject = Peer(), unknownObject = Peer()
        let a = ObjectIdentifier(aObject), b = ObjectIdentifier(bObject), unknown = ObjectIdentifier(unknownObject)
        if CommandLine.arguments.contains("--exhaustion") {
            let gate = SentryAdmission()
            gate.configure(latched: false, persistenceHealthy: true)
            gate.register(a, externalRoute: false)
            expect(gate.sourceSelectionAdmission(for: a)?.generation == SourceSelectionAdmission.maximumGeneration,
                   "마지막 53비트 세대는 유효함")
            gate.admit(a)
            expect(gate.sourceSelectionAdmission(for: a) == nil && gate.allowsActions(a),
                   "세대 소진은 신호만 닫고 실제 권한 조건은 유지함")
            gate.register(b, externalRoute: false); gate.admit(b)
            expect(gate.sourceSelectionAdmission(for: b) == nil, "소진 뒤 새 세션에 세대를 재사용하지 않음")
            gate.requireProtection(explicit: true); gate.update(verified: true, persistenceHealthy: true, reason: nil)
            expect(gate.sourceSelectionAdmission(for: a) == nil, "소진 뒤 복구해도 래핑하지 않음")
            print("EXHAUSTION_CHECKS_COMPLETE \(count)")
            return
        }

        func signal(_ gate: SentryAdmission, _ peer: ObjectIdentifier) -> SourceSelectionAdmission {
            let value = gate.sourceSelectionAdmission(for: peer)!
            expect(value.ready == gate.allowsActions(peer), "신호와 실제 소스 선택 권한이 같음")
            return value
        }

        let gate = SentryAdmission()
        expect(gate.sourceSelectionAdmission(for: unknown) == nil, "미등록 peer는 비활성 상태에서도 신호 없음")
        gate.register(a, externalRoute: false)
        expect(gate.sourceSelectionAdmission(for: a) == nil, "미설정 synthetic admission은 등록 peer에도 신호 없음")
        gate.configure(latched: false, persistenceHealthy: true)
        gate.register(a, externalRoute: false)
        let registered = signal(gate, a)
        expect(!registered.ready && registered.generation > 0, "초기 등록은 새 세대의 미허용 상태임")
        gate.admit(a)
        let admitted = signal(gate, a)
        expect(admitted.ready && admitted.generation > registered.generation, "admit 전후 권한 전이에 새 세대를 배정함")
        gate.admit(a)
        expect(signal(gate, a) == admitted, "같은 admit은 세대를 바꾸지 않음")
        for _ in 0..<20 {
            expect(gate.sourceSelectionAdmission(for: a) == admitted, "반복 catalog 읽기는 세대를 바꾸지 않음")
        }
        gate.register(b, externalRoute: false)
        let bRegistered = signal(gate, b)
        gate.admit(b)
        let bAdmitted = signal(gate, b)
        expect(bAdmitted.generation > bRegistered.generation && signal(gate, a) == admitted,
               "다른 peer의 등록과 권한 전이는 기존 peer 세대를 바꾸지 않음")
        gate.capture(UUID()); gate.capture(nil, for: a); gate.capture(UUID(), for: b)
        expect(signal(gate, a) == admitted && signal(gate, b) == bAdmitted, "공유 및 peer 캡처 변경은 선택 세대에 영향 없음")
        gate.requireProtection(explicit: true)
        let blocked = signal(gate, a)
        expect(!blocked.ready && blocked.generation > admitted.generation, "보호 요청이 기존 세션을 즉시 닫음")
        gate.update(verified: true, persistenceHealthy: true, reason: nil)
        let recovered = signal(gate, a)
        expect(recovered.ready && recovered.generation > blocked.generation, "보호 복구가 새 허용 세대를 만듦")
        expect(gate.status(for: a)?.phase == .pending && !gate.allows(a, epoch: UUID()),
               "캡처 epoch가 없는 pending도 소스 선택은 허용되고 영상은 차단됨")
        let beforeRevision = gate.status(for: a)!.revision
        gate.capture(UUID(), for: b)
        expect(gate.status(for: a)!.revision != beforeRevision && signal(gate, a) == recovered,
               "다른 peer 캡처가 Sentry revision을 바꿔도 허용 세대는 불변임")
        gate.update(verified: false, persistenceHealthy: true, reason: "보호 상실")
        gate.update(verified: true, persistenceHealthy: true, reason: nil)
        let coalesced = signal(gate, a)
        expect(coalesced.ready && coalesced.generation > recovered.generation,
               "중간 false catalog가 전혀 출력되지 않아도 새 true 세대가 남음")
        gate.update(verified: true, persistenceHealthy: true, reason: nil)
        expect(signal(gate, a) == coalesced, "동일 보호 readback은 세대를 바꾸지 않음")
        gate.update(verified: true, persistenceHealthy: true, reason: "기존 권한 조건에 없는 사유")
        expect(signal(gate, a) == coalesced, "사유 문자열은 기존 allowsActions 조건을 바꾸지 않음")
        gate.update(verified: true, persistenceHealthy: false, reason: nil)
        let unhealthy = signal(gate, a)
        expect(!unhealthy.ready && unhealthy.generation > coalesced.generation, "저장 상태 실패는 허용을 철회함")
        gate.configure(latched: true, persistenceHealthy: true)
        let reconfigured = signal(gate, a)
        expect(reconfigured.ready && reconfigured.generation > unhealthy.generation, "재설정의 실제 권한 전이도 갱신함")
        gate.configure(latched: true, persistenceHealthy: true)
        expect(signal(gate, a) == reconfigured, "같은 재설정은 세대를 보존함")
        gate.fenceForLocalReturn()
        let fenced = signal(gate, a)
        expect(!fenced.ready && fenced.generation > reconfigured.generation, "로컬 복귀 fence가 즉시 새 미허용 세대를 만듦")
        gate.update(verified: true, persistenceHealthy: true, reason: nil)
        expect(signal(gate, a) == fenced, "fence 중 표면 복구만으로 선택을 허용하지 않음")
        gate.completeLocalReturn()
        expect(gate.sourceSelectionAdmission(for: a) == nil && gate.sourceSelectionAdmission(for: b) == nil,
               "로컬 복귀 완료는 이전 세션 신호를 제거함")
        gate.register(a, externalRoute: false); gate.admit(a)
        let newSession = signal(gate, a)
        expect(newSession.ready && newSession.generation > fenced.generation, "복귀 뒤 새 세션은 이전 세대를 재사용하지 않음")
        gate.remove(a)
        expect(gate.sourceSelectionAdmission(for: a) == nil && !gate.allowsActions(a), "제거된 peer는 신호와 권한 없음")
        gate.register(a, externalRoute: false)
        let registeredAgain = signal(gate, a)
        expect(!registeredAgain.ready && registeredAgain.generation > newSession.generation, "같은 peer 재등록은 새 미허용 세대임")
        gate.admit(a)
        let current = gate.status(for: a)!
        let activation = SentryActivation(hostBootID: current.hostBootID, sessionID: current.sessionID, revision: current.revision)
        expect(gate.accept(activation, from: a), "기존 Sentry activation CAS를 유지함")
        let manual = signal(gate, a)
        expect(!manual.ready, "수동 보호 활성화도 현재 선택 권한을 닫음")
        expect(gate.accept(activation, from: a) && signal(gate, a) == manual, "동일 activation 재처리는 새 세대를 만들지 않음")
        expect(gate.sourceSelectionAdmission(for: unknown) == nil, "활성 상태의 미등록 peer도 신호 없음")

        let externalGate = SentryAdmission()
        externalGate.configure(latched: false, persistenceHealthy: true)
        externalGate.register(a, externalRoute: false); externalGate.admit(a)
        let beforeExternal = signal(externalGate, a)
        externalGate.register(b, externalRoute: true)
        let afterExternal = signal(externalGate, a)
        expect(afterExternal == beforeExternal && afterExternal.ready && !externalGate.isRequested,
               "외부 peer 등록은 기존 선택 권한·세대와 Sentry OFF를 보존함")
        externalGate.update(verified: true, persistenceHealthy: true, reason: nil)
        let beforeBAdmission = signal(externalGate, a)
        externalGate.admit(b)
        expect(signal(externalGate, a) == beforeBAdmission && signal(externalGate, b).ready,
               "보호가 준비된 다른 peer의 admit은 자기 세대만 바꿈")

        for requested in [false, true] {
            for verified in [false, true] {
                for healthy in [false, true] {
                    for admitted in [false, true] {
                        for fenced in [false, true] {
                            let state = SentryAdmission()
                            state.configure(latched: requested, persistenceHealthy: healthy)
                            state.register(a, externalRoute: false)
                            if admitted { state.admit(a) }
                            state.update(verified: verified, persistenceHealthy: healthy, reason: nil)
                            if fenced { state.fenceForLocalReturn() }
                            let expected = !fenced && admitted && (!requested || (healthy && verified))
                            expect(signal(state, a).ready == expected, "모든 기존 권한 조건 조합을 보존함")
                        }
                    }
                }
            }
        }
        codecChecks()
        print("SOURCE_SELECTION_ADMISSION_CHECKS_COMPLETE \(count)")
    }

    static func codecChecks() {
        expect(SourceSelectionAdmission(generation: 0, ready: true) == nil, "생성자가 0 세대를 거절함")
        expect(SourceSelectionAdmission(generation: .max, ready: true) == nil, "생성자가 53비트 초과 세대를 거절함")
        let valid = SourceSelectionAdmission(generation: SourceSelectionAdmission.maximumGeneration, ready: true)!
        expect(Wire.decode(SourceSelectionAdmission.self, from: Wire.encode(valid)) == valid, "53비트 최댓값도 codec 왕복 가능함")
        let invalid = [
            "{}", "{\"schemaVersion\":2,\"generation\":1,\"ready\":true}",
            "{\"schemaVersion\":1,\"generation\":0,\"ready\":true}",
            "{\"schemaVersion\":1,\"generation\":9007199254740992,\"ready\":true}",
            "{\"schemaVersion\":1,\"generation\":-1,\"ready\":true}",
            "{\"schemaVersion\":1,\"generation\":1.5,\"ready\":true}",
            "{\"schemaVersion\":1,\"generation\":\"1\",\"ready\":true}",
            "{\"schemaVersion\":1,\"generation\":1,\"ready\":1}",
            "{\"schemaVersion\":1,\"generation\":1,\"ready\":null}"
        ]
        for json in invalid {
            expect(Wire.decode(SourceSelectionAdmission.self, from: Data(json.utf8)) == nil, "잘못된 DTO를 decode 단계에서 거절함")
        }
        let legacy = WindowList(macName: "시험 Mac", windows: [], active: .none)
        expect(legacy.sourceSelectionAdmission == nil, "기존 생성자는 기본 nil을 유지함")
        expect(Wire.decode(WindowList.self, from: Wire.encode(legacy))?.sourceSelectionAdmission == nil, "기존 payload의 누락 필드는 nil로 해석함")
        let modern = WindowList(macName: "시험 Mac", windows: [], active: .none, sourceSelectionAdmission: valid)
        expect(Wire.decode(WindowList.self, from: Wire.encode(modern))?.sourceSelectionAdmission == valid, "WindowList에 새 DTO를 보존함")
        struct OldWindowList: Decodable { let macName: String; let windows: [WindowInfo]; let active: StreamSource }
        expect(Wire.decode(OldWindowList.self, from: Wire.encode(modern))?.macName == "시험 Mac", "구형 디코더가 새 optional 필드를 무시함")
        var json = try! JSONSerialization.jsonObject(with: Wire.encode(legacy)) as! [String: Any]
        json["sourceSelectionAdmission"] = NSNull()
        expect(Wire.decode(WindowList.self, from: try! JSONSerialization.data(withJSONObject: json))?.sourceSelectionAdmission == nil,
               "명시적 null은 준비 신호 없음으로 해석함")
        json["sourceSelectionAdmission"] = ["schemaVersion": 1, "generation": 0, "ready": true]
        expect(Wire.decode(WindowList.self, from: try! JSONSerialization.data(withJSONObject: json)) == nil,
               "잘못된 nested 신호를 가진 catalog는 거절함")
    }
}
