import AVFoundation
import Foundation
import StreamProtocol

var checks = 0
var failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !value() { failures += 1; print("FAIL \(name)") }
}
func rejects(_ operation: () throws -> Void) -> Bool {
    do { try operation(); return false } catch { return true }
}
struct SyntheticError: LocalizedError { var errorDescription: String? { "injected OS failure" } }
final class FakeGraph: VisionAudioGraphDriving {
    var recordPermissionGranted = true
    var profiles: [VisionAudioProfile] = []
    var outputs: [VisionAudioPlaybackGraph?] = []
    var inputs: [VisionAudioCaptureGraph?] = []
    var stops = 0
    var deactivations = 0
    var failConfigure = false
    var failStart = false
    var failStop = false
    var failDeactivate = false
    var duringStart: (() -> Void)?
    func configure(_ profile: VisionAudioProfile) throws {
        profiles.append(profile)
        if failConfigure { throw SyntheticError() }
    }
    func start(playback: VisionAudioPlaybackGraph?, capture: VisionAudioCaptureGraph?) throws {
        outputs.append(playback)
        inputs.append(capture)
        capture?.formatChanged(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        let callback = duringStart
        duringStart = nil
        callback?()
        if failStart { throw SyntheticError() }
    }
    func stop() throws { stops += 1; if failStop { throw SyntheticError() } }
    func deactivate() throws { deactivations += 1; if failDeactivate { throw SyntheticError() } }
}
enum VisionAudioSharedHardware {
    static let graph = FakeGraph()
    static let shared = VisionAudioHardware(driver: graph)
}
let format = VisionAudioFormat(rate: 48_000, channels: 1)!
func render(_ graph: VisionAudioPlaybackGraph?) -> Float {
    guard let graph else { return -2 }
    let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!, frameCapacity: 1)!
    buffer.frameLength = 1
    buffer.floatChannelData![0][0] = 9
    var flag = ObjCBool(false)
    var time = AudioTimeStamp()
    _ = graph.render(&flag, &time, 1, buffer.mutableAudioBufferList)
    return buffer.floatChannelData![0][0]
}
let tone: AVAudioSourceNodeRenderBlock = { _, _, _, list in
    UnsafeMutableAudioBufferListPointer(list)[0].mData!.assumingMemoryBound(to: Float.self)[0] = 0.5
    return noErr
}
func input(_ graph: VisionAudioCaptureGraph?, frames: AVAudioFrameCount = 960) {
    let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!, frameCapacity: max(1, frames))!
    buffer.frameLength = frames
    graph?.copyInput(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
}
func start(_ hw: VisionAudioHardware, _ claim: VisionAudioClaim, version: UInt64 = 1, authorization: @escaping () -> VisionAudioPlaybackAuthorization = { .current }) throws {
    try hw.startPlayback(claim, format: format, version: version, authorization: authorization, render: tone)
}
func reserve(_ hw: VisionAudioHardware, owner: UUID) -> VisionAudioClaim {
    hw.reserve(owner: owner, role: .playback, epoch: UUID())!
}
func runHardwareChecks() throws {
    let driver = FakeGraph(), owner = UUID(), foreign = UUID()
    let hw = VisionAudioHardware(driver: driver)
    let speaker = reserve(hw, owner: owner)
    check(driver.profiles.isEmpty && driver.outputs.isEmpty, "reservation never touches audio hardware")
    check(hw.reserve(owner: foreign, role: .capture, epoch: UUID()) == nil, "foreign client cannot share process session")
    check(hw.reserve(owner: owner, role: .playback, epoch: UUID()) == nil, "second playback activation refused")
    driver.duringStart = { check(render(driver.outputs.last!) == 0, "render silent before graph commit") }
    try start(hw, speaker)
    let oldOutput = driver.outputs.last!
    check(driver.profiles == [.playback] && hw.matches(speaker, version: 1), "speaker commits playback-only profile")
    check(render(oldOutput) == 0.5, "committed playback renders")
    var copied = 0, formats = 0, stopped = 0
    driver.duringStart = {
        check(render(oldOutput) == 0, "old graph closed during duplex rebuild")
        input(driver.inputs.last!)
        check(copied == 0, "capture closed before graph commit")
    }
    let mic = try hw.beginCapture(owner: owner, epoch: UUID(), permitted: { true },
        formatChanged: { _ in formats += 1 }, copyInput: { _, _ in copied += 1 }, stopped: { _ in stopped += 1 })
    check(driver.profiles == [.playback, .microphone] && hw.matches(speaker, version: 1), "duplex preserves speaker identity")
    check(driver.outputs.last! != nil && driver.inputs.last! != nil, "duplex builds input and render on one driver")
    let duplexOutput = driver.outputs.last!, duplexInput = driver.inputs.last!
    input(duplexInput)
    input(duplexInput, frames: 4_800)
    check(copied == 2 && formats == 1, "tap hint may yield larger bounded buffers")
    input(duplexInput, frames: 0)
    input(duplexInput, frames: 16_385)
    check(copied == 2, "empty and oversized borrowed buffers rejected")
    check(render(oldOutput) == 0 && render(duplexOutput) == 0.5, "previous graph stays silent after new commit")
    hw.revoke(mic)
    input(duplexInput)
    check(copied == 2, "stop revokes input before hardware cleanup")
    check(hw.close(mic) == nil && hw.matches(speaker, version: 1), "microphone close retains authorized playback")
    check(driver.profiles.last == .playback && driver.inputs.last! == nil && driver.deactivations == 0,
          "last microphone role rebuilds speaker without deactivating shared session")
    let speakerOnly = driver.outputs.last!
    check(render(duplexOutput) == 0 && render(speakerOnly) == 0.5, "duplex callback cannot enter successor graph")
    check(hw.close(speaker) == nil && driver.deactivations == 1, "last role deactivates before releasing lease")
    let successor = reserve(hw, owner: foreign)
    try start(hw, successor)
    check(hw.close(speaker) == nil && hw.matches(successor, version: 1), "stale close cannot release successor owner")
    check(render(speakerOnly) == 0, "retired speaker callback stays silent")
    _ = hw.close(successor)
    check(stopped == 0, "normal role stop does not report a failure")

    let d2 = FakeGraph(), h2 = VisionAudioHardware(driver: FakeGraph())
    check(rejects { _ = try h2.beginCapture(owner: owner, epoch: UUID(), permitted: { false }, formatChanged: { _ in }, copyInput: { _, _ in }, stopped: { _ in }) }, "missing grant cannot create capture role")
    let h3 = VisionAudioHardware(driver: d2)
    d2.recordPermissionGranted = false
    check(rejects { _ = try h3.beginCapture(owner: owner, epoch: UUID(), permitted: { true }, formatChanged: { _ in }, copyInput: { _, _ in }, stopped: { _ in }) }, "denied OS permission cannot create capture role")
    check(d2.profiles.isEmpty && d2.inputs.isEmpty && d2.stops == 0 && h3.cleanupProblem == nil, "permission refusal cannot configure or start hardware")
    d2.recordPermissionGranted = true
    var captureOnlyCopies = 0
    let onlyMic = try h3.beginCapture(owner: owner, epoch: UUID(), permitted: { true }, formatChanged: { _ in }, copyInput: { _, _ in captureOnlyCopies += 1 }, stopped: { _ in })
    check(d2.outputs.last! == nil && d2.inputs.last! != nil && d2.profiles.last == .microphone, "capture-only uses same owner without speaker requirement")
    let captureOnlyInput = d2.inputs.last!
    let addedSpeaker = reserve(h3, owner: owner)
    try start(h3, addedSpeaker)
    _ = h3.close(addedSpeaker)
    input(captureOnlyInput)
    input(d2.inputs.last!)
    check(captureOnlyCopies == 1 && d2.outputs.last! == nil, "speaker removal preserves capture and fences previous tap")
    _ = h3.close(onlyMic)
}
func runFailureChecks() throws {
    for failure in ["configure", "start", "stop", "deactivate"] {
        let d = FakeGraph(), owner = UUID()
        let hw = VisionAudioHardware(driver: d)
        let claim = reserve(hw, owner: owner)
        if failure == "configure" { d.failConfigure = true }
        if failure == "start" { d.failStart = true }
        if failure == "stop" { d.failStop = true }
        if failure == "deactivate" {
            try start(hw, claim)
            d.failDeactivate = true
            check(hw.close(claim) != nil, "deactivation failure reported")
        } else {
            check(rejects { try start(hw, claim) }, "\(failure) failure surfaced")
        }
        check(hw.cleanupProblem != nil && !hw.matches(claim, version: 1), "\(failure) uncertainty closes committed gate")
        check(hw.reserve(owner: UUID(), role: .playback, epoch: UUID()) == nil, "\(failure) uncertainty retains process ownership")
        check(hw.reserve(owner: owner, role: .capture, epoch: UUID()) == nil, "\(failure) quarantine refuses same-owner capture reservation")
        let before = d.profiles.count
        _ = hw.close(claim)
        check(d.profiles.count == before && hw.cleanupProblem != nil, "\(failure) close cannot silently restart or release quarantine")
        if failure == "deactivate" {
            hw.retryCleanup()
            check(hw.cleanupProblem != nil, "failed explicit cleanup retains quarantine")
        }
        d.failConfigure = false; d.failStart = false; d.failStop = false; d.failDeactivate = false
        hw.retryCleanup()
        check(hw.cleanupProblem == nil && d.profiles.count == before, "\(failure) explicit cleanup does not restart graph")
        let next = hw.reserve(owner: UUID(), role: .playback, epoch: UUID())
        check(next != nil, "\(failure) successful cleanup releases old process ownership")
        if let next { _ = hw.close(next) }
    }
    let d = FakeGraph()
    let h = VisionAudioHardware(driver: d), owner = UUID()
    var copies = 0, stopped = 0
    d.duringStart = { d.recordPermissionGranted = false }
    check(rejects { _ = try h.beginCapture(owner: owner, epoch: UUID(), permitted: { true }, formatChanged: { _ in }, copyInput: { _, _ in copies += 1 }, stopped: { _ in stopped += 1 }) }, "permission revoked during start prevents commit")
    input(d.inputs.last!)
    check(copies == 0 && stopped == 1 && h.cleanupProblem != nil, "failed capture closes late tap and reports once")
    h.retryCleanup()
    d.recordPermissionGranted = true
    let claim = reserve(h, owner: owner)
    d.duringStart = { h.revoke(claim) }
    check(rejects { try start(h, claim) }, "revocation during start prevents commit")
    check(render(d.outputs.last!) == 0 && !h.matches(claim, version: 1), "revoked in-flight output remains silent")
    h.retryCleanup()
    let claim2 = reserve(h, owner: owner)
    d.duringStart = { _ = h.close(claim2) }
    check(rejects { try start(h, claim2) }, "reentrant close cancels transition without nested native operations")
    check(h.cleanupProblem != nil, "reentrant transition retains cleanup identity")
    h.retryCleanup()
    let claim3 = reserve(h, owner: owner)
    try start(h, claim3)
    let old = d.outputs.last!
    h.invalidate("synthetic route change")
    check(render(old) == 0 && h.cleanupProblem != nil, "external interruption closes graph without auto restart")
    let before = d.profiles.count
    h.retryCleanup()
    check(d.profiles.count == before && h.cleanupProblem == nil, "route recovery is cleanup-only")
}
func runReviewRegressions() throws {
    let d = FakeGraph()
    let h = VisionAudioHardware(driver: d), owner = UUID()
    let claim = reserve(h, owner: owner)
    var current = true
    d.duringStart = { current = false }
    check(rejects { try start(h, claim, authorization: { current ? .current : .superseded }) },
          "superseded graph asks caller for newer reconciliation")
    check(h.cleanupProblem == nil && !h.matches(claim, version: 1), "normal format replacement does not quarantine lease")
    if h.cleanupProblem == nil {
        try start(h, claim, version: 2)
        check(h.matches(claim, version: 2), "newer format can commit on same grant and claim")
        _ = h.close(claim)
    } else { h.retryCleanup() }

    let d2 = FakeGraph()
    let h3 = VisionAudioHardware(driver: d2)
    var startedInCallback = false
    _ = try h3.beginCapture(owner: owner, epoch: UUID(), permitted: { true }, formatChanged: { _ in }, copyInput: { _, _ in }, stopped: { _ in
        h3.retryCleanup()
        if let next = h3.reserve(owner: owner, role: .playback, epoch: UUID()) {
            startedInCallback = true
            try? start(h3, next)
        }
    })
    h3.invalidate("synthetic invalidation")
    check(!startedInCallback && h3.cleanupProblem != nil, "invalidation callback cannot replace a resource before old stop finishes")
    h3.invalidate("end review probe")
    h3.retryCleanup()
}
func drain(_ until: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}
func runPlayerChecks() throws {
    let d = FakeGraph()
    let hw = VisionAudioHardware(driver: d), owner = UUID(), grant = UUID()
    let decode = DispatchQueue(label: "checks.real-player-decode")
    let player = VisionAudioPlayer(hardware: hw, ownerID: owner, decodeQueue: decode)
    var events: [VisionAudioPlaybackEvent] = []
    player.begin(grant: grant) { _, event in events.append(event) }
    let samples = [Int16](repeating: 16_384, count: 4_800)
    let packet = samples.withUnsafeBufferPointer { AudioPacket.pack(sampleRate: 48_000, channels: 1, samples: $0) }
    let replacement = samples.withUnsafeBufferPointer { AudioPacket.pack(sampleRate: 44_100, channels: 1, samples: $0) }
    d.duringStart = {
        player.receive(replacement, grant: grant)
        decode.sync {}
    }
    player.receive(packet, grant: grant)
    drain { d.outputs.count >= 2 }
    check(d.outputs.count >= 2 && d.outputs.last!?.format.rate == 44_100 && player.cleanupProblem == nil,
          "real player newer PCM survives old graph supersession without cleanup UI")
    check(!d.outputs.isEmpty && d.profiles.allSatisfy { $0 == .playback }, "real player decodes and starts injected shared graph")
    guard !d.outputs.isEmpty else { return }
    if let graph = d.outputs.last! {
        check(render(graph) > 0, "real player render uses admitted PCM")
        let mic = try hw.beginCapture(owner: owner, epoch: UUID(), permitted: { true }, formatChanged: { _ in }, copyInput: { _, _ in }, stopped: { _ in })
        check(d.profiles.last == .microphone && d.outputs.last! != nil, "real player shares its session with capture seam")
        let duplexOutput = d.outputs.last!
        player.stop()
        check(render(duplexOutput) == 0, "real player stop immediately zeros retained render callback")
        drain { d.outputs.last! == nil }
        check(d.outputs.last! == nil && d.inputs.last! != nil, "real player cleanup retains capture role")
        _ = hw.close(mic)
    }
    d.failDeactivate = true
    let next = UUID()
    player.begin(grant: next) { _, event in events.append(event) }
    player.receive(packet, grant: next)
    let starts = d.outputs.count
    drain { d.outputs.count > starts }
    player.stop()
    drain { player.cleanupProblem != nil }
    check(player.cleanupProblem != nil, "real player exposes cleanup failure after stop")
    d.failDeactivate = false
    player.retryCleanup()
    check(player.cleanupProblem == nil, "real player explicit cleanup recovers shared owner")
    let delayedGrant = UUID(), beforeDelayed = d.outputs.count
    player.begin(grant: delayedGrant) { _, event in events.append(event) }
    player.receive(packet, grant: delayedGrant, arrived: ProcessInfo.processInfo.systemUptime - 0.200)
    decode.sync {}
    drain { player.cleanupProblem != nil || d.outputs.count > beforeDelayed }
    check(d.outputs.count == beforeDelayed && player.cleanupProblem == nil,
          "real player retains network arrival time and drops already stale ingress before graph start")
    player.stop()
}
final class BarrierPlayback {
    var stopAction: () -> Void = {}
    func stop() { stopAction() }
}
final class BarrierFrames {
    var open = true
    func close() { open = false }
}
struct BarrierEpoch { let id: UUID }
struct BarrierBinding { let epoch: BarrierEpoch? }
final class StreamClient {
    let visionAudioOwnerID = UUID()
    let visionAudio = BarrierPlayback()
    let microphoneFrames = BarrierFrames()
    let visionWireSource = StreamSource.desktop
    var visionWireBinding: (binding: BarrierBinding, unused: Bool)?
}
func runCatalogBarrierChecks() throws {
    let hw = VisionAudioSharedHardware.shared, graph = VisionAudioSharedHardware.graph
    let invalid: [AudioPrivacyState?] = [nil, .init(version: 1, protected: true),
        .init(version: 3, protected: true), .init(version: 2, protected: false)]
    for privacy in invalid {
        let client = StreamClient()
        let epoch = VideoEpoch(generation: UUID().uuidString, source: .desktop,
            geometry: .init(x: 0, y: 0, width: 100, height: 100), width: 100, height: 100)
        client.visionWireBinding = (BarrierBinding(epoch: BarrierEpoch(id: epoch.id)), false)
        let speaker = reserve(hw, owner: client.visionAudioOwnerID)
        try start(hw, speaker)
        var copies = 0
        let microphone = try hw.beginCapture(owner: client.visionAudioOwnerID, epoch: UUID(),
            permitted: { true }, formatChanged: { _ in }, copyInput: { _, _ in copies += 1 }, stopped: { _ in })
        let output = graph.outputs.last!, capture = graph.inputs.last!
        check(render(output) > 0, "playback claim committed before metadata downgrade")
        input(capture)
        let before = copies
        var cleaned = false
        client.visionAudio.stopAction = {
            DispatchQueue.main.async {
                _ = hw.close(speaker)
                _ = hw.close(microphone)
                cleaned = true
            }
        }
        let list = WindowList(macName: "fixture", windows: [], active: .desktop,
            videoEpoch: epoch, audioPrivacy: privacy)
        let network = DispatchQueue(label: "fixture.catalog.receive")
        network.sync { client.receiveVisionAudioCatalogBarrier(list) }
        check(!cleaned && !hw.isIdle, "main cleanup remains pending after receive returns")
        check(!hw.matches(speaker, version: 1) && render(output) == 0,
            "same epoch invalid privacy revokes actual playback claim before main drains")
        input(capture)
        check(copies == before && !client.microphoneFrames.open,
            "same epoch invalid privacy revokes actual capture claim and closes frame gate")
        drain { cleaned }
        check(cleaned && hw.isIdle, "main cleanup eventually releases both reserved roles")
    }
}
do {
    switch CommandLine.arguments.dropFirst().first {
    case "catalog": try runCatalogBarrierChecks()
    case "review": try runReviewRegressions()
    case "hardware": try runHardwareChecks()
    case "failure": try runFailureChecks()
    case nil:
        try runCatalogBarrierChecks()
        if failures == 0 { try runReviewRegressions() }
        if failures == 0 { try runHardwareChecks() }
        if failures == 0 { try runFailureChecks() }
        if failures == 0 { try runPlayerChecks() }
    default: throw SyntheticError()
    }
}
catch { failures += 1; print("FAIL unexpected error \(error)") }
print("RESULT_ASSERTIONS \(checks)")
print("RESULT_FAILURES \(failures)")
exit(failures == 0 ? 0 : 1)
