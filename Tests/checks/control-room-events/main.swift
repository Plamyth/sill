import Foundation

func check(_ value: Bool, _ label: String) {
    precondition(value,label)
}
func encoded(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) }
func frame(_ value: [String:Any], ending: String = "\n") throws -> Data {
    Data("id: \(value["generation"]!):\(value["revision"]!)\(ending)event: \(value["type"]!)\(ending)data: \(String(decoding:try encoded(value),as:UTF8.self))\(ending)\(ending)".utf8)
}
func frames(_ data: Data) throws -> [ControlRoomSSE.Frame] {
    var parser = ControlRoomSSE()
    var result = [ControlRoomSSE.Frame]()
    for byte in data { if let frame = try parser.append(byte) { result.append(frame) } }
    if let frame = try parser.finish() { result.append(frame) }
    return result
}
let generation = "11111111-1111-4111-8111-111111111111"
let clock = "2026-10-23T00:00:00.000Z"
func event(_ type: String, _ revision: Int, fields: [String:Any] = [:]) -> [String:Any] {
    ["schema":"ccr.control-events/v1","type":type,"generation":generation,
     "revision":revision,"emittedAt":clock].merging(fields) { _,new in new }
}
func snapshot(_ extra: [String:Any] = [:]) -> [String:Any] {
    ["schemaVersion":1,"generatedAt":clock,"sourceObservedAt":clock,
     "connection":["connected":true,"state":"connected"],"threads":[],"catalog":[],
     "currentGrid":[],"workspaces":[]].merging(extra) { _,new in new }
}
func patch(_ revision: Int, set: [String:Any] = [:], unset: [String] = []) -> [String:Any] {
    event("patch",revision,fields:["baseRevision":revision-1,"set":set,"unset":unset,
        "threads":["upsert":[],"remove":[]],"catalog":["upsert":[],"remove":[]]])
}
func consume(_ reducer: inout ControlRoomEventsReducer, _ value: [String:Any]) throws -> ControlRoomEventsReducer.Outcome {
    try reducer.consume(frames(frame(value))[0],contract:.common)
}
func rejects(_ label: String, _ action: () throws -> Void) {
    do { try action(); preconditionFailure(label) } catch { }
}

final class StubURL: URLProtocol {
    struct Reply {
        var status = 200
        var mime = "text/event-stream; charset=utf-8"
        var data = Data()
        var finish = false
    }
    static let lock = NSLock()
    static var replies = [Reply]()
    static var requests = [URLRequest]()
    static var stops = 0
    static func reset(_ items: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        replies = items; requests = []; stops = 0
    }
    static func captured() -> ([URLRequest],Int) {
        lock.lock(); defer { lock.unlock() }; return (requests,stops)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.replies.isEmpty ? Reply(status:404,finish:true) : Self.replies.removeFirst()
        Self.lock.unlock()
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:reply.status,
            httpVersion:"HTTP/1.1",headerFields:["Content-Type":reply.mime])!,cacheStoragePolicy:.notAllowed)
        if !reply.data.isEmpty { client?.urlProtocol(self,didLoad:reply.data) }
        if reply.finish { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.lock.lock(); Self.stops += 1; Self.lock.unlock() }
}
actor Updates {
    var values = [ControlRoomEventUpdate]()
    func add(_ value: ControlRoomEventUpdate) { values.append(value) }
    func all() -> [ControlRoomEventUpdate] { values }
}
func wait(_ label: String, until condition: () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for:.milliseconds(10))
    }
    preconditionFailure(label)
}
func stream() -> AsyncStream<ControlRoomEventUpdate> {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURL.self]
    var request = URLRequest(url:URL(string:"https://fixture.invalid/control-room/events")!)
    request.setValue("synthetic-fixture-token",forHTTPHeaderField:"X-Canvas-Token")
    return ControlRoomEventStream.updates(request:request,configuration:config)
}

@main struct Checks {
    static func main() async throws {
        try sourceSessionChecks()
        let fixture = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"fixture.json"))) as! [String:Any]
        let common = fixture["events"] as! [[String:Any]]
        var reducer = ControlRoomEventsReducer()
        check(try consume(&reducer,common[0]) == .applied,"공통 snapshot")
        check(try consume(&reducer,common[1]) == .applied,"공통 patch")
        let before = try JSONEncoder().encode(ProjectionValue.object(reducer.snapshot!))
        check(try consume(&reducer,common[2]) == .heartbeat,"공통 heartbeat")
        check(try JSONSerialization.jsonObject(with:JSONEncoder().encode(ProjectionValue.object(reducer.snapshot!))) as! NSDictionary == JSONSerialization.jsonObject(with:before) as! NSDictionary,"heartbeat 원본 불변")
        check(try consume(&reducer,common[1]) == .ignored,"중복 patch")
        check(try consume(&reducer,fixture["gap"] as! [String:Any]) == .resync,"누락 재동기화")
        check(reducer.revision == 1,"누락 수용 금지")
        check(try consume(&reducer,fixture["replacement"] as! [String:Any]) == .applied,"generation 교체")
        check(try consume(&reducer,common[1]) == .resync,"이전 generation patch 거부")
        var older = fixture["replacement"] as! [String:Any]
        older["revision"] = 1
        _ = try consume(&reducer,older)
        check(try consume(&reducer,fixture["replacement"] as! [String:Any]) == .ignored,"이전 snapshot 무시")

        var strict = ControlRoomEventsReducer()
        let validRelayFrame = try frames(frame(event("snapshot",0,fields:["snapshot":snapshot()])))[0]
        _ = try strict.consume(validRelayFrame,contract:.relayProjection)
        for removedField in ["connection","sourceObservedAt","threads","catalog","currentGrid","workspaces"] {
            var invalid = snapshot(); invalid.removeValue(forKey:removedField)
            rejects("SSE 필수 메타데이터 누락") {
                _ = try strict.consume(frames(frame(event("snapshot",1,fields:["snapshot":invalid])))[0],contract:.relayProjection)
            }
            check(strict.revision == 0,"SSE 검증 실패는 마지막 정상 상태 보존")
        }
        rejects("connected 원본 관측 null 거부") {
            _ = try strict.consume(frames(frame(event("snapshot",1,fields:["snapshot":snapshot(["sourceObservedAt":NSNull()])])))[0],contract:.relayProjection)
        }
        rejects("연결 상태 모순 거부") {
            _ = try strict.consume(frames(frame(event("snapshot",1,fields:["snapshot":snapshot(["connection":["connected":true,"state":"stale"]])])))[0],contract:.relayProjection)
        }
        for invalidField in ["threads","catalog"] {
            for badValue in [NSNull(),"not-an-array",[["id":"private-row"]]] as [Any] {
                rejects("relay 비공개 행 배열 계약 거부") {
                    _ = try strict.consume(frames(frame(event("snapshot",1,fields:["snapshot":snapshot([invalidField:badValue])])))[0],contract:.relayProjection)
                }
            }
        }
        rejects("원본 관측 시각 불일치 거부") {
            _ = try strict.consume(frames(frame(event("snapshot",1,fields:["snapshot":snapshot(["sourceObservedAt":"2026-10-23T00:00:01.000Z"])])))[0],contract:.relayProjection)
        }
        let now = BrainTrinityFeed.date(clock)!
        reducer = ControlRoomEventsReducer()
        _ = try consume(&reducer,event("snapshot",0,fields:["snapshot":snapshot()]))
        check(reducer.projection!.isFresh(now:now),"연결 원본 신선도")
        check(!reducer.projection!.isFresh(now:now.addingTimeInterval(31)),"30초 원본 보안 유지")
        let generated = reducer.projection!.generatedAt
        var heartbeat = event("heartbeat",0); heartbeat["emittedAt"] = "2026-10-23T00:01:00.000Z"
        _ = try consume(&reducer,heartbeat)
        check(reducer.projection!.generatedAt == generated && reducer.projection!.sourceObservedAt == clock,"heartbeat 관측시각 갱신 금지")
        check(!reducer.projection!.disconnected().isFresh(now:now),"전송 단절 권한 차단")
        _ = try consume(&reducer,patch(1,set:["connection":["connected":false,"state":"stale"]]))
        check(!reducer.projection!.isFresh(now:now) && reducer.projection!.hasDisplayContent,"UDS 단절 마지막 내용")
        let legacy = try JSONDecoder().decode(ControlRoomProjection.self,from:encoded(["schemaVersion":1,
            "generatedAt":clock,"currentGrid":[],"workspaces":[]]))
        check(legacy.connection == nil && legacy.isFresh(now:now),"legacy GET Decodable 호환")
        let unavailable: [String:Any] = ["schemaVersion":1,"threads":[],"catalog":[],"sourceObservedAt":NSNull(),
            "connection":["connected":false,"state":"unavailable"]]
        _ = try consume(&reducer,event("snapshot",2,fields:["snapshot":unavailable]))
        check(reducer.projection!.currentGrid.isEmpty && !reducer.projection!.hasDisplayContent,"최초 unavailable grid 없음")

        let cards: [[String:Any]] = (0..<4002).map { index in
            ["index":index,"kind":"normal","threadId":"card-\(index)",
             "card":["id":"card-\(index)","title": index == 4000 ? "Cursor Desktop" : index == 4001 ? "Cursor Cloud" : "대화 \(index)",
                     "source":"codex","available":true,"latestProgress":["id":"progress", "text":String(repeating:"가",count:80)]]]
        }
        _ = try consume(&reducer,event("snapshot",3,fields:["snapshot":snapshot(["currentGrid":cards])]))
        check(reducer.projection!.currentGrid.count == 4002,"4,002 snapshot 카드")
        check(reducer.projection!.currentGrid.suffix(2).map { $0.card?.title ?? "" } == ["Cursor Desktop","Cursor Cloud"],"4,000 뒤 Cursor 두 카드")
        _ = try consume(&reducer,patch(4,set:["currentGrid":cards]))
        check(reducer.projection!.currentGrid.count == 4002,"큰 patch 카드 보존")
        let removed = ["generatedAt","currentGrid","workspaces","voiceCard","activeVoiceId","activeVoiceSession","projects"]
        _ = try consume(&reducer,patch(5,set:["connection":["connected":false,"state":"unavailable"]],unset:removed))
        check(reducer.projection!.currentGrid.isEmpty && reducer.projection!.voiceCard == nil && !reducer.projection!.hasDisplayContent,"숨김 정책 제거 후 예전 카드 노출 금지")

        let raw = try frame(event("snapshot",0,fields:["snapshot":snapshot()]),ending:"\r\n")
        check(try frames(Data("\u{feff}: 주석\r\n\r\n".utf8)+raw).count == 1,"UTF8 BOM 주석 CRLF")
        check(try frames(frame(event("snapshot",0,fields:["snapshot":snapshot()]),ending:"\r")).count == 1,"CR 분할")
        check(try frames(Data(raw.dropLast(2))).isEmpty,"불완전 frame 미수용")
        rejects("본문 제한") {
            _ = try frames(Data("data: \(String(repeating:"a",count:ControlRoomSSE.maxBodyBytes+1))\n\n".utf8))
        }
        check(try frames(Data("data: \(String(repeating:"a",count:ControlRoomSSE.maxBodyBytes))\n\n".utf8))[0].data.count == ControlRoomSSE.maxBodyBytes,"본문 정확 경계 수용")
        rejects("CRLF 전체 frame 실제 byte 제한") {
            let lines = String(repeating:":\r\n",count:ControlRoomSSE.maxFrameBytes / 3 + 1)
            _ = try frames(Data(lines.utf8))
        }
        rejects("전체 frame 제한") {
            _ = try frames(Data((":"+String(repeating:"a",count:ControlRoomSSE.maxFrameBytes)).utf8))
        }
        rejects("악성 키") {
            var copy = reducer
            _ = try consume(&copy,event("snapshot",6,fields:["snapshot":snapshot(["nested":["__proto__":true]])]))
        }
        rejects("id 불일치") {
            var copy = reducer
            _ = try copy.consume(ControlRoomSSE.Frame(id:"bad",event:"snapshot",data:encoded(event("snapshot",6,fields:["snapshot":snapshot()]))),contract:.common)
        }
        print("PASS 공통 reducer, 순서, 관측시각, legacy, unavailable, 4,002 카드, 파서와 크기 제한")

        var lease = ControlRoomConnectionGeneration()
        let oldGeneration = lease.begin(address:"https://mac-a.invalid",token:"synthetic-a")
        let newGeneration = lease.begin(address:"https://mac-a.invalid",token:"synthetic-a")
        check(!oldGeneration.retainsContent && newGeneration.retainsContent,"같은 출처에서만 마지막 내용 유지")
        check(!lease.owns(oldGeneration) && lease.owns(newGeneration),"취소된 옛 연결 update와 defer 차단")
        var guardedProjection = reducer.projection
        if lease.owns(oldGeneration) { guardedProjection = nil }
        check(guardedProjection != nil,"옛 defer가 새 projection을 지우지 않음")
        let anotherMac = lease.begin(address:"https://mac-b.invalid",token:"synthetic-a")
        check(!anotherMac.retainsContent && !lease.owns(newGeneration),"Mac 변경은 이전 카드와 연결 세대 제거")
        let anotherToken = lease.begin(address:"https://mac-b.invalid",token:"synthetic-b")
        check(!anotherToken.retainsContent && !lease.owns(anotherMac),"토큰 변경도 이전 카드와 연결 세대 제거")

        let full0 = try frame(event("snapshot",0,fields:["snapshot":snapshot()]))
        let full1 = try frame(event("snapshot",1,fields:["snapshot":snapshot(["workspace":"reconnected"])]))
        StubURL.reset([.init(data:full0,finish:true),.init(data:full1)])
        let received = Updates()
        let consumer = Task { for await value in stream() { await received.add(value) } }
        try await wait("재연결 snapshot",until:{ await received.all().contains { $0.projection?.workspace == "reconnected" } })
        let requests = StubURL.captured().0
        check(requests.count == 2 && requests[1].value(forHTTPHeaderField:"Last-Event-ID") == "\(generation):0","Last-Event-ID 재연결")
        check(requests.allSatisfy { $0.value(forHTTPHeaderField:"Authorization") == nil &&
            $0.value(forHTTPHeaderField:"X-Canvas-Token") == "synthetic-fixture-token" &&
            $0.url?.path == "/control-room/events" },"기존 토큰 유지와 polling 금지")
        check(await received.all().contains { $0.projection?.transportConnected == false && $0.message != nil },"단절 stale 전달")
        consumer.cancel(); await consumer.value
        try await wait("구독 취소가 task 정리",until:{ StubURL.captured().1 > 0 })
        let requestCount = StubURL.captured().0.count
        try await Task.sleep(for:.milliseconds(1100))
        check(StubURL.captured().0.count == requestCount,"취소 뒤 재연결 금지")

        StubURL.reset([.init(data:full0 + (try frame(patch(2)))),.init(data:full1)])
        let gapConsumer = Task { for await _ in stream() { } }
        try await wait("gap cursor 없는 재연결",until:{ StubURL.captured().0.count == 2 })
        check(StubURL.captured().0[1].value(forHTTPHeaderField:"Last-Event-ID") == nil,"gap cursor 제거")
        gapConsumer.cancel(); await gapConsumer.value

        StubURL.reset([.init(status:404,finish:true)])
        var unsupported = false
        for await value in stream() { unsupported = value.message?.contains("지원하지 않습니다") == true }
        check(unsupported && StubURL.captured().0.count == 1,"미지원 endpoint 명확 표시와 fallback 금지")

        StubURL.reset([.init(data:full0,finish:true),.init(status:503,finish:true),.init(data:full1)])
        let retryUpdates = Updates()
        let retryConsumer = Task { for await value in stream() { await retryUpdates.add(value) } }
        try await wait("서버 오류 후 복구",until:{ await retryUpdates.all().contains { $0.projection?.workspace == "reconnected" } })
        check(StubURL.captured().0[2].value(forHTTPHeaderField:"Last-Event-ID") == "\(generation):0","HTTP 재시도 cursor 보존")
        retryConsumer.cancel(); await retryConsumer.value
        StubURL.reset([.init(status:401,finish:true)])
        for await _ in stream() { }
        check(StubURL.captured().0.count == 1,"인증 거부 자동 재발급 금지")
        for mime in ["application/json","text/html"] {
            StubURL.reset([.init(mime:mime,data:Data(),finish:true),.init(data:full1)])
            let mimeUpdates = Updates()
            let mimeConsumer = Task { for await value in stream() { await mimeUpdates.add(value) } }
            try await wait("잘못된 MIME 뒤 이벤트 복구",until:{
                await mimeUpdates.all().contains { $0.projection?.workspace == "reconnected" }
            })
            check(StubURL.captured().0.count == 2,"\(mime) HTTP200은 영구 종료 대신 재접속")
            check(StubURL.captured().0[1].value(forHTTPHeaderField:"Last-Event-ID") == nil,
                  "\(mime) 불완전 초기 응답의 cursor를 수용하지 않음")
            mimeConsumer.cancel(); await mimeConsumer.value
        }

        var burst = full0
        for revision in 1...120 { burst += try frame(patch(revision,set:["workspace":"revision-\(revision)"])) }
        StubURL.reset([.init(data:burst)])
        let bounded = stream()
        try await Task.sleep(for:.milliseconds(600))
        var iterator = bounded.makeAsyncIterator()
        let newest = await iterator.next()
        check(newest?.projection?.workspace == "revision-120","backpressure 최신 1개와 모든 patch 적용")
        let cleanup = Task { for await _ in bounded { } }
        cleanup.cancel(); await cleanup.value

        let policyRemoval = patch(1,set:["connection":["connected":false,"state":"unavailable"]],
            unset:["generatedAt","currentGrid","workspaces","voiceCard","activeVoiceId","activeVoiceSession"])
        StubURL.reset([.init(data:full0 + (try frame(policyRemoval)))])
        let policyStream = stream()
        try await Task.sleep(for:.milliseconds(200))
        var policyIterator = policyStream.makeAsyncIterator()
        let policyUpdate = await policyIterator.next()
        if case .unavailable? = policyUpdate { } else { preconditionFailure("정책 삭제는 명시적 unavailable") }
        check(policyUpdate?.projection == nil,"정책 unavailable 실제 nil")
        let policyCleanup = Task { for await _ in policyStream { } }
        policyCleanup.cancel(); await policyCleanup.value
        StubURL.reset([.init(data:full0 + (try frame(policyRemoval)),finish:true)])
        let policyEOF = stream()
        try await Task.sleep(for:.milliseconds(200))
        var eofIterator = policyEOF.makeAsyncIterator()
        let eofUpdate = await eofIterator.next()
        if case .disconnected(let last, _)? = eofUpdate { check(last == nil,"정책 삭제 뒤 단절도 이전 카드 보존 금지") }
        else { preconditionFailure("정책 삭제 뒤 단절 전달") }
        let eofCleanup = Task { for await _ in policyEOF { } }
        eofCleanup.cancel(); await eofCleanup.value

        let delegate = ControlRoomEventRedirects()
        let session = URLSession(configuration:.ephemeral)
        let task = session.dataTask(with:URL(string:"https://fixture.invalid")!)
        var redirected = true
        delegate.urlSession(session,task:task,
            willPerformHTTPRedirection:HTTPURLResponse(url:task.originalRequest!.url!,statusCode:302,httpVersion:nil,headerFields:nil)!,
            newRequest:URLRequest(url:URL(string:"https://elsewhere.invalid")!)) { redirected = $0 != nil }
        check(!redirected,"redirect 차단")
        session.invalidateAndCancel()
        print("PASS URLProtocol 격리 전송, 재접속, cursor, 오류, 취소, 최신 1개 버퍼, redirect 차단. 실제 네트워크 0")
    }
}
