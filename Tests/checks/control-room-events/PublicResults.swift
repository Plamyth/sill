import Foundation

func publicResultChecks() async throws {
    let fixture = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"public-fixtures.json"))) as! [String:Any]
    let cases = fixture["cases"] as! [[String:Any]]
    check(fixture["producerCommit"] as? String == "9a91483f5e054ad8f30e9a1d43d8e7fd91740c6a" &&
        fixture["producerTree"] as? String == "4f7581661680f466a363ad7199ae1db54874163e", "공개 fixture exact producer")
    check(cases.map { $0["name"] as! String } == ["verified-public-fork","hidden-ancestor","unverified-child",
        "missing-current-child","retained-placeholder","duplicate-missing-root"], "공개 보호 6case")
    let normal = cases[0]["projected"] as! [String:Any]
    let rows = (normal["unifiedControl"] as! [String:Any])["rows"] as! [[String:Any]]
    let cloudRow = rows.first { $0["source"] as? String == "cursor-cloud" }!
    let childID = cloudRow["ownerThreadId"] as! String
    let siblingID = "abcdefab-0000-4000-8000-000000000003"
    let summaries = normal["sourceConnections"] as! [[String:Any]]
    let now = BrainTrinityFeed.date(clock)!
    // Native top-level slots are not relay currentGrid. Only public source DTOs enter this synthetic relay envelope.
    func sourceFields(_ projected: [String:Any]) -> [String:Any] {
        ["unifiedControl":projected["unifiedControl"]!,"sourceConnections":projected["sourceConnections"]!]
    }
    func projection(_ sourceRows: [[String:Any]] = rows, extra: [String:Any] = [:]) throws -> ControlRoomProjection {
        let root = snapshot([
            "unifiedControl":["schema":1,"rows":sourceRows,"truncated":false,"error":NSNull()],
            "sourceConnections":summaries].merging(extra) { _,new in new })
        var reducer = ControlRoomEventsReducer()
        _ = try reducer.consume(.init(id:"\(generation):0",event:"snapshot",
            data:encoded(event("snapshot",0,fields:["snapshot":root]))),contract:.relayProjection)
        return reducer.projection!
    }
    func cloudSelection(_ value: ControlRoomProjection) -> ControlRoomSourceSelection {
        var choice = ControlRoomSourceSelection()
        choice.select(source:.cursorCloud)
        choice.select(session:value.sessions(for:.cursorCloud)[0],in:value)
        return choice
    }
    let initial = try projection()
    let selected = cloudSelection(initial)
    let body = cloudRow["result"] as! String
    var terminal = cloudRow
    terminal["status"] = "FINISHED"; terminal["executionStatus"] = "FINISHED"
    terminal["statusSource"] = "cursor-cloud-get-run"; terminal["connectionState"] = "closed"
    terminal["observedAt"] = "2026-10-22T00:00:00Z"
    let terminalProjection = try projection([terminal])
    let terminalResult = cloudSelection(terminalProjection).currentResult(in:terminalProjection,now:now)
    check(terminalResult == body,
        "공개 fresh terminal old observedAt expected=\(body) actual=\(terminalResult ?? "nil")")
    for status in ["FINISHED","ERROR","CANCELLED","EXPIRED"] {
        for connectionState in ["closed","expired"] {
            for statusSource in ["cursor-cloud-sse","cursor-cloud-get-run"] {
                var row = terminal
                row["status"] = status; row["executionStatus"] = status
                row["connectionState"] = connectionState; row["statusSource"] = statusSource
                row["capabilities"] = ["read":true,"send":true]; row["readOnly"] = false
                let value = try projection([row])
                check(cloudSelection(value).resultDisplay(in:value,now:now) == .current(body),
                    "공개 fresh terminal \(status)/\(connectionState)/\(statusSource) old observedAt 허용")
                check(!value.sessions(for:.cursorCloud)[0].reportedSendAllowed(now:now),
                    "terminal 읽기 복구로 send 승격 없음")
            }
        }
    }
    for age in [31.0,60,89,90] {
        var row = cloudRow
        row["status"] = "RUNNING"; row["executionStatus"] = "RUNNING"
        row["statusSource"] = "cursor-cloud-sse"; row["connectionState"] = "connected"
        row["observedAt"] = ISO8601DateFormatter().string(from:now.addingTimeInterval(-age))
        let value = try projection([row])
        check(cloudSelection(value).resultDisplay(in:value,now:now) == .current(body),
            "공개 fresh observation \(age)초 허용")
    }
    check(selected.currentResult(in:initial,now:now) == body, "같은 Cloud agent/run의 공개 현재 응답")
    check(initial.sessions(for:.cursorCloud)[0].observedAt == nil && initial.sourceSummary(for:.cursorCloud)?.capabilities?.read == false,
        "행 관측 null과 summary read 거부는 공개 행 read를 대체하지 않음")

    for protected in cases.dropFirst() {
        let name = protected["name"] as! String
        let projected = protected["projected"] as! [String:Any]
        check(projected["currentGrid"] == nil && projected["slots"] is [[String:Any]], "\(name) native/relay 계약 분리")
        check(try encoded(projected["slots"]!) == encoded(normal["slots"]!), "\(name) native placeholder 슬롯 identity 보존")
        let nativeThreads = projected["threads"] as! [[String:Any]]
        let child = nativeThreads.first { $0["id"] as? String == childID }!
        check(child["emptySlot"] as? Bool == true && child["sourceMissing"] as? Bool == true &&
            (child["events"] as! [Any]).isEmpty && child["sourceConnection"] is NSNull, "\(name) placeholder 본문·연결 제거")
        for asPatch in [false,true] {
            var reducer = ControlRoomEventsReducer()
            func apply(_ value: [String:Any]) throws {
                check(try reducer.consume(frames(frame(value))[0],contract:.relayProjection) == .applied, "공개 DTO synthetic SSE 적용")
            }
            try apply(event("snapshot",0,fields:["snapshot":snapshot(sourceFields(normal))]))
            var choice = cloudSelection(reducer.projection!)
            choice.select(source:.codex)
            choice.select(session:reducer.projection!.sessions(for:.codex).first { $0.externalId == childID }!,in:reducer.projection!)
            check(choice.session(in:reducer.projection!)?.externalId == childID &&
                choice.currentResult(in:reducer.projection!,now:now) == nil, "native Codex 본문 미지원")
            choice.select(source:.cursorCloud)
            check(choice.currentResult(in:reducer.projection!,now:now) == body, "보호 전 같은 Cloud 선택")
            try apply(asPatch ? patch(1,set:sourceFields(projected)) :
                event("snapshot",1,fields:["snapshot":snapshot(sourceFields(projected))]))
            let hidden = reducer.projection!
            check(hidden.currentGrid.isEmpty && hidden.sessions(for:.cursorCloud).isEmpty &&
                !hidden.sessions(for:.codex).contains { $0.externalId == childID }, "\(name) 목록 제거")
            check(hidden.sessions(for:.codex).contains { $0.externalId == siblingID }, "\(name) 공개 형제 보존")
            check(choice.session(in:hidden) == nil && choice.resultDisplay(in:hidden,now:now) == nil, "\(name) reconcile 전에도 본문 잔류 없음")
            choice.reconcile(hidden)
            check(choice.sessionID == nil, "\(name) Cloud 선택 해제")
            choice.select(source:.codex)
            check(choice.sessionID == nil && choice.session(in:hidden) == nil, "\(name) Codex child 선택 해제")
            for source in [ControlRoomSource.codex,.cursorCloud] {
                let summary = hidden.sourceSummary(for:source)!
                check(summary.state == "unavailable" && summary.connected == false && summary.owner == nil &&
                    summary.sessionId == nil && summary.runId == nil && summary.observedAt == nil &&
                    summary.connectedAt == nil && summary.sourceRevision == nil && summary.capabilities?.read == false,
                    "\(name) 관련 summary 잔류 없음")
            }
            try apply(patch(2,set:sourceFields(normal)))
            choice.reconcile(reducer.projection)
            check(choice.sessionID == nil, "\(name) 정상 복귀 Codex 자동 재선택 없음")
            choice.select(source:.cursorCloud)
            check(choice.sessionID == nil && choice.currentResult(in:reducer.projection!,now:now) == nil,
                "\(name) 정상 복귀 Cloud 자동 재선택 없음")
            choice.select(session:reducer.projection!.sessions(for:.cursorCloud)[0],in:reducer.projection!)
            check(choice.currentResult(in:reducer.projection!,now:now) == body, "\(name) 명시적 재선택만 복구")
        }
    }

    for field in ["source","provider","key","externalId","sessionId","runId","ownerThreadId"] {
        var row = cloudRow; row[field] = "changed-\(field)"
        let changed = try projection([row])
        var choice = selected
        check(choice.currentResult(in:changed,now:now) == nil, "\(field) 변경 이전 본문 결박 해제")
        choice.reconcile(changed); choice.reconcile(initial)
        check(choice.sessionID == nil, "\(field) 복구 자동 재선택 없음")
    }
    var switched = selected
    for source in [ControlRoomSource.codex,.cursorDesktop] {
        switched.select(source:source)
        check(switched.currentResult(in:initial,now:now) == nil, "provider 전환 Cloud 본문 혼입 없음")
    }
    switched.select(source:.cursorCloud)
    check(switched.currentResult(in:initial,now:now) == body, "유효 Cloud 선택 복원")
    for field in ["key","externalId","sessionId","runId"] {
        for value in [NSNull(),""," \n"] as [Any] {
            var row = cloudRow; row[field] = value
            if field == "key" && value is NSNull {
                rejects("필수 key null은 잘못된 프레임") { _ = try projection([row]) }
            } else {
                let value = try projection([row])
                var choice = ControlRoomSourceSelection(); choice.select(source:.cursorCloud)
                if let session = value.sessions(for:.cursorCloud).first { choice.select(session:session,in:value) }
                check(choice.currentResult(in:value,now:now) == nil, "\(field) 불완전 식별자는 본문 미표시")
            }
        }
    }
    var mismatched = cloudRow; mismatched["sessionId"] = "other-agent"
    let mismatch = try projection([mismatched])
    check(cloudSelection(mismatch).currentResult(in:mismatch,now:now) == nil, "agent/session 불일치")
    for permission in [["read":false,"send":true],["send":true],[:]] {
        var denied = cloudRow; denied["capabilities"] = permission
        var powerful = summaries; powerful[1]["capabilities"] = ["read":true,"send":true]
        let value = try projection(rows.map { $0["source"] as? String == "cursor-cloud" ? denied : $0 },
            extra:["sourceConnections":powerful])
        check(selected.resultDisplay(in:value,now:now) == nil, "read 취소·누락을 owner/send/summary로 승격하지 않음")
        check(value.sourceSessionIDs == initial.sourceSessionIDs && value.sourceSelectionContext != initial.sourceSelectionContext,
            "같은 ID read 회수도 UI reconcile 관측값 변경")
        var choice = selected
        choice.reconcile(value); choice.reconcile(initial)
        check(choice.sessionID == nil && choice.resultDisplay(in:initial,now:now) == nil,
            "read 복구 자동 재선택 없음")
    }
    var readable = cloudRow
    readable["ownerVerified"] = false; readable["ownerThreadId"] = NSNull()
    readable["capabilities"] = ["read":true,"send":false]; readable["readOnly"] = true
    check(selected.session(in:try projection([readable])) == nil, "owner identity 변경은 기존 선택과 분리")
    let readOnly = try projection([readable])
    check(cloudSelection(readOnly).currentResult(in:readOnly,now:now) == body, "미확인 owner·send 불가도 행 read로 읽기 가능")
    for (field,value) in [("fresh",false),("stale",true)] as [(String,Any)] {
        var row = cloudRow; row[field] = value
        let stale = try projection(rows.map { $0["source"] as? String == "cursor-cloud" ? row : $0 })
        var choice = selected; choice.reconcile(stale)
        check(choice.sessionID == selected.sessionID && choice.currentResult(in:stale,now:now) == nil &&
            choice.resultDisplay(in:stale,now:now) == .lastObserved(body), "행 \(field) 현재 표시 차단·마지막 관측 보존")
        check(stale.sourceSelectionContext == initial.sourceSelectionContext,
            "단순 신선도 변경으로 선택 자격 회수 없음")
        choice.reconcile(initial)
        check(choice.currentResult(in:initial,now:now) == body, "같은 run 신선도 정상 복귀 선택 유지")
    }
    check(selected.currentResult(in:initial,now:now.addingTimeInterval(31)) == nil &&
        selected.currentResult(in:initial.disconnected(),now:now) == nil, "projection 만료·disconnect 본문 미표시")
    check(selected.currentResult(in:try projection(extra:["connection":["connected":false,"state":"stale"]]),now:now) == nil,
        "원본 stale 본문 미표시")
    check(selected.currentResult(in:try projection([cloudRow,cloudRow]),now:now) == nil, "중복 identity 본문 차단")
    for (label,value,at) in [("transport",initial.disconnected(),now),("clock",initial,now.addingTimeInterval(31)),
        ("connection stale",try projection(extra:["connection":["connected":false,"state":"stale"]]),now)] {
        var choice = selected; choice.reconcile(value)
        check(choice.sessionID == selected.sessionID && choice.currentResult(in:value,now:at) == nil &&
            choice.resultDisplay(in:value,now:at) == .lastObserved(body), "\(label) 선택·마지막 관측 보존")
        choice.reconcile(initial)
        check(choice.currentResult(in:initial,now:now) == body, "\(label) 같은 lineage 복귀")
    }
    let unavailable = try projection(extra:["connection":["connected":false,"state":"unavailable"]])
    var unavailableChoice = selected
    check(unavailableChoice.resultDisplay(in:unavailable,now:now) == nil, "unavailable은 마지막 관측도 제거")
    unavailableChoice.reconcile(unavailable); unavailableChoice.reconcile(initial)
    check(unavailableChoice.sessionID == nil, "unavailable 정상 복귀 자동 재선택 없음")

    for connection in [NSNull(),["connected":false,"state":"connected"],["connected":true,"state":"stale"]] as [Any] {
        rejects("relay 연결 누락·불일치 프레임 거부") { _ = try projection(extra:["connection":connection]) }
    }
    for extra in [["wireGeneration":generation],["connection":NSNull(),"wireGeneration":generation]] as [[String:Any]] {
        let legacy = try JSONDecoder().decode(ControlRoomProjection.self,from:encoded(snapshot([
            "unifiedControl":["schema":1,"rows":[cloudRow],"truncated":false]].merging(extra) { _,new in new })))
        check(legacy.isFresh(now:now) && legacy.wireGeneration == nil,
            "generic legacy fallback 보존·JSON wireGeneration 주입 무시")
        check(cloudSelection(legacy).sessionID == nil && selected.resultDisplay(in:legacy,now:now) == nil,
            "세대 미확인 Cloud 결과·선택 금지")
    }

    var generations = ControlRoomEventsReducer()
    let nextGeneration = "22222222-2222-4222-8222-222222222222"
    _ = try generations.consume(frames(frame(event("snapshot",0,fields:["generation":nextGeneration,
        "snapshot":snapshot(sourceFields(normal))])))[0],contract:.relayProjection)
    let newGeneration = generations.projection!
    var generationChoice = selected
    check(newGeneration.sourceSessionIDs == initial.sourceSessionIDs &&
        newGeneration.sourceSelectionContext != initial.sourceSelectionContext &&
        generationChoice.resultDisplay(in:newGeneration,now:now) == nil, "같은 ID 다른 event generation 자동 승계 없음")
    generationChoice.reconcile(newGeneration); generationChoice.reconcile(initial)
    check(generationChoice.sessionID == nil, "이전 generation 정상 복귀 자동 재선택 없음")
    generationChoice.select(session:initial.sessions(for:.cursorCloud)[0],in:initial)
    check(generationChoice.currentResult(in:initial,now:now) == body, "generation 변경 뒤 명시적 재선택")

    var reducer = ControlRoomEventsReducer()
    _ = try reducer.consume(frames(frame(event("snapshot",0,fields:["snapshot":snapshot(sourceFields(normal))])))[0],contract:.relayProjection)
    var current = cloudSelection(reducer.projection!)
    let replacements: [Any] = ["교체 응답 🧪 e\u{301}\n<script>alert(1)</script>","",NSNull(),
        String(repeating:"가",count:4000),String(repeating:"가",count:4000)+"a",String(repeating:"🧪",count:3000),
        String(repeating:"🧪",count:3001),"마지막 전체 응답"]
    for (index,result) in replacements.enumerated() {
        var row = cloudRow; row["result"] = result
        _ = try reducer.consume(frames(frame(patch(index+1,set:["unifiedControl":["schema":1,"rows":[row],"truncated":false]])))[0],contract:.relayProjection)
        let value = reducer.projection!
        current.reconcile(value)
        let expected = (result as? String).flatMap { $0.utf8.count <= 12_000 ? $0 : nil }
        check(current.sessionID == selected.sessionID && current.currentResult(in:value,now:now) == expected,
            "same-ID null/empty/UTF8 한도·전체 교체 \(index)")
        if expected == nil {
            check(current.resultDisplay(in:value,now:now) == nil, "null/UTF8 초과는 마지막 관측 본문도 제거")
        }
    }
    var absent = cloudRow; absent.removeValue(forKey:"result")
    let absentResult = try projection([absent])
    var absentChoice = selected
    check(absentChoice.resultDisplay(in:absentResult,now:now) == nil, "result 필드 제거 잔류 없음")
    absentChoice.reconcile(absentResult); absentChoice.reconcile(initial)
    check(absentChoice.sessionID == selected.sessionID && absentChoice.currentResult(in:initial,now:now) == body,
        "result 필드 제거와 같은 run 본문 도착은 선택 보존")
    for result in [false,123,["text":"오인 금지"],["오인 금지"]] as [Any] {
        var row = cloudRow; row["result"] = result
        rejects("malformed result는 문자열로 변환하지 않음") { _ = try projection([row]) }
    }
    var native = rows[1]; native["result"] = body; native["fresh"] = true; native["observedAt"] = clock
    let nativeProjection = try projection([native])
    var nativeChoice = ControlRoomSourceSelection(); nativeChoice.select(session:nativeProjection.sessions(for:.codex)[0],in:nativeProjection)
    check(nativeChoice.currentResult(in:nativeProjection,now:now) == nil, "nativeCodex result가 있어도 본문 미지원")

    let valid = try frame(event("snapshot",0,fields:["snapshot":snapshot(sourceFields(normal))]))
    var malformed = cloudRow; malformed["result"] = ["text":"잘못된 프레임"]
    let invalid = try frame(patch(1,set:["unifiedControl":["schema":1,"rows":[malformed],"truncated":false]]))
    for (label,suffix,finish) in [("invalidframe",invalid,false),("disconnect",Data(),true)] {
        StubURL.reset([.init(data:valid + suffix,finish:finish)])
        let updates = Updates()
        let task = Task { for await update in stream() { await updates.add(update) } }
        try await wait("\(label) 단절 전달") {
            await updates.all().contains { if case .disconnected = $0 { return true }; return false }
        }
        task.cancel(); await task.value
        let values = await updates.all()
        let last = values.last!.projection!
        check(last.transportConnected == false && selected.currentResult(in:last,now:now) == nil,
            "\(label) 이전 정상 result가 현재 응답으로 잔류하지 않음")
        var choice = selected; choice.reconcile(last)
        check(choice.sessionID == selected.sessionID && choice.resultDisplay(in:last,now:now) == .lastObserved(body),
            "\(label) read 가능한 마지막 공개 관측은 선택과 보존")
    }
    print("PASS Cloud terminal old observedAt 16case, observation 31/60/89/90초, current/lastObserved, read/unavailable 회수, null 선택 보존, generation/owner/run·복귀 선택, send 승격 0")
    print("PASS 공개 보호 6case source/selection synthetic snapshot·patch, Cloud 전체 교체/read/exact identity/UTF8, invalidframe/disconnect")
}
