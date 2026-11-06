import Foundation
import StreamProtocol

struct CraftFixtureMicrophone { let canStop = false }
struct CraftFixturePhase { let grant: UUID? = nil }
struct CraftFixturePresentation { let phase = CraftFixturePhase() }
struct CraftFixtureLifecycle {
    func refresh() {}
    func cancel() {}
}
extension InertPlayback { var presentation: CraftFixturePresentation { .init() } }
extension StreamClient {
    var microphonePhase: CraftFixtureMicrophone { .init() }
    var visionConfiguredCraftAction: CraftFixtureLifecycle { .init() }
    var visionConfiguredCraftContext: VisionConfiguredCraftAction.Context {
        let intent = store.model.intent
        var value = VisionConfiguredCraftAction.Context(hostKey: context.hostKey, scope: context.scope,
            binding: fixtureBinding, routeGeneration: fixtureRoute, capabilityPresent: true,
            routeImplemented: true, admitted: visionAudioIntentContext.admitted)
        value.selection = context.hostKey.flatMap { intent.desires[$0] }
        value.selectionRevision = max(intent.desiredRevision(.playback, hostKey: context.hostKey!),
                                      intent.desiredRevision(.microphone, hostKey: context.hostKey!))
        return value
    }
}
