import Foundation

@main
struct ClosureCheck {
    static func main() throws {
        let inventory = try LocalAudioRelayInventory.capture(package: URL(fileURLWithPath: CommandLine.arguments[1]))
        try LocalAudioRelayLaunch.requireLaunchSupport(inventory)
        let invocation = LocalAudioRelayInvocation(inventory: inventory)
        precondition(invocation.arguments.last == "--native-audio-forwarding-stdio")
        precondition(invocation.environment == ["CCR_MOBILE_PORT": "17648"])
        print("PASS actual sealed runtime inventory and Mach-O closure")
    }
}
