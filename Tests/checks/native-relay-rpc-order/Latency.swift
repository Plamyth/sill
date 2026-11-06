import Foundation

extension Checks {
    @MainActor static func latencyLines() -> [[String: String]] {
        HostLog.shared.lines(after: 0).filter { $0.text.hasPrefix("audio.trace relayRPC ") }.map {
            Dictionary(uniqueKeysWithValues: $0.text.split(separator: " ").dropFirst(2).compactMap { field in
                let parts = field.split(separator: "=", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            })
        }
    }
    @MainActor static func latencyDiagnostics() async {
        await serverLatencyDiagnostics()
        let f = await Fixture.make("latency"), relay = f.relay
        HostLog.shared.configure(keepLines: 2048, fileURL: nil)
        for _ in 0..<80 {
            expect(await relay.checkedTrace(until: .now.advanced(by: .seconds(2))) == 1, "빠른 정상 OFF 대응 제어 왕복")
        }
        expect(latencyLines().isEmpty, "빠른 정상 제어 왕복은 유한 진단 예산을 소진하지 않음")
        let slow = Task { await relay.checkedTrace(delay: 0.4, until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkPending }
        let queued = Task { await relay.checkedTrace(until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkWaiting == 1 }
        let expired = Task { await relay.checkedTrace(until: .now.advanced(by: .milliseconds(40))) }
        await wait { relay.checkWaiting == 2 }
        let cancelled = Task { await relay.checkedTrace(until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkWaiting == 3 }
        cancelled.cancel()
        let expiredValue = await expired.value, cancelledValue = await cancelled.value
        expect(expiredValue == nil && cancelledValue == nil, "미전송 deadline과 취소는 nil")
        let slowValue = await slow.value, queuedValue = await queued.value
        expect(slowValue == 1 && queuedValue == 1 && relay.checkConnected, "느린 활성 호출과 살아남은 FIFO 호출 완료")
        let lines = latencyLines()
        print("LATENCY_REPRO records=\(lines.count)")
        expect(lines.count == 4, "느린 응답·FIFO 대기·미전송 deadline·취소를 각 한 줄로 기록")
        expect(lines.contains { $0["phase"] == "queueDeadline" && $0["sent"] == "false" && $0["success"] == "false" }, "큐 만료는 응답 timeout과 구분")
        expect(lines.contains { $0["phase"] == "queueCancelled" && $0["sent"] == "false" }, "큐 취소 종료 단계")
        let successes = lines.filter { $0["success"] == "true" }
        expect(successes.count == 2 && successes.contains { (Double($0["queueMs"] ?? "") ?? -1) >= 250 } &&
            successes.contains { (Double($0["writeToReadMs"] ?? "") ?? -1) >= 250 }, "FIFO 대기와 자식 응답 지연을 분리")
        print("LATENCY_PHASE_METRICS queueMaxMs=\(successes.compactMap { Double($0["queueMs"] ?? "") }.max() ?? -1) writeToReadMaxMs=\(successes.compactMap { Double($0["writeToReadMs"] ?? "") }.max() ?? -1)")
        expect(Set(lines.compactMap { $0["request"] }).count == 4 && lines.allSatisfy { UUID(uuidString: $0["request"] ?? "") != nil }, "유효한 개별 RPC requestID로 상관 관계 유지")

        let hop = Task { await relay.checkedTrace(delay: 0.04, until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkPending }
        Thread.sleep(forTimeInterval: 0.4)
        expect(await hop.value == 1, "MainActor 지연 뒤 실제 pipe 응답은 기존 기한 안에서 수용")
        expect(latencyLines().contains { (Double($0["readHopMs"] ?? "") ?? -1) >= 200 }, "비격리 stdio 읽기부터 MainActor 진입까지 지연 기록")
        print("LATENCY_HOP_METRICS maxMs=\(latencyLines().compactMap { Double($0["readHopMs"] ?? "") }.max() ?? -1)")
        let count = f.requests().count
        expect(await relay.checkedTrace("TRACE_METHOD_SECRET", until: .now.advanced(by: .seconds(2)), admission: { false }) == nil,
               "최종 admission 실패 시 전송0")
        expect(f.requests().count == count && latencyLines().last?["phase"] == "admission", "admission 실패를 deadline·IPC 실패와 구분")
        expect(latencyLines().last?["method"] == "other", "알 수 없는 method 문자열을 로그에 복사하지 않음")
        let text = HostLog.shared.lines(after: 0).map(\.text).joined(separator: "\n")
        expect(!["TRACE_CREDENTIAL_SECRET", "TRACE_PCM_SECRET", "TRACE_METHOD_SECRET", "credential", "payload"].contains(where: text.contains),
               "본문·credential·PCM·임의 method 비밀값 로그0")
        for _ in 0..<80 { _ = await relay.checkedTrace(until: .now.advanced(by: .seconds(2)), admission: { false }) }
        expect(latencyLines().count == 64, "느리거나 실패한 호출의 진단 상한은 정확히 64개")
        f.finish()

        for cancel in [false, true] {
            let active = await Fixture.make("latency")
            LocalAudioRelay.checkResetRPCTraceBudget()
            HostLog.shared.configure(keepLines: 128, fileURL: nil)
            let task = Task { await active.relay.checkedTrace(delay: 0.4,
                until: .now.advanced(by: .milliseconds(cancel ? 2000 : 60))) }
            await wait { active.relay.checkPending }
            if cancel { task.cancel() }
            expect(await task.value == nil && active.relay.checkClosed, "전송 후 취소·기한은 기존 relay 종료 계약 유지")
            expect(latencyLines().count == 1 && latencyLines()[0]["phase"] == (cancel ? "responseCancelled" : "responseDeadline") &&
                latencyLines()[0]["sent"] == "true", "전송된 호출 실패 단계 구분")
            active.finish()
        }
        let late = await Fixture.make("latency")
        LocalAudioRelay.checkResetRPCTraceBudget()
        HostLog.shared.configure(keepLines: 128, fileURL: nil)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(140))
        let task = Task { await late.relay.checkedTrace(delay: 0.04, until: deadline) }
        await wait { late.relay.checkPending }
        Thread.sleep(forTimeInterval: 0.4)
        expect(await task.value == nil && late.relay.checkClosed, "read가 이미 끝나도 MainActor 진입이 기한 뒤이면 원래 deadline대로 거절")
        for _ in 0..<20 { await Task.yield() }
        let lateLines = HostLog.shared.lines(after: 0).map(\.text)
        expect(lateLines.contains { $0.hasPrefix("audio.trace relayRPC ") && !$0.contains("readNs=unobserved") },
               "timer가 receive를 추월해도 비격리 read 시각 보존")
        expect(lateLines.contains { ($0.hasPrefix("audio.trace relayRead ") || $0.hasPrefix("audio.trace relayRPC ")) &&
            $0.split(separator: " ").contains { field in
                field.hasPrefix("readHopMs=") && (Double(field.dropFirst("readHopMs=".count)) ?? -1) >= 200
            } }, "완료와 receive 순서에 무관하게 실제 MainActor hop을 유한 관측")
        late.finish()
    }
}
