import Foundation
import Network
import StreamProtocol

// Authentication is supplied by the existing TLS helper in the app. This fixture only controls
// that helper's result; the real adapter below never creates a connection or sends a message.
final class StreamClient {
    struct Session { var macID: String? }
    var connection: NWConnection?
    var session: Session?
    var authenticatedVisionMacAudioPeer: ObjectIdentifier?
    // PRODUCTION_TEST_DESTINATION_STORAGE

    init(now: Date) { visionTestDestinations = VisionTestDestinations(clock: { now }) }
}

func runAdapterChecks(catalog: TestDestinationCatalog, now: Date) {
    let client = StreamClient(now: now)
    let first = NWConnection()
    let second = NWConnection()
    let list = WindowList(macName: "fixture-Mac", windows: [], active: .desktop,
                          testDestinations: TestDestinationCatalog.Projection(catalog))
    client.connection = first
    client.session = StreamClient.Session(macID: "fixture-peer")
    client.bindVisionTestDestinations(to: first)
    client.observeVisionTestDestinations(list, from: first)
    check(client.visionTestDestinations.binding == nil && client.visionTestDestinations.entries.isEmpty,
          "actual adapter rejects catalog before current peer authentication")
    client.authenticatedVisionMacAudioPeer = ObjectIdentifier(first)
    client.observeVisionTestDestinations(list, from: first)
    let initialBinding = client.visionTestDestinations.binding!
    check(initialBinding.peerID == "fixture-peer" && client.visionTestDestinations.entries == catalog.entries,
          "actual adapter uses authenticated current peer identity")
    check(client.visionTestDestinations.open(catalog.entries[0], from: initialBinding),
          "actual adapter permits current authenticated catalog selection")
    let initialSelection = client.visionTestDestinations.selection!
    let initialEpoch = client.visionTestDestinations.storageEpoch
    client.observeVisionTestDestinations(list, from: second)
    check(client.visionTestDestinations.selection == initialSelection,
          "foreign connection catalog cannot replace current view")

    let malformed = Data("{\"macName\":\"fixture-Mac\",\"windows\":[],\"active\":{\"desktop\":{}},\"testDestinations\":42}".utf8)
    let malformedList = try! JSONDecoder().decode(WindowList.self, from: malformed)
    client.observeVisionTestDestinations(malformedList, from: first)
    check(malformedList.active == .desktop && client.visionTestDestinations.catalog == nil &&
          client.visionTestDestinations.selection == nil && client.visionTestDestinations.storageEpoch != initialEpoch,
          "malformed optional WindowList carrier preserves stream and clears prior viewer authority")
    client.observeVisionTestDestinations(list, from: first)
    client.visionTestDestinations.open(catalog.entries[0], from: initialBinding)
    client.authenticatedVisionMacAudioPeer = nil
    client.reconcileVisionTestDestinationAuthentication()
    check(client.visionTestDestinations.binding == nil && client.visionTestDestinations.selection == nil,
          "authentication revocation immediately clears catalog and selection")
    client.authenticatedVisionMacAudioPeer = ObjectIdentifier(first)
    client.observeVisionTestDestinations(list, from: first)
    client.session?.macID = "other-peer"
    client.reconcileVisionTestDestinationAuthentication()
    check(client.visionTestDestinations.binding == nil, "authenticated session identity change revokes old project catalog")

    client.session?.macID = "fixture-peer"
    client.observeVisionTestDestinations(list, from: first)
    let beforeMove = client.visionTestDestinations.storageEpoch
    client.connection = second
    client.bindVisionTestDestinations(to: second)
    check(client.visionTestDestinations.binding == nil && client.visionTestDestinations.entries.isEmpty &&
          client.visionTestDestinations.storageEpoch != beforeMove,
          "peer handover clears catalog selection and project store scope before next catalog")
    client.authenticatedVisionMacAudioPeer = ObjectIdentifier(second)
    client.observeVisionTestDestinations(list, from: second)
    let movedBinding = client.visionTestDestinations.binding!
    check(movedBinding.peerID == initialBinding.peerID && movedBinding.generation != initialBinding.generation,
          "same Mac on new connection receives fresh generation")
    check(!client.visionTestDestinations.open(catalog.entries[0], from: initialBinding),
          "old generation cannot reopen after same Mac handover")
    client.visionTestDestinations.open(catalog.entries[0], from: movedBinding)
    client.invalidateVisionTestDestinations(from: first)
    drainCatalogCallbacks()
    check(client.visionTestDestinations.selection != nil, "old peer decode failure cannot clear new peer catalog")
    client.invalidateVisionTestDestinations(from: second)
    drainCatalogCallbacks()
    check(client.visionTestDestinations.catalogStatus == .invalid && client.visionTestDestinations.catalog == nil &&
          client.visionTestDestinations.selection == nil, "current peer decode failure clears viewer authority")
    client.observeVisionTestDestinations(list, from: second)
    client.connection = nil
    client.bindVisionTestDestinations(to: nil)
    check(client.visionTestDestinations.catalogStatus == .disconnected && client.visionTestDestinations.binding == nil,
          "disconnect clears current authenticated peer binding")
    client.observeVisionTestDestinations(list, from: second)
    check(client.visionTestDestinations.entries.isEmpty, "queued former peer catalog cannot restore disconnected viewer")
    check(first.sent.isEmpty && second.sent.isEmpty, "catalog adapter emits no stream input or protocol writes")
}

private func drainCatalogCallbacks() {
    var drained = false
    DispatchQueue.main.async { drained = true }
    let deadline = Date().addingTimeInterval(1)
    while !drained && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    check(drained, "queued catalog invalidation completes within bounded fixture run loop")
}
