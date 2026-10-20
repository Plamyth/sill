import Foundation

@main struct Checks {
    @MainActor static func main() async {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [CommandLine.arguments[1]]
        let relay = LocalAudioRelay(participants: LocalAudioParticipantRegistry(), process: child, validateLaunch: { true })
        let started = await relay.start()
        precondition(started)
        let first = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) }
        try? await Task.sleep(for: .milliseconds(50))
        let second = Task { await relay.checkedCall("next", until: .now.advanced(by: .seconds(2))) }
        let a = await first.value, b = await second.value
        print("overlap first=\(String(describing: a)) second=\(String(describing: b))")
        relay.lost()
        precondition(a == 1 && b == 1, "FIFO overlap must preserve both calls")
    }
}
