import Foundation
import Darwin

@main
struct ClosureCheck {
    @MainActor
    static func main() {
        do { try verify() }
        catch {
            FileHandle.standardError.write(Data("검증 거절: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func verify() throws {
        if CommandLine.arguments.last == "factory-rejection" {
            do {
                _ = try LocalAudioRelayLaunch.makeForwardingRelay(participants: LocalAudioParticipantRegistry())
                preconditionFailure("test executable passed canonical app validation")
            } catch {
                print("PASS canonical app factory refuses test executable")
                return
            }
        }
        let inventory = try LocalAudioRelayInventory.capture(package: URL(fileURLWithPath: CommandLine.arguments[1]))
        try LocalAudioRelayLaunch.requireLaunchSupport(inventory)
        let invocation = LocalAudioRelayInvocation(inventory: inventory)
        precondition(invocation.arguments.last == "--native-audio-forwarding-stdio")
        precondition(invocation.environment == ["CCR_MOBILE_PORT": "17648"])
        print("PASS actual sealed runtime inventory and Mach-O closure")
    }
}
