import AVFoundation
import Foundation
import StreamProtocol

final class DuplexGraph: VisionAudioGraphDriving {
    var recordPermissionGranted = true
    var starts = 0
    func configure(_ profile: VisionAudioProfile) throws {}
    func start(playback: VisionAudioPlaybackGraph?, capture: VisionAudioCaptureGraph?) throws {
        starts += 1
        capture?.formatChanged(AVAudioFormat(standardFormatWithSampleRate: 48_000,channels:1)!)
    }
    func stop() throws {}
    func deactivate() throws {}
}
enum VisionAudioSharedHardware { static let shared = VisionAudioHardware(driver: DuplexGraph()) }
func runDuplexRegression() -> Int32 {
    var failures = 0, checks = 0
    func check(_ value: Bool, _ name: String) {
        checks += 1
        if !value { failures += 1; print("FAIL \(name)") }
    }
    func pump(_ condition: () -> Bool) {
        let until = Date().addingTimeInterval(2)
        while !condition() && Date() < until { RunLoop.main.run(until:Date().addingTimeInterval(0.005)) }
    }
    let graph = DuplexGraph(), owner = UUID()
    let hw = VisionAudioHardware(driver:graph)
    let player = VisionAudioPlayer(hardware:hw,ownerID:owner)
    var controls: [VisionAudioControl] = []
    let controller = VisionAudioController(send:{controls.append($0)},player:player)
    let scope = VisionAudioScope(connection:UUID(),source:1)
    controller.setForeground(true); controller.update(.available(scope)); controller.enable()
    let grant = controls.last!.grant
    controller.acknowledge(id:grant.id,enabled:true,scope:scope,reason:nil)
    let samples = [Int16](repeating:10000,count:4800)
    let packet = samples.withUnsafeBufferPointer { AudioPacket.pack(sampleRate:48000,channels:1,samples:$0) }
    player.receive(packet,grant:grant.id)
    pump { graph.starts > 0 }
    check(graph.starts > 0,"duplex regression actual player committed")
    let capture = VisionMicrophoneCapture(hardware:hw,owner:owner,permitted:{true},requestPermission:{true},closeFrames:{},failed:{_ in})
    var ready = false, startFailed = false
    Task { @MainActor in
        do { try await capture.start {_ in}; ready = true } catch { startFailed = true }
    }
    pump { ready || startFailed }
    check(ready && !startFailed,"duplex regression actual capture committed")
    controller.setForeground(false)
    do { try capture.stop() }
    catch { check(false,"healthy duplex shutdown does not need microphone cleanup") }
    check(hw.cleanupProblem == nil,"healthy revoked sibling does not quarantine shared hardware")
    let until = Date().addingTimeInterval(0.03)
    RunLoop.main.run(until:until)
    check(hw.cleanupProblem == nil && player.cleanupProblem == nil,"queued playback retirement stays clean after microphone close")
    if hw.cleanupProblem != nil { try? capture.retryCleanup() }
    print("RESULT_ASSERTIONS \(checks)")
    print("RESULT_FAILURES \(failures)")
    return failures == 0 ? 0 : 1
}
