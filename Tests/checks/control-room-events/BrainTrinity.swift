import Foundation

func brainTrinityChecks() throws {
    let now = BrainTrinityFeed.date(clock)!
    let old = "2026-10-22T18:00:00.000Z"
    let owner = "bt-ledger:goal_becdf9909850486b:root7302"
    let link: [String:Any] = ["workspaceId":"bt-workspace","slotIndex":0]
    let row: [String:Any] = ["projectId":"bt-project","threadId":"bt-thread",
        "summary":"읽기 전용 관측","updatedAt":old,"ledgerRevision":7,"cardLinks":[link]]
    let activity = row.merging(["key":"bt-activity","phase":"observation_pending"]) { _,new in new }
    let review = row.merging(["id":"bt-review","state":"pending","order":0,
        "decisionAllowed":false]) { _,new in new }
    let feed: [String:Any] = ["schema":"control-room-bt-mobile-feed/v1","available":true,
        "writable":false,"source":"braintrinity","ownerInstanceId":owner,"revision":7,"epoch":2,
        "observedAt":old,"mode":"running","reason":"ccr_resident_registration_conflict",
        "activities":[activity],"reviewRequests":[review]]
    let card: [String:Any] = ["id":"bt-thread","available":true,"source":"codex",
        "projectId":"bt-project","projectVerified":true]
    let slot: [String:Any] = ["index":0,"kind":"normal","threadId":"bt-thread",
        "projectId":"bt-project","card":card]
    func projection(_ changes: [String:Any] = [:], root: [String:Any] = [:],
                    slot slotChanges: [String:Any] = [:]) throws -> ControlRoomProjection {
        let selected = slot.merging(slotChanges) { _,new in new }
        let fields: [String:Any] = ["workspace":"bt-workspace","brainTrinity":feed.merging(changes) { _,new in new },
            "currentGrid":[selected],"workspaces":[["id":"bt-workspace","label":"BT","slots":[selected]]]]
        return try JSONDecoder().decode(ControlRoomProjection.self,
            from:encoded(snapshot(fields.merging(root) { _,new in new })))
    }
    var count = 0
    var failures = [String]()
    func expect(_ value: Bool, _ label: String) {
        count += 1
        if !value { failures.append(label) }
    }
    func badges(_ value: ControlRoomProjection) -> BrainTrinityBadges {
        value.brainTrinityBadges(layoutID:nil,index:0,now:now)
    }
    let historical = try projection()
    expect(historical.isFresh(now:now),"상위 snapshot은 현재이며 BT 관측 age와 독립")
    expect(historical.brainTrinity?.isAvailable(now:now) == true,"과거 6시간 BT read-only 관측 수용")
    expect(historical.freshBrainTrinity(now:now)?.observedAt == old,"과거 6시간 observedAt 원문 보존")
    expect(badges(historical).activities.count == 1 && badges(historical).reviews.count == 1,
        "과거 6시간 행의 활동·검토 배지 보존")
    expect(historical.brainTrinity?.mode == .running &&
        historical.brainTrinity?.reason == "ccr_resident_registration_conflict",
        "mode와 conflict 사유를 별도 관측값으로 보존")
    expect(historical.brainTrinity?.writable == false &&
        historical.brainTrinity?.reviewRequests.first?.decisionAllowed == false,"관측 수용은 쓰기·판정 권한을 만들지 않음")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
    for seconds in [-21600.0, -31, -30, 0, 30, 30.001] {
        let value = try projection(["observedAt":formatter.string(from:now.addingTimeInterval(seconds))])
        expect((value.freshBrainTrinity(now:now) != nil) == (seconds <= 30),"BT 관측 상대 초 \(seconds)")
    }
    for invalid in ["", "invalid", "2026-99-99T00:00:00Z", String(repeating:"x",count:65)] {
        expect(try projection(["observedAt":invalid]).freshBrainTrinity(now:now) == nil,"잘못된 BT timestamp 거부 \(invalid)")
    }
    for (field, value) in [("observedAt",NSNull()),("mode",NSNull())] {
        expect(try projection([field:value]).freshBrainTrinity(now:now) == nil,"누락 \(field) 거부")
    }
    for (field, value) in [("schema","other/v1"),("source","other"),
        ("ownerInstanceId","bt-ledger:other-root:root7302"),("ownerInstanceId","bt-ledger:goal_becdf9909850486b:"),
        ("ownerInstanceId",owner+"\n")] {
        expect(try projection([field:value]).freshBrainTrinity(now:now) == nil,"다른·잘못된 출처 거부 \(field) \(value)")
    }
    for field in ["revision","epoch"] {
        for value in [-1,9_007_199_254_740_992] {
            expect(try projection([field:value]).freshBrainTrinity(now:now) == nil,"범위 밖 \(field) \(value) 거부")
        }
        expect(try projection([field:NSNull()]).freshBrainTrinity(now:now) == nil,"누락 \(field) 거부")
    }
    expect(try projection(["available":false]).freshBrainTrinity(now:now) == nil,"unavailable 관측 거부")
    expect(try projection(["writable":true]).freshBrainTrinity(now:now) == nil,"writable feed 거부")
    for mode in ["unknown","pending","ccr_resident_registration_conflict"] {
        do {
            _ = try projection(["mode":mode])
            expect(false,"알 수 없는 mode \(mode)를 running으로 승격하지 않음")
        } catch {
            expect(true,"알 수 없는 mode \(mode)를 running으로 승격하지 않음")
        }
    }
    for mode in ["stopped","starting","stopping","blocked"] {
        let value = try projection(["mode":mode])
        expect(value.freshBrainTrinity(now:now)?.mode?.rawValue == mode,"공식 mode \(mode) 원문 보존")
    }
    for field in ["generatedAt","sourceObservedAt"] {
        expect(try projection(root:[field:old]).freshBrainTrinity(now:now) == nil,"상위 \(field) 과거 age 제한 유지")
        expect(try projection(root:[field:formatter.string(from:now.addingTimeInterval(6))]).freshBrainTrinity(now:now) == nil,
            "상위 \(field) 미래 5초 제한 유지")
    }
    expect(historical.disconnected().freshBrainTrinity(now:now) == nil,"transport 단절 보호 유지")
    expect(try projection(root:["schemaVersion":2]).freshBrainTrinity(now:now) == nil,"상위 schema 보호 유지")
    expect(try projection(root:["connection":["connected":false,"state":"stale"]]).freshBrainTrinity(now:now) == nil,
        "상위 connection freshness 유지")
    for field in ["updatedAt","ledgerRevision","threadId","projectId","cardLinks"] {
        let badValues: [String:Any] = ["updatedAt":formatter.string(from:now.addingTimeInterval(31)),
            "ledgerRevision":8,"threadId":"another-thread","projectId":"another-project",
            "cardLinks":[["workspaceId":"another-workspace","slotIndex":0]]]
        let badActivity = activity.merging([field:badValues[field]!]) { _,new in new }
        let badReview = review.merging([field:badValues[field]!]) { _,new in new }
        let value = try projection(["activities":[badActivity],"reviewRequests":[badReview]])
        expect(badges(value).activities.isEmpty && badges(value).reviews.isEmpty,"행 결박 보호 \(field)")
    }
    for timestamp in [old, "2000-01-01T00:00:00Z", formatter.string(from:now.addingTimeInterval(30))] {
        let updated = activity.merging(["updatedAt":timestamp]) { _,new in new }
        expect(try badges(projection(["activities":[updated]])).activities.count == 1,
            "updatedAt은 과거 age 제한 없이 미래 30초까지만 수용 \(timestamp)")
    }
    let invalidRow = activity.merging(["updatedAt":"invalid"]) { _,new in new }
    expect(try badges(projection(["activities":[invalidRow]])).activities.isEmpty,"잘못된 행 timestamp 거부")
    let writableReview = review.merging(["decisionAllowed":true]) { _,new in new }
    let denied = try projection(["reviewRequests":[writableReview]])
    expect(badges(denied).reviews.isEmpty && badges(denied).activities.count == 1,"decisionAllowed=true 검토만 거부")
    for changes: [String:Any] in [["source":"chatgpt"],["available":false],["stale":true],
        ["hidden":true],["archived":true],["projectVerified":false]] {
        let changedCard = card.merging(changes) { _,new in new }
        let value = try projection(slot:["card":changedCard])
        expect(badges(value).activities.isEmpty && badges(value).reviews.isEmpty,"소유 카드 출처·가용성 보호 \(changes)")
    }
    expect(try badges(projection(slot:["chatgptProjectId":"other-project"])).activities.isEmpty,"다른 프로젝트 종류 차단")
    expect(try badges(projection(["activities":[activity,activity],"reviewRequests":[review,review]])).activities.isEmpty,
        "중복 활동 키 차단")
    expect(try badges(projection(["reviewRequests":[review,review]])).reviews.isEmpty,"중복 검토 ID 차단")
    let output = failures.map { "FAIL BT \($0)" } + ["\(failures.isEmpty ? "PASS" : "FAIL") BT 관측 정책 \(count-failures.count)/\(count), 실패 \(failures.count)"]
    FileHandle.standardOutput.write(Data((output.joined(separator:"\n")+"\n").utf8))
    if !failures.isEmpty { throw NSError(domain:"BTObservationChecks",code:failures.count) }
}
