import Foundation
import Network
import StreamProtocol
@main struct MenuScopeChecks {
    @MainActor static func main() async {
        var checks = 0
        func check(_ ok: Bool, _ label: String) { precondition(ok, label); checks += 1 }
        let reader = MenuReader(), mirror = MenuMirror(server: StreamServer(), reader: reader)
        mirror.setTarget(.init(pid: 999999, app: "격리 앱", bundleID: "test.invalid", window: 10))
        var ready = false
        mirror.readScopeReady = { ready }
        let initial = mirror.version
        _ = await mirror.readTop(version: initial)
        check(reader.reads == 0, "wrong key window never reads AX menus")
        check(mirror.topMessage(answering: nil).menus?.isEmpty == true && mirror.topMessage(answering: nil).note != nil, "wrong key window displays an honest unavailable state")
        check(mirror.version > initial && mirror.needsRetry, "old menu ids expire and observational retry remains possible")
        ready = true
        _ = await mirror.readTop(version: mirror.version)
        check(reader.reads == 1 && mirror.topMessage(answering: nil).menus?.first?.title == "파일", "matching key window recovers without a focus operation")
        ready = false
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        mirror.subscribers[ObjectIdentifier(connection)] = connection
        await mirror.serveFetch(FetchMenu(version: mirror.version, id: "1", title: "파일", token: 1), id: "1", to: connection, arrived: CFAbsoluteTimeGetCurrent())
        check(reader.reads == 1, "submenu fetch cannot read another key window")
        check(mirror.topMessage(answering: nil).menus?.isEmpty == true && mirror.needsRetry, "cached rows are removed when input ownership changes")
        var failures = 0
        func boundary(_ ok: Bool, _ label: String) {
            if !ok { print("FAIL " + label); failures += 1 }
            else { print("PASS " + label); checks += 1 }
        }
        func pair() -> (MenuReader, MenuMirror, NWConnection, MenuBoundaryFixture) {
            let reader = MenuReader(), mirror = MenuMirror(server: StreamServer(), reader: reader)
            let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            mirror.setTarget(.init(pid: 999999, app: "격리 앱", bundleID: "test.invalid", window: 10))
            mirror.subscribers[ObjectIdentifier(connection)] = connection
            let fixture = MenuBoundaryFixture(); fixture.attach(mirror, connection: connection)
            return (reader, mirror, connection, fixture)
        }
        let (declinedReader, declined, declinedConnection, declinedFixture) = pair()
        declined.preparePress = { false }
        declined.press(.init(version: declined.version, id: "1.1", title: "격리 메뉴"),
                       from: declinedConnection, who: "격리 연결")
        await declinedFixture.peerInputQueue.drain()
        boundary(declinedReader.presses == 0,
                 "preparePress 거부 뒤 reader.press 호출: 기대 0, 실제 \(declinedReader.presses)")

        for scoped in [false, true] {
        let (queuedReader, queued, queuedConnection, queuedFixture) = pair()
        queued.effectAdmission = scoped ? SourcePublicationAdmission() : nil
        queued.preparePress = { true }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        queuedReader.queue.raw.async { entered.signal(); release.wait() }
        entered.wait()
        queued.press(.init(version: queued.version, id: "1.1", title: "격리 메뉴"),
                     from: queuedConnection, who: "격리 연결")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while queuedReader.queue.submissions == 0, ContinuousClock.now < deadline { await Task.yield() }
        boundary(queuedReader.queue.submissions == 1, "실제 메뉴 reader 큐에 제출된 요청 관측")
        queuedFixture.revoke()
        queuedFixture.resume()
        boundary(queuedFixture.server.sentryAdmission.allowsActions(ObjectIdentifier(queuedConnection)),
                 "현재 인가가 다시 true인 상태에서도 옛 메뉴 세대는 복원하지 않음")
        release.signal()
        await queuedFixture.peerInputQueue.drain()
        boundary(queuedReader.presses == 0,
                 "인증 철회·재개 뒤 옛 큐 요청의 reader.press 호출: 기대 0, 실제 \(queuedReader.presses)")
        let prior = queuedReader.presses
        queued.press(.init(version: queued.version, id: "1.1", title: "격리 메뉴"),
                     from: queuedConnection, who: "격리 연결")
        await queuedFixture.peerInputQueue.drain()
        boundary(queuedReader.presses == prior + 1, "재개 후 새 메뉴 세대 요청은 정상 실행")
        }
        if failures > 0 { exit(1) }
        print("PASS \(checks) production menu scope checks; inert AX reader, no listener, focus, or OS input")
    }
}
