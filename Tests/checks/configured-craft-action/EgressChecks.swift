import Foundation
import StreamProtocol

private func craftPlanObject(operation: UUID, session: UUID, expires: Int64, modifiers: Int = 4) -> [String: Any] {
    ["operationId":operation.uuidString.lowercased(), "deviceId":Checks.device,
     "deviceSessionId":session.uuidString.lowercased(), "bindingSha256":Checks.hash,
     "bundleIdentifier":"com.openai.codex", "keyCode":9, "modifiers":modifiers, "expiresAt":expires]
}

@MainActor final class EgressFixture {
    var tick: Int64 = 1793910000010
    var elapsed: TimeInterval = 100
    var target: HostConfiguredCraftTarget? = .init(pid: 55, startSeconds: 99, startMicroseconds: 1)
    var front = true, current = true, delayed = false, upWorks = true, prepareWorks = true
    var downs = 0, ups = 0, focuses = 0
    var strokes: [KeyStroke] = []
    var onWait: (() -> Void)?, onDown: (() -> Void)?
    lazy var egress = HostConfiguredCraftEgress(resolve: { self.target }, foreground: { self.front && self.target == $0 },
        focus: { _ in self.focuses += 1; self.front = !self.delayed; return true },
        prepare: { _, _ in
            guard self.prepareWorks else { return nil }
            return { stroke in
                self.strokes.append(stroke)
                if stroke.down { self.downs += 1; self.onDown?(); return true }
                self.ups += 1; return self.upWorks
            }
        }, beforeFlags: { 0 }, now: { self.tick }, uptime: { self.elapsed }, wait: {
            self.tick += 10; self.elapsed += 0.01; self.front = true; self.onWait?()
        })
}

@MainActor func craftProtectedEgressChecks(_ check: @escaping (String, Bool) -> Void) async throws {
    var count = 0
    func expect(_ name: String, _ value: Bool) { count += 1; check("EGRESS " + name, value) }
    let operation = UUID(), session = UUID(), clock: Int64 = 1793910000010
    let object = craftPlanObject(operation: operation, session: session, expires: clock + 1000)
    func plan(_ value: [String: Any]) throws -> HostConfiguredCraftExecution {
        try ConfiguredCraftActionJSON.decode(HostConfiguredCraftExecution.self, from: JSONSerialization.data(withJSONObject: value))
    }
    let valid = try plan(object)
    for raw in 0...31 {
        let p = try plan(craftPlanObject(operation: UUID(), session: session, expires: clock + 1000, modifiers: raw))
        let command: UInt64 = raw & 1 != 0 ? 1 << 20 : 0
        let option: UInt64 = raw & 2 != 0 ? 1 << 19 : 0
        let control: UInt64 = raw & 4 != 0 ? 1 << 18 : 0
        let shift: UInt64 = raw & 8 != 0 ? 1 << 17 : 0
        let function: UInt64 = raw & 16 != 0 ? 1 << 23 : 0
        let expected = command | option | control | shift | function
        expect("explicit Craft modifier map \(raw)", p.flags == expected && p.keyCode == 9)
    }
    for (key, value) in [("keyCode", 128 as Any), ("keyCode", true as Any), ("modifiers", 32 as Any),
                         ("expiresAt", 1.5 as Any), ("bundleIdentifier", "other" as Any), ("unknown", 0 as Any)] {
        var changed = object; changed[key] = value
        do { _ = try plan(changed); expect("reject invalid \(key)", false) }
        catch { expect("reject invalid \(key)", true) }
    }
    let fixture = EgressFixture()
    var admissions = 0
    let posted = await fixture.egress.execute(valid, current: { fixture.current }, admission: { write in admissions += 1; try write() })
    expect("virtual key passes directly and up restores flags", posted && fixture.strokes == KeyStrokes.chord(virtualKey: 9, flags: 1 << 18, before: 0) && admissions == 1)
    let duplicate = await fixture.egress.execute(valid, current: { true }, admission: { try $0() })
    expect("same handed plan never posts twice", !duplicate && fixture.downs == 1)
    let unavailable = EgressFixture(); let originalTarget = unavailable.target; unavailable.target = nil
    _ = await unavailable.egress.execute(valid, current: { true }, admission: { try $0() })
    unavailable.target = originalTarget
    let replayUnavailable = await unavailable.egress.execute(valid, current: { true }, admission: { try $0() })
    expect("initially missing target cannot be retried with the same plan", !replayUnavailable && unavailable.downs == 0)
    for boundary in ["TLS", "pairing", "source_epoch", "window_epoch", "selection", "Sentry", "deadline", "target_identity"] {
        let f = EgressFixture(); f.front = false; f.delayed = true
        f.onWait = {
            if boundary == "deadline" { f.tick = valid.expiresAt }
            else if boundary == "target_identity" { f.target = .init(pid: 55, startSeconds: 100, startMicroseconds: 1) }
            else { f.current = false }
        }
        let ok = await f.egress.execute(valid, current: { f.current }, admission: { try $0() })
        expect("late focus invalidates \(boundary) before down", !ok && f.downs == 0 && f.focuses == 1)
    }
    let f = EgressFixture(); f.front = false; f.delayed = true
    let focused = await f.egress.execute(valid, current: { f.current }, admission: { try $0() })
    expect("one bounded focus of existing target", focused && f.focuses == 1 && f.downs == 1)
    let frozen = EgressFixture(); frozen.front = false; frozen.delayed = true
    frozen.onWait = { frozen.tick = clock; frozen.elapsed += 2 }
    let timedOut = await frozen.egress.execute(valid, current: { true }, admission: { try $0() })
    expect("focus timeout does not depend on wall clock progress", !timedOut && frozen.downs == 0)
    let denied = EgressFixture()
    let denyResult = await denied.egress.execute(valid, current: { true }, admission: { _ in throw ProviderCallFailure.superseded })
    expect("last write admission denies down", !denyResult && denied.downs == 0)
    let lateCancel = EgressFixture()
    var cancelledTask: Task<Bool, Never>?
    cancelledTask = Task { @MainActor in
        await lateCancel.egress.execute(valid, current: { true }, admission: { write in
            cancelledTask?.cancel(); try write()
        })
    }
    let lateCancelled = await cancelledTask!.value
    cancelledTask = nil
    expect("Task cancellation inside final admission prevents down", !lateCancelled && lateCancel.downs == 0)
    let cancelled = EgressFixture(); cancelled.onDown = { cancelled.current = false; cancelled.front = false }
    let cancelledResult = await cancelled.egress.execute(valid, current: { cancelled.current }, admission: { try $0() })
    expect("cancel after down cleans only its up", !cancelledResult && cancelled.downs == 1 && cancelled.ups == 1 && !cancelled.egress.hasDebt)
    let partial = EgressFixture(); partial.upWorks = false
    let partialResult = await partial.egress.execute(valid, current: { true }, admission: { try $0() })
    let before = partial.ups
    _ = partial.egress.release(owner: UUID())
    expect("failed up retains operation debt; other owner cannot clean it", !partialResult && partial.egress.hasDebt && partial.ups == before)
    let next = try plan(craftPlanObject(operation: UUID(), session: session, expires: clock + 1000))
    let blocked = await partial.egress.execute(next, current: { true }, admission: { try $0() })
    expect("unretired debt blocks another operation", !blocked && partial.downs == 1)
    partial.upWorks = true; _ = partial.egress.release(owner: operation)
    expect("only original owner retries its up", !partial.egress.hasDebt && partial.downs == 1 && partial.ups == before + 1)

    for mode in ["plan", "missing_plan", "focus_cancel", "late_reply", "expired_plan"] {
        let device = AudioForwardingDeviceID(hex: Checks.device)!, generation = UUID()
        let off = try Checks.snapshot(input: false, output: false, phase: .off)
        let control = try ConfiguredCraftActionControl.decode(Checks.control())
        var current = true, sends = 0, executions = 0, queries = 0
        let transport = CraftFixtureTransport { data in
            let command = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let preparing = command["op"] as? String == "configuredCraftAction.prepareHost"
            if preparing {
                sends += 1
                expect("prepareHost keeps exact common6+client+sentry", command.count == 8 && command["sentryState"] as? String == "userSessionProtected")
            } else { queries += 1 }
            let result = try ConfiguredCraftActionResult(outcome: .invoked, operationId: control.client!.operationId,
                deviceId: device, bindingSha256: Checks.hash, invoked: true)
            var response: [String: Any] = ["op":"configuredCraftAction.reply", "schemaVersion":1,
                "requestId":command["requestId"]!, "outcome":"ok", "actionResult":try JSONSerialization.jsonObject(with: Wire.encode(result))]
            if preparing {
                response["hostExecution"] = mode == "missing_plan" ? NSNull() : craftPlanObject(operation: control.client!.operationId,
                    session: session, expires: mode == "expired_plan" ? clock : clock + 1000)
                if mode == "late_reply" { current = false }
            }
            return try JSONSerialization.data(withJSONObject: response)
        }
        let runtime = HostConfiguredCraftRuntime(open: { _ in transport }, now: { clock })
        var context = HostConfiguredCraftSession(deviceId: device, deviceSessionId: session, pairingGeneration: generation,
            sentryProtected: { true }, isCurrent: { current }, currentSelection: { off }, readSnapshot: { off }, withSendAdmission: { _, write in try write() })
        context.canPrepareHost = { true }; context.withPreparedHostAdmission = { try $0() }
        context.executeHost = { _, _ in executions += 1; return mode != "focus_cancel" }
        let response = await runtime.exchange(control, session: context)
        if mode == "late_reply" { expect("late response does not execute", response == nil && executions == 0) }
        else { expect("handoff truth survives \(mode)", response?.result?.invoked == true && response?.result?.effectConfirmed == false && response?.result?.outcome == (mode == "plan" ? .invoked : .unknown)) }
        current = true
        _ = await runtime.exchange(control, session: context)
        _ = await runtime.exchange(ConfiguredCraftActionControl(requestId: UUID(), operationId: control.client!.operationId), session: context)
        expect("duplicate/query cannot re-execute \(mode)", sends == 1 && executions == (mode == "plan" || mode == "focus_cancel" ? 1 : 0) && queries >= 1)
    }
    let peer = NSObject(), peerID = ObjectIdentifier(peer), device = AudioForwardingDeviceID(hex: Checks.device)!
    let admission = SentryAdmission()
    admission.configure(latched: true, persistenceHealthy: true); admission.register(peerID, externalRoute: false); admission.admit(peerID)
    _ = admission.grantControl(to: peerID, verifiedOwner: .init(deviceID: device.hex, encryptedTLS: true, currentPairedOwner: true)!)
    admission.update(verified: true, persistenceHealthy: true, reason: nil); admission.capture(UUID())
    let proof = admission.status(for: peerID)!
    var writes = 0
    expect("protected owner gate admits same state", admission.withPreparedHostCraftWrite(for: peerID, deviceID: device.hex, expected: proof) { writes += 1 } && writes == 1)
    expect("inactive-only gate remains closed while protected", !admission.withInactiveCraftWrite(for: peerID, expected: proof) { writes += 1 })
    expect("other owner rejected", !admission.withPreparedHostCraftWrite(for: peerID, deviceID: String(repeating: "c", count: 64), expected: proof) { writes += 1 })
    admission.setLocalReturnRequestActive(true)
    expect("local return and stale state rejected", !admission.withPreparedHostCraftWrite(for: peerID, deviceID: device.hex, expected: proof) { writes += 1 } && writes == 1)
    print("EGRESS_NEW_CHECKS \(count); fake target/sink/clock/transport only; actual effects=0")
}
