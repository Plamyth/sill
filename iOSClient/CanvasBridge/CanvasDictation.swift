import AVFoundation
import Speech

@MainActor
final class CanvasDictation: ObservableObject {
    @Published var draft = ""
    @Published private(set) var status = "시작을 누르면 iPad 마이크로 받아씁니다."
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published private(set) var isFinalizing = false

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var finalization: Task<Void,Never>?
    private var generation = UUID()
    private var ownsMicrophoneLease = false
    private let audioLeaseId = UUID()

    func start() async {
        guard !isListening, !isStarting, !isFinalizing else { return }
        isStarting = true
        let sessionId = UUID()
        generation = sessionId
        defer { isStarting = false }

        let speechPermission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning:$0) }
        }
        guard generation == sessionId else { return }
        guard speechPermission == .authorized else {
            status = "음성 인식 권한이 필요합니다. iPad 설정에서 허용해 주세요."
            return
        }
        guard await AVCaptureDevice.requestAccess(for:.audio) else {
            status = "마이크 권한이 필요합니다. iPad 설정에서 허용해 주세요."
            return
        }
        guard generation == sessionId else { return }
        guard let recognizer = SFSpeechRecognizer(locale:Locale(identifier:"ko-KR")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            status = "이 iPad에서는 한국어 기기 내 받아쓰기를 사용할 수 없습니다. 음성은 전송하지 않았습니다."
            return
        }

        draft = ""

        do {
            try IPadAudioSession.shared.acquire(.canvasDictation,leaseId:audioLeaseId)
            ownsMicrophoneLease = true
            let nextEngine = AVAudioEngine()
            let nextRequest = SFSpeechAudioBufferRecognitionRequest()
            nextRequest.requiresOnDeviceRecognition = true
            nextRequest.shouldReportPartialResults = true
            let input = nextEngine.inputNode
            let format = input.outputFormat(forBus:0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CanvasDictationError.audioFormat
            }
            input.installTap(onBus:0,bufferSize:1024,format:format) { buffer,_ in
                nextRequest.append(buffer)
            }
            tapInstalled = true
            engine = nextEngine
            request = nextRequest
            recognition = recognizer.recognitionTask(with:nextRequest) { [weak self] result,error in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == sessionId else { return }
                    if let result { self.draft = result.bestTranscription.formattedString }
                    if let error {
                        self.finish(status:"받아쓰기가 중단됐습니다: \(error.localizedDescription)")
                    } else if result?.isFinal == true {
                        self.finish(status:"받아쓰기 완료 · 문구를 확인한 뒤 저장하세요.")
                    }
                }
            }
            nextEngine.prepare()
            try nextEngine.start()
            guard generation == sessionId else { cancel(); return }
            isListening = true
            status = "듣는 중 · 설명을 말한 뒤 멈추기를 누르세요."
        } catch {
            finish(status:"마이크 시작 실패: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        isFinalizing = true
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus:0); tapInstalled = false }
        request?.endAudio()
        status = "마지막 문장을 정리하고 있습니다."
        let sessionId = generation
        finalization?.cancel()
        finalization = Task { [weak self] in
            try? await Task.sleep(for:.seconds(3))
            guard let self, self.generation == sessionId, self.isFinalizing else { return }
            self.finish(status:"받아쓰기 종료 · 표시된 문구를 확인한 뒤 저장하세요.")
        }
    }

    func cancel() {
        generation = UUID()
        finish(status:"받아쓰기를 취소했습니다.")
        draft = ""
    }

    private func finish(status message: String) {
        generation = UUID()
        finalization?.cancel()
        finalization = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus:0); tapInstalled = false }
        request?.endAudio()
        recognition?.cancel()
        engine = nil
        request = nil
        recognition = nil
        if ownsMicrophoneLease {
            IPadAudioSession.shared.release(leaseId:audioLeaseId)
            ownsMicrophoneLease = false
        }
        isListening = false
        isFinalizing = false
        status = message
    }
}

private enum CanvasDictationError: LocalizedError {
    case audioFormat
    var errorDescription: String? { "마이크 입력 형식을 확인할 수 없습니다." }
}
