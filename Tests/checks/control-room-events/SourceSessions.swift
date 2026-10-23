import Foundation

func sourceSessionChecks() throws {
    let data = try Data(contentsOf:URL(fileURLWithPath:"android-mobile-control-events-v1.json"))
    let fixture = try JSONSerialization.jsonObject(with:data) as! [String:Any]
    let events = fixture["events"] as! [[String:Any]]
    let android = events[0]["snapshot"] as! [String:Any]
    let unified = android["unifiedControl"] as! [String:Any]
    let rows = unified["rows"] as! [[String:Any]]
    let summaries = android["sourceConnections"] as! [[String:Any]]
    let now = BrainTrinityFeed.date(clock)!
    func projection(_ sourceRows: [[String:Any]] = rows, extra: [String:Any] = [:]) throws -> ControlRoomProjection {
        let root = snapshot([
            "unifiedControl":["schema":1,"rows":sourceRows,"truncated":false,"error":NSNull()],
            "sourceConnections":summaries].merging(extra) { _,new in new })
        var reducer = ControlRoomEventsReducer()
        _ = try reducer.consume(.init(id:"\(generation):0",event:"snapshot",
            data:encoded(event("snapshot",0,fields:["snapshot":root]))),contract:.relayProjection)
        return reducer.projection!
    }
    let initial = try projection()
    check(rows.count == 3 && initial.sourceSessions.count == 3,"Android exact DTO 3 provider 보존")
    check(initial.currentGrid.isEmpty,"Android 모바일 root를 relay currentGrid로 오인하지 않음")
    for source in ControlRoomSource.allCases {
        check(initial.sessions(for:source).count == 1,"provider 분리")
        check(initial.sourceSummary(for:source)?.provider == source.rawValue,"요약 provider 분리")
    }
    let codex = initial.sessions(for:.codex)[0]
    let cloud = initial.sessions(for:.cursorCloud)[0]
    check(codex.sessionConnection(now:now) == .current,"Codex 개별 연결 결박")
    check(codex.capabilities?.send == true && codex.sourceConnection?.capabilities?.send == false &&
        codex.sourceConnection?.readOnly == true,"행 권한과 개별 연결 보고 권한 분리")
    check(cloud.status == "FINISHED" && cloud.executionStatus == "FINISHED" && cloud.agentStatus == "IDLE" &&
        cloud.connectionState == "closed" && cloud.isFresh(now:now),"원본 실행·agent·연결·최신 관측 독립")
    check(!cloud.isFresh(now:now.addingTimeInterval(31)),"행 관측 30초 만료")
    check(!cloud.isFresh(now:now.addingTimeInterval(-6)),"미래 행 관측 거부")

    var selected = ControlRoomSourceSelection()
    selected.select(session:codex,in:initial)
    selected.select(source:.cursorCloud)
    check(selected.sessionID == nil,"provider 전환 자동 선택 금지")
    selected.select(session:cloud,in:initial)
    selected.select(source:.codex)
    check(selected.session(in:initial)?.id == codex.id,"존재하는 Codex 선택만 복원")
    selected.select(source:.cursorCloud)
    check(selected.session(in:initial)?.id == cloud.id,"존재하는 Cloud 선택만 복원")
    selected.select(session:codex,in:initial)
    check(selected.sessionID == cloud.id,"다른 provider 행 선택 거부")

    let identityFields = ["source","key","externalId","sessionId","runId","hostId","instanceId",
        "startedAt","workspaceIdentity","ownerThreadId"]
    for field in identityFields {
        var changed = rows[0]
        changed[field] = "different-\(field)"
        let replacement = try projection([changed,rows[1],rows[2]])
        var choice = ControlRoomSourceSelection()
        choice.select(session:codex,in:initial)
        check(choice.session(in:replacement) == nil,"\(field) 교체 자동 승계 금지")
        choice.reconcile(replacement)
        choice.reconcile(initial)
        check(choice.sessionID == nil,"\(field) 교체 뒤 이전 identity 재등장 자동 선택 금지")
    }
    var removed = selected
    removed.reconcile(try projection([rows[0],rows[1]]))
    removed.reconcile(initial)
    check(removed.sessionID == nil,"사라진 Cloud 재등장 자동 승계 금지")
    removed.select(source:.codex)
    check(removed.sessionID == codex.id,"다른 source의 유효 선택 보존")
    removed.reconcile(nil)
    check(removed.sessionID == nil,"상위 projection 해제는 선택 삭제")

    var sameRows = rows
    for index in sameRows.indices {
        sameRows[index]["title"] = "같은 제목"
        sameRows[index]["externalId"] = "같은 ID"
        sameRows[index]["sessionId"] = "같은 ID"
        sameRows[index]["key"] = "같은 키"
    }
    let same = try projection(sameRows)
    check(Set(same.sourceSessionIDs).count == 3,"같은 제목·키·ID의 교차 provider 병합 0")
    var sameProvider = rows[0]
    sameProvider["runId"] = "다른 실행"
    sameProvider["title"] = rows[0]["title"]
    check(try projection([rows[0],sameProvider]).sessions(for:.codex).count == 2,"같은 제목·key·외부 ID의 다른 실행 별도 표시")
    let duplicate = try projection([rows[0],rows[0],rows[1]])
    check(duplicate.sessions(for:.codex).isEmpty && duplicate.sessions(for:.cursorDesktop).count == 1,"중복 복합 identity 선택 차단")

    var large = [[String:Any]]()
    for index in 0..<4000 {
        var row = rows[0]
        row["key"] = "codex:\(index)"
        row["externalId"] = "codex-\(index)"
        row["sessionId"] = "codex-\(index)"
        large.append(row)
    }
    large += [rows[1],rows[2]]
    let many = try projection(large)
    check(many.sourceSessions.count == 4002 && many.sessions(for:.codex).count == 4000 &&
        many.sessions(for:.cursorDesktop).count == 1 && many.sessions(for:.cursorCloud).count == 1,"4000 Codex 뒤 Cursor 2 누락 0")

    for field in ["provider","sessionId","runId"] {
        var row = rows[0]
        var connection = row["sourceConnection"] as! [String:Any]
        connection[field] = "mismatched"
        row["sourceConnection"] = connection
        let bad = try projection([row]).sessions(for:.codex)[0]
        check(bad.sessionConnection(now:now) == .mismatched && !bad.reportedSendAllowed(now:now),"개별 \(field) mismatch")
    }
    for field in ["threadId","activeTurnId"] {
        var row = rows[0]; row[field] = "alias-mismatch"
        check(try projection([row]).sessions(for:.codex)[0].sessionConnection(now:now) == .mismatched,"Codex \(field) 결박")
    }
    for (field,value) in [("connected",false),("state","stale"),("owner",""),("sourceRevision",-1),
                          ("sourceRevision",0.5),("sourceRevision","7"),("observedAt","2026-10-22T23:59:00Z")] as [(String,Any)] {
        var row = rows[0]
        var connection = row["sourceConnection"] as! [String:Any]
        connection[field] = value
        row["sourceConnection"] = connection
        let bad = try projection([row]).sessions(for:.codex)[0]
        check(bad.sessionConnection(now:now) == .stale && !bad.reportedSendAllowed(now:now),"개별 \(field) 오래된 관측")
    }
    for field in ["fresh","stale"] {
        var row = rows[0]; row[field] = field == "stale"
        let bad = try projection([row]).sessions(for:.codex)[0]
        check(bad.sessionConnection(now:now) == .stale && !bad.reportedSendAllowed(now:now),"행 \(field) 연결 최신성")
    }
    var noConnection = rows[0]; noConnection.removeValue(forKey:"sourceConnection")
    let summaryOnly = try projection([noConnection]).sessions(for:.codex)[0]
    check(summaryOnly.sessionConnection(now:now) == .unavailable && !summaryOnly.reportedSendAllowed(now:now),"요약 연결로 개별 연결 승격 금지")
    var denied = rows[2]
    denied["readOnly"] = true
    denied["capabilities"] = ["read":false,"send":false]
    var powerful = summaries
    powerful[2]["readOnly"] = false
    powerful[2]["capabilities"] = ["read":true,"send":true]
    let noPromotion = try projection([denied],extra:["sourceConnections":powerful])
    check(!noPromotion.sessions(for:.cursorCloud)[0].reportedSendAllowed(now:now),"요약 send로 행 권한 승격 금지")
    var hiddenSummary: [String:Any] = ["provider":"codex","state":"unavailable","connected":false,
        "readOnly":true,"capabilities":["read":false,"send":false],"reason":"숨김 정책으로 연결 정보를 제공하지 않습니다."]
    for field in ["connectedAt","observedAt","owner","sessionId","runId","sourceRevision"] {
        hiddenSummary[field] = NSNull()
    }
    let hidden = try projection([rows[1],rows[2]],extra:["sourceConnections":[hiddenSummary]])
    let hiddenConnection = hidden.sourceSummary(for:.codex)!
    check(hiddenConnection.label == "연결 정보 없음" && hiddenConnection.connected == false &&
        hiddenConnection.connectedAt == nil && hiddenConnection.observedAt == nil && hiddenConnection.owner == nil &&
        hiddenConnection.sessionId == nil && hiddenConnection.runId == nil && hiddenConnection.sourceRevision == nil &&
        hiddenConnection.readOnly == true && hiddenConnection.capabilities?.read == false &&
        hiddenConnection.capabilities?.send == false && hiddenConnection.reason == hiddenSummary["reason"] as? String,
        "숨김 unavailable 요약과 한국어 안내를 그대로 수용")
    check(hidden.sessions(for:.codex).isEmpty && hidden.sessions(for:.cursorCloud)[0].status == cloud.status,
        "숨김 source 요약을 다른 행 상태와 섞지 않음")
    var hiddenChoice = ControlRoomSourceSelection(); hiddenChoice.select(session:codex,in:initial)
    hiddenChoice.reconcile(hidden); hiddenChoice.reconcile(initial)
    check(hiddenChoice.sessionID == nil,"숨김 제거 뒤 재등장 자동 선택 금지")
    let remainingRow = try projection(extra:["sourceConnections":[hiddenSummary]])
    check(remainingRow.sessions(for:.codex)[0].sessionConnection(now:now) == .current &&
        remainingRow.sessions(for:.codex)[0].capabilities?.send == codex.capabilities?.send,
        "provider unavailable 요약으로 별도 개별 연결·행 보고 권한을 덮지 않음")
    let noSummary = try projection(extra:["sourceConnections":NSNull()])
    check(noSummary.sessions(for:.cursorCloud)[0].capabilities?.send == true && noSummary.sourceSummary(for:.cursorCloud) == nil,"행 보고 권한을 요약으로 덮지 않음")
    var unknownOwner = rows[2]; unknownOwner["ownerVerified"] = false
    let unverified = try projection([unknownOwner]).sessions(for:.cursorCloud)[0]
    check(unverified.ownerThreadId == cloud.ownerThreadId && unverified.ownerLabel == "미확인" && !unverified.reportedSendAllowed(now:now),"원본 owner 보존과 확인된 owner 분리")
    var malformedProvider = rows[0]; malformedProvider["provider"] = "cursor-cloud"
    let mismatch = try projection([malformedProvider])
    check(mismatch.sessions(for:.codex).isEmpty,"source/provider 불일치 미지원")
    var remembered = ControlRoomSourceSelection(); remembered.select(session:codex,in:initial)
    remembered.reconcile(mismatch); remembered.reconcile(initial)
    check(remembered.sessionID == nil && mismatch.sourceSessionIDs.isEmpty,"지원 취소 후 같은 identity 복구 자동 선택 금지")

    let legacy = try JSONDecoder().decode(ControlRoomProjection.self,from:encoded(snapshot()))
    check(legacy.unifiedControl == nil && legacy.sourceConnections == nil && legacy.sourceSessions.isEmpty,"optional 없는 legacy")
    let privateOnly = try projection([],extra:["unifiedControl":NSNull(),"unifiedPayload":["rows":rows],"sourceConnections":NSNull()])
    check(privateOnly.sourceSessions.isEmpty,"비공개 unifiedPayload 직접 해석 금지")
    let wrongSchema = try projection(extra:["unifiedControl":["schema":2,"rows":rows,"truncated":false]])
    check(wrongSchema.sourceSessions.isEmpty,"미지원 schema 비노출")

    var reducer = ControlRoomEventsReducer()
    let root = snapshot(["unifiedControl":unified,"sourceConnections":summaries])
    _ = try reducer.consume(frames(frame(event("snapshot",0,fields:["snapshot":root])))[0],contract:.relayProjection)
    check(reducer.projection!.sourceSessions.count == 3,"relay strict root optional DTO 수용")
    let before = reducer.projection!.sourceSessions[2].status
    let patchRows = (events[1]["set"] as! [String:Any])["unifiedControl"]!
    _ = try reducer.consume(frames(frame(patch(1,set:["unifiedControl":patchRows])))[0],contract:.relayProjection)
    check(before == "FINISHED" && reducer.projection!.sourceSessions[2].status == "RUNNING" &&
        reducer.projection!.sourceSessions[2].agentStatus == "IDLE","exact Android patch 상태 변화와 agent 분리")
    _ = try reducer.consume(frames(frame(patch(2,set:["connection":["connected":false,"state":"unavailable"]],
        unset:["unifiedControl","sourceConnections","generatedAt","currentGrid","workspaces"])))[0],contract:.relayProjection)
    check(reducer.projection!.sourceSessions.isEmpty && reducer.projection!.sourceConnections == nil,"unavailable 필드 제거는 세션·요약 제거")
    var unavailableSelection = selected
    unavailableSelection.reconcile(reducer.projection)
    unavailableSelection.reconcile(initial)
    check(unavailableSelection.sessionID == nil,"unavailable 복구 자동 승계 금지")
    for field in ["threads","catalog"] {
        var bad = root; bad[field] = [["id":"private"]]
        rejects("optional DTO로 strict 배열 완화 금지") {
            _ = try reducer.consume(frames(frame(event("snapshot",3,fields:["snapshot":bad])))[0],contract:.relayProjection)
        }
    }
    rejects("잘못된 optional rows 타입 거부") {
        _ = try projection(extra:["unifiedControl":["schema":1,"rows":"private-items","truncated":false]])
    }
    print("PASS 소스·세션 exact Android DTO, 4002행, 복합 선택, 권한 분리, 개별 연결, legacy/strict SSE")
}
