import AVFoundation
import Foundation

#if os(visionOS)
private final class VisionAudioNativeGraph: VisionAudioGraphDriving {
    private struct Previous {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }
    private var previous: Previous?
    private var expected: Previous?
    private var engine: AVAudioEngine?
    private var inputTapped = false

    var recordPermissionGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }

    func configure(_ profile: VisionAudioProfile) throws {
        let session = AVAudioSession.sharedInstance()
        if previous == nil {
            previous = Previous(category: session.category, mode: session.mode, options: session.categoryOptions)
        }
        expected = Previous(category: profile == .microphone ? .playAndRecord : .playback,
                            mode: .default, options: [.mixWithOthers])
        try session.setCategory(profile == .microphone ? .playAndRecord : .playback,
                                mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    func start(playback: VisionAudioPlaybackGraph?, capture: VisionAudioCaptureGraph?) throws {
        let graph = AVAudioEngine()
        engine = graph
        if let playback {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: playback.format.rate,
                                             channels: AVAudioChannelCount(playback.format.channels), interleaved: false) else {
                throw NSError(domain: "VisionAudioGraph", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Unsupported playback format."])
            }
            let source = AVAudioSourceNode(format: format, renderBlock: playback.render)
            graph.attach(source)
            graph.connect(source, to: graph.mainMixerNode, format: format)
        }
        if let capture {
            guard recordPermissionGranted else { throw CancellationError() }
            let input = graph.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, (8_000...192_000).contains(format.sampleRate),
                  (1...8).contains(format.channelCount) else {
                throw NSError(domain: "VisionAudioGraph", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Microphone has no valid hardware format."])
            }
            capture.formatChanged(format)
            input.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, time in
                capture.copyInput(buffer, time)
            }
            inputTapped = true
        }
        graph.prepare()
        try graph.start()
        guard graph.isRunning else { throw CancellationError() }
    }

    func stop() throws {
        guard let engine else { return }
        engine.stop()
        guard !engine.isRunning else {
            throw NSError(domain: "VisionAudioGraph", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Audio engine did not stop."])
        }
        if inputTapped { engine.inputNode.removeTap(onBus: 0); inputTapped = false }
        self.engine = nil
    }

    func deactivate() throws {
        guard let previous else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        expected = previous
        try session.setCategory(previous.category, mode: previous.mode, options: previous.options)
        self.previous = nil
    }

    func categoryStillMatches() -> Bool {
        guard let expected else { return false }
        let session = AVAudioSession.sharedInstance()
        return session.category == expected.category
            && session.mode == expected.mode && session.categoryOptions == expected.options
    }
}

enum VisionAudioSharedHardware {
    static let shared: VisionAudioHardware = {
        let driver = VisionAudioNativeGraph()
        let hardware = VisionAudioHardware(driver: driver)
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                if note.name == AVAudioSession.routeChangeNotification,
                   let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                   AVAudioSession.RouteChangeReason(rawValue: raw) == .categoryChange,
                   driver.categoryStillMatches() { return }
                hardware.invalidate("오디오 상태가 바뀌었습니다. 정리 후 직접 다시 켜세요.")
            })
        }
        return hardware
    }()
    private static var observers: [NSObjectProtocol] = []
}
#endif
