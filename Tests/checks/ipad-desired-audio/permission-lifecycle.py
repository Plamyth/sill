"""Build actual observer and chooser bodies with controlled permission and media boundaries."""
import ast
from pathlib import Path


def sources(root):
    here = root / 'Tests/checks/ipad-desired-audio'
    constants = {}
    for node in ast.parse((here / 'intent-adapters.py').read_text()).body:
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name) and node.targets[0].id == 'standins':
            constants['standins'] = ast.literal_eval(node.value)
    standins = constants['standins'].replace('final class IPadAudioResumeObserver { init(client: StreamClient) {} }\n', '')
    standins = standins.replace('var audioRouteAuthorization: UUID?', '''var audioRouteAuthorization: IPadAudioRoutePolicy.Authorization?
 var active = StreamSource.desktop
 var permissionWaiter: CheckedContinuation<Bool, Never>?
 var audioRouteAppActive: Bool { UIApplication.shared.applicationState == .active }
 var microphonePhase: IPadMicrophonePolicy.Phase { microphonePolicy.phase }
 @MainActor func requestAudioRouteMicrophonePermission() async -> Bool {
  await withCheckedContinuation { permissionWaiter = $0 }
 }''')
    standins += '''
extension Notification.Name {
 static let willResignActive = Notification.Name("fixture.resign")
 static let didEnterBackground = Notification.Name("fixture.background")
 static let didBecomeActive = Notification.Name("fixture.active")
}
extension UIApplication {
 static let willResignActiveNotification = Notification.Name.willResignActive
 static let didEnterBackgroundNotification = Notification.Name.didEnterBackground
 static let didBecomeActiveNotification = Notification.Name.didBecomeActive
}
final class IPadMicrophoneDiagnostics {
 static let shared = IPadMicrophoneDiagnostics()
 func attempt(_ id: UUID) -> Self { self }
 func record(_ name: String, _ fields: [String: String] = [:]) {}
}
'''
    desired = (root / 'iOSClient/StreamClient+DesiredAudio.swift').read_text()
    desired = desired[desired.index('extension StreamClient'):desired.rindex('#endif')]
    routes = (root / 'iOSClient/StreamClient+AudioRoutes.swift').read_text()
    def block(signature):
        start = routes.index(signature)
        end = routes.index('{', start) + 1
        depth = 1
        while depth:
            depth += (routes[end] == '{') - (routes[end] == '}')
            end += 1
        return routes[start:end]
    start = routes.index('@MainActor func applyAudioRoutes(')
    end = routes.index('@MainActor var audioRouteAppActive', start)
    properties = '\n'.join(block(signature) for signature in [
        'var audioRouteCapabilities:', 'var audioRouteContext:', 'var audioRouteSelection:'])
    adapter = standins + desired + '\nextension StreamClient {\n' + properties + '\n' + routes[start:end] + '\n}\n'
    return {'Adapter.swift': adapter, 'main.swift': MAIN}


MAIN = '''import Foundation
import StreamProtocol
@main struct Checks {
 @MainActor static func main() async {
  var checks = 0
  func check(_ value: Bool, _ label: String) {
   checks += 1
   if !value { print("FAIL " + label); exit(1) }
  }
  for event in ["allow-before-active", "allow", "allow-after-failed-auto", "off", "source", "background", "privacy",
                "off-after-result", "source-after-result", "background-after-result", "privacy-after-result",
                "peer-after-result", "cancel-after-result"] {
   UIApplication.shared.applicationState = .active
   let client = StreamClient(), peer = NWConnection(), generation = UUID()
   let epoch = VideoEpoch(generation: generation.uuidString, source: .desktop,
    geometry: .init(x: 0, y: 0, width: 800, height: 600), width: 800, height: 600)
   let list = WindowList(macName: "fixture", windows: [], active: .desktop, remoteAudio: 1,
    inputGeneration: generation.uuidString, videoEpoch: epoch,
    microphone: .init(peer: UUID(), destination: UUID(), generation: UUID()), audioPrivacy: .init(version: 2, protected: true))
   client.connection = peer
   client.desiredAudioSetConnection(peer)
   _ = client.microphonePolicy.setConnection(ObjectIdentifier(peer))
   _ = client.microphonePolicy.observe(list, from: ObjectIdentifier(peer))
   client.remoteAudioControl.setConnection(ObjectIdentifier(peer))
   client.remoteAudioControl.receive(list, from: ObjectIdentifier(peer))
   client.desiredAudioObserve(list, from: peer)
   client.reconcileDesiredAudio()
   if event == "allow-after-failed-auto" { client.audioAutomaticDirections.insert(.microphone) }
   let context = client.audioRouteContext
   let pending = Task { @MainActor in
    try await client.applyAudioRoutes(.init(input: .iPadMicrophone, output: .iPadPlayback), context: context)
   }
   for _ in 0..<1000 where client.permissionWaiter == nil { await Task.yield() }
   check(client.permissionWaiter != nil, "chooser reaches the real permission boundary")
   UIApplication.shared.applicationState = .inactive
   NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
   client.reconcileDesiredAudio()
   if event == "allow-before-active" || event.hasSuffix("-after-result") {
    client.permissionWaiter?.resume(returning: true); client.permissionWaiter = nil
    for _ in 0..<1000 where client.audioPendingMicrophonePermission == nil { await Task.yield() }
    check(client.audioPendingMicrophonePermission != nil, "OS result waits for foreground without opening media")
   }
   check(client.microphoneAttempts == 0 && client.subscriptions.filter(\\.enabled).isEmpty,
         "permission inactivity keeps both actual media paths closed")
   if event.hasPrefix("allow") {
    check(client.audioRouteAuthorization != nil, "manual chooser intent survives its OS permission alert")
   } else if event.hasPrefix("off") { client.cancelDesiredAudioRequest() }
   else if event.hasPrefix("source") { client.desiredAudio.sourceWillChange(); client.suspendDesiredAudio() }
   else if event.hasPrefix("peer") {
    client.connection = NWConnection(); client.desiredAudioSetConnection(client.connection)
   } else if event.hasPrefix("cancel") { pending.cancel() }
   else if event.hasPrefix("background") {
    client.appInForeground = false
    UIApplication.shared.applicationState = .background
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
   } else {
    var blocked = list; blocked.audioPrivacy = .init(version: 2, protected: false)
    client.desiredAudioObserve(blocked, from: peer)
   }
   UIApplication.shared.applicationState = .active
   client.appInForeground = true
   NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
   for _ in 0..<20 { await Task.yield() }
   client.permissionWaiter?.resume(returning: true); client.permissionWaiter = nil
   var succeeded = true
   do { try await pending.value } catch { succeeded = false }
   check(succeeded == event.hasPrefix("allow"), "only unchanged explicit chooser permission completes after active return")
   check(client.desiredAudio.selection.microphone == succeeded && client.desiredAudio.selection.playback == succeeded,
         "cancellation never stores the rejected ON choice")
   check(client.microphoneAttempts == (succeeded ? 1 : 0) && client.subscriptions.filter(\\.enabled).count == (succeeded ? 1 : 0),
         "only accepted permission requests media once")
   client.audioResumeObserver = nil
  }
  print("PASS \\(checks) actual chooser and notification lifecycle checks with controlled OS and media")
 }
}
'''
