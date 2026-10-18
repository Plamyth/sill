import Foundation

@main struct Checks {
    @MainActor static func main() throws {
        var checks = 0
        var failures = 0
        func expect(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("FAIL \(label)") }
        }
        let list = try JSONDecoder().decode(WindowList.self, from:Data("""
        {"macName":"fixture","windows":[{"id":1001,"title":"old","appName":"fixture","bundleID":"test","width":600,"height":400}],"active":{"none":{}}}
        """.utf8))
        for choice in ["window","display","launch","none"] {
            let client = Client()
            client.resumeSource = .window(1001)
            switch choice {
            case "window": client.select(.window(1002))
            case "display": client.selectDisplay(client.displays[0])
            case "launch": client.launch(bundleID:"test.new")
            default: client.select(.none)
            }
            client.deliverIdleCatalog(list)
            let picks = client.sent.filter { $0.0 == .selectSource }.compactMap { Wire.decode(StreamSource.self,from:$0.1) }
            expect(!picks.contains(.window(1001)), "delayed handover catalog cannot restore old window after explicit \(choice)")
        }
        let reconnect = Client()
        reconnect.resumeSource = .window(1001)
        reconnect.deliverIdleCatalog(list)
        expect(reconnect.sent.contains { $0.0 == .selectSource && Wire.decode(StreamSource.self,from:$0.1) == .window(1001) },
               "idle handover with no newer explicit choice still restores its window")
        let missing = Client()
        missing.resumeSource = .window(999)
        missing.deliverIdleCatalog(list)
        expect(missing.sent.contains { $0.0 == .selectSource && Wire.decode(StreamSource.self,from:$0.1) == .desktop },
               "missing restored window retains Desktop fallback")
        print("SOURCE_REQUEST_CLIENT_CHECKS total=\(checks) failed=\(failures)")
        if failures > 0 { exit(1) }
    }
}
