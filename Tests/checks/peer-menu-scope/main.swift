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
        print("PASS \(checks) production menu scope checks; inert AX reader, no listener, focus, or OS input")
    }
}
