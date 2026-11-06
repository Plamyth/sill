import Foundation
import StreamProtocol

private struct CohortCommand: Decodable {
    let op: String
    let requestId: UUID
    let deviceId: AudioForwardingDeviceID
    let deviceSessionId: UUID
    let acceptedAt: Int64
    let client: ConfiguredCraftActionRequest?
    let operationId: UUID?
}

@MainActor func craftProducerCohortChecks(path: String) async throws {
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    precondition(bytes.count <= 1_048_576)
    let fixture = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    let bridge = fixture["schema"] as? String == "ccr.configured-craft-core-bridge-fixture/v1"
    precondition(bridge || fixture["schema"] as? String == "ccr.configured-craft-host-cohort-fixture/v1")
    let clock = (fixture[bridge ? "now" : "clockMs"] as! NSNumber).int64Value
    var exchanges: [[String: Any]]
    var suppliedControls: [ConfiguredCraftActionControl] = []
    if bridge {
        precondition(fixture["actualCraftProducerPayload"] as? Bool == true && fixture["actualCoreAdapterValidation"] as? Bool == true)
        let requests = fixture["coreRequests"] as! [[String: Any]], controls = fixture["controls"] as! [[String: Any]]
        precondition(requests.count == 3 && controls.count == 3)
        suppliedControls = try controls.map { try ConfiguredCraftActionControl.decode(JSONSerialization.data(withJSONObject: $0)) }
        exchanges = try zip(["first", "duplicate", "query"], requests).map { name, request in
            ["name":name, "requestUTF8":String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self),
             "replyUTF8":fixture[name + "ResponseJSON"] as! String]
        }
    } else { exchanges = fixture["exchanges"] as! [[String: Any]] }
    precondition(exchanges.count == 3)
    var commands: [CohortCommand] = [], responses: [Data] = [], requestObjects: [NSDictionary] = []
    for (index, name) in ["first", "duplicate", "query"].enumerated() {
        let row = exchanges[index]
        precondition(row["name"] as? String == name)
        let request = Data((row["requestUTF8"] as! String).utf8)
        let response = Data((row["replyUTF8"] as! String).utf8)
        let command = try ConfiguredCraftActionJSON.decode(CohortCommand.self, from: request)
        let decoded = try HostConfiguredCraftReply.decode(response, preparingHost: index != 2)
        precondition(decoded.requestId == command.requestId)
        if index == 0 { precondition(decoded.hostExecution != nil) }
        else { precondition(decoded.hostExecution == nil) }
        commands.append(command); responses.append(response)
        requestObjects.append(try JSONSerialization.jsonObject(with: request) as! NSDictionary)
    }
    let first = commands[0], query = commands[2]
    precondition(first.op == "configuredCraftAction.prepareHost" && commands[1].op == first.op)
    precondition(query.op == "configuredCraftAction.query" && commands[1].client == first.client)
    precondition(commands.allSatisfy { $0.deviceId == first.deviceId && $0.deviceSessionId == first.deviceSessionId })
    let client = first.client!
    if bridge {
        precondition(zip(suppliedControls, commands).allSatisfy { $0.requestId == $1.requestId })
        precondition(suppliedControls[0].client == client && suppliedControls[1].client == client &&
                     suppliedControls[2].operationId == client.operationId)
    }
    precondition(query.operationId == client.operationId)
    let off = try Checks.snapshot(input: false, output: false, phase: .off, deviceId: first.deviceId)
    let egress = EgressFixture(); egress.tick = clock
    var sends = 0, hostClock = first.acceptedAt
    let transport = CraftFixtureTransport { data in
        let index = sends == 0 ? 0 : 2
        let outgoing = try JSONSerialization.jsonObject(with: data) as! NSDictionary
        precondition(outgoing == requestObjects[index])
        sends += 1
        if index == 0 { hostClock = clock }
        return responses[index]
    }
    let runtime = HostConfiguredCraftRuntime(open: { _ in transport }, now: { hostClock })
    var session = HostConfiguredCraftSession(deviceId: first.deviceId, deviceSessionId: first.deviceSessionId,
        pairingGeneration: UUID(), sentryProtected: { true }, isCurrent: { true }, currentSelection: { off },
        readSnapshot: { off }, withSendAdmission: { _, write in try write() })
    session.canPrepareHost = { true }; session.withPreparedHostAdmission = { try $0() }
    session.executeHost = { plan, _ in await egress.egress.execute(plan, current: { true }, admission: { try $0() }) }
    let invoked = await runtime.exchange(bridge ? suppliedControls[0] : .init(requestId: first.requestId, client: client), session: session)
    precondition(invoked?.result?.invoked == true && invoked?.result?.effectConfirmed == false)
    precondition(egress.downs == 1 && egress.ups == 1 && sends == 1)
    _ = await runtime.exchange(bridge ? suppliedControls[1] : .init(requestId: commands[1].requestId, client: client), session: session)
    precondition(egress.downs == 1 && sends == 1)
    hostClock = query.acceptedAt
    let queried = await runtime.exchange(bridge ? suppliedControls[2] : .init(requestId: query.requestId, operationId: client.operationId), session: session)
    precondition(queried?.result?.operationId == client.operationId && egress.downs == 1 && sends == 2)
    print("COHORT_PRODUCER_CORE_HOST_PASS rawReplies=3 prepare=1 duplicateReplayPosts=0 queryPosts=0 fakeDowns=1 fakeUps=1 actualEffects=0")
}
