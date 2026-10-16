import SwiftUI
import StreamProtocol

@main
struct SillVisionApp: App {
    var body: some Scene {
        WindowGroup {
            SillVisionWorkspace()
        }
        .defaultSize(width: 1280, height: 800)
    }
}

struct SillVisionWorkspace: View {
    @StateObject private var client = StreamClient()
    @StateObject private var stats = ClientStatsReporter()
    @Environment(\.scenePhase) private var phase
    @StateObject private var input = VisionInputSession()
    @State private var mode = VisionPointer.Mode.pointer
    @State private var keyboardShown = false
    @State private var keysShown = false
    @State private var code = ""
    @State private var address = ""
    @State private var addMac = false
    @State private var changingSource = false
    @GestureState private var dragging = false
    @State private var transitions = VisionTransition()
    @State private var inputSuspended = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(client.macName.isEmpty ? "Sill Vision" : client.macName).font(.headline)
                Spacer()
                Text(client.status).font(.caption).lineLimit(2)
                if client.connected {
                    Button("연결 해제") { requestTransition(.disconnect) }
                }
            }
            if inputSuspended {
                Text("Mac의 입력 해제 수신을 확인하지 못해 원격 입력을 중지했습니다.").foregroundStyle(.orange)
            }
            if client.connected {
                screen
                controls
                HStack {
                    Button("누른 입력 해제") { input.releaseAll() }
                        .accessibilityHint("이 Vision 앱이 누른 키와 드래그를 해제합니다.")
                    Spacer()
                    if input.moving { Text("연결 경로 전환 중").font(.caption) }
                }
                VisionAudioControls(audio: client.visionAudio,
                                    allowStart: phase == .active && !transitions.isPending && !inputSuspended)
            } else {
                hosts
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 500)
        .task { input.bind(client); updateInputAdmission(); stats.attach(to: client); client.startBrowsing() }
        .onChange(of: inputAllowed) { _, _ in updateInputAdmission() }
        .onChange(of: phase, initial: true) { _, value in
            client.visionAudio.setForeground(value == .active)
            if value != .active { releaseInput() }
        }
        .onChange(of: client.connected) { _, connected in
            releaseInput()
            transitions.cancel()
            if connected { inputSuspended = false }
        }
        .onChange(of: client.videoSize) { _, _ in releaseInput() }
        .onChange(of: client.active) { _, _ in releaseInput() }
        .onChange(of: mode) { _, _ in releaseInput() }
        .onChange(of: dragging) { _, value in if !value { input.endGesture() } }
        .onDisappear {
            client.visionAudio.setForeground(false)
            if client.connected { requestTransition(.disconnect) } else { releaseInput() }
        }
        .sheet(isPresented: $addMac) { pairingForm }
        .confirmationDialog("같은 Mac에 연결된 iPad 화면도 바뀔 수 있습니다.", isPresented: $changingSource) {
            Button("Mac 전체 화면 표시") { requestTransition(.desktop) }
        }
    }

    private var hosts: some View {
        VStack(spacing: 18) {
            Text("Mac 화면을 공간 창에서 사용합니다").font(.title2)
            Text("연결할 Mac을 선택하세요. Vision Pro는 자체 키로 새로 페어링합니다.")
            ForEach(client.macs) { mac in
                Button {
                    client.connect(to: mac)
                } label: {
                    HStack { Text(mac.name); Spacer(); Text(mac.word ?? "") }
                }
            }
            if let ask = client.homeAsk {
                Text("\(ask.name)에 표시된 12자리 코드를 입력하세요.")
                TextField("페어링 코드", text: $code).textContentType(.oneTimeCode)
                HStack {
                    Button("페어링") { client.pairHome(code: code); code = "" }
                    Button("취소") { client.cancelHomeAsk(); code = "" }
                }
            }
            if case .failed(let problem) = client.pairing { Text(problem.text).foregroundStyle(.orange) }
            Button("주소로 Mac 추가") { addMac = true }
            Text("Mac 소리는 지원하는 호스트에서 직접 켤 수 있습니다. 마이크 전송은 아직 지원하지 않습니다.").font(.caption)
        }
        .frame(maxWidth: 650, maxHeight: .infinity)
    }

    private var screen: some View {
        GeometryReader { geo in
            ZStack {
                StreamView(client: client)
                InputOverlay(videoSize: client.videoSize, send: { input.overlayInput($0) },
                             setOwnPointer: client.setOwnPointer, proxy: input.keyboard,
                             isKeyboardShown: $keyboardShown, latchedModifiers: input.latched,
                             onModifiersConsumed: { input.consumeLatch() })
                    .allowsHitTesting(false)
                Color.clear.contentShape(Rectangle())
                    .gesture(SpatialTapGesture().exclusively(before: DragGesture(minimumDistance: 5))
                        .updating($dragging) { value, state, _ in
                            if case .second = value { state = true }
                        }
                        .onChanged { value in
                            guard case .second(let drag) = value else { return }
                            let bounds = CGRect(origin: .zero, size: geo.size)
                            guard let start = VisionPointer.point(drag.startLocation, bounds: bounds, video: client.videoSize),
                                  let p = VisionPointer.point(drag.location, bounds: bounds, video: client.videoSize, clamp: true) else { return }
                            input.drag(from: start, to: p, mode: mode)
                        }
                        .onEnded { value in
                            switch value {
                            case .first(let tap):
                                guard let p = VisionPointer.point(tap.location, bounds: CGRect(origin: .zero, size: geo.size), video: client.videoSize) else { return }
                                input.tap(p, mode: mode)
                            case .second: input.endGesture()
                            }
                        })
                if client.active == .none {
                    Button("Mac 전체 화면 표시") { changingSource = true }
                }
            }
            .onChange(of: geo.size, initial: true) { _, _ in
                releaseInput()
            }
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("조작", selection: $mode) {
                ForEach(VisionPointer.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Button("키보드") { input.keyboard.view?.toggleKeyboard() }
            Button("Esc") { input.press(.escape) }
            Button("Mac 키") { keysShown.toggle() }
                .popover(isPresented: $keysShown) {
                    VisionKeyPalette(input: input, desktop: client.active == .desktop)
                }
            Button("전체 화면") { changingSource = true }
            if let measured = client.linkStats {
                Text("\(measured.fps) fps · RTT \(measured.rtt.map { String($0.median) } ?? "측정 전") ms")
                    .font(.caption.monospacedDigit())
            }
        }
        .disabled(!input.canSend)
    }

    private var pairingForm: some View {
        VStack(spacing: 16) {
            Text("Mac 주소로 페어링").font(.title2)
            TextField("Mac 주소", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("12자리 코드", text: $code).textContentType(.oneTimeCode)
            if case .failed(let problem) = client.pairing { Text(problem.text).foregroundStyle(.orange) }
            Button("페어링") { client.pairTyped(code: code, address: address, overlay: false); code = "" }
            Button("닫기") { client.cancelPairing(); code = ""; addMac = false }
        }.padding(30).frame(width: 550)
    }

    private var inputAllowed: Bool {
        phase == .active && client.connected && client.active != .none && !transitions.isPending && !inputSuspended
    }

    private func updateInputAdmission() { input.allowed = inputAllowed }

    private func releaseInput() { input.releaseAll() }

    private func requestTransition(_ action: VisionTransition.Action) {
        client.visionAudio.stop()
        guard let ticket = transitions.request(action) else { return }
        let expected = client.connection
        updateInputAdmission()
        releaseInput()
        client.afterVisionInputRelease { readByHost in
            guard client.connection === expected else {
                _ = transitions.settle(ticket, confirmed: false)
                inputSuspended = true
                updateInputAdmission()
                return
            }
            let next = transitions.settle(ticket, confirmed: readByHost)
            guard next != nil || !readByHost else { return }
            inputSuspended = !readByHost
            defer { updateInputAdmission() }
            switch next {
            case .desktop: client.select(.desktop)
            case .disconnect: client.disconnect()
            case nil: break
            }
        }
    }
}

private struct VisionAudioControls: View {
    @ObservedObject var audio: VisionAudioController
    let allowStart: Bool

    var body: some View {
        HStack(spacing: 12) {
            let running = audio.presentation.phase.grant != nil
            Button(running ? "Mac 소리 중지" : "Mac 소리 켜기",
                   systemImage: running ? "speaker.slash" : "speaker.wave.2") {
                if running { audio.stop() } else if allowStart { audio.enable() }
            }
            .disabled(!running && (!audio.presentation.canEnable || !allowStart))
            .accessibilityHint(running ? "즉시 소리를 중지합니다." : "선택한 Mac의 소리만 수신합니다. 마이크는 켜지지 않습니다.")
            Text(message).font(.caption).lineLimit(2)
            Spacer()
        }
    }

    private var message: String {
        switch audio.presentation.phase {
        case .requesting: return "Mac의 소리 전송 확인을 기다립니다."
        case .waiting: return "소리 데이터를 기다립니다."
        case .rendering: return "Mac 소리 재생 중 · 마이크 꺼짐"
        case .failed(let problem): return problem
        case .off:
            switch audio.presentation.availability {
            case .disconnected: return "Mac 연결 후 사용할 수 있습니다."
            case .unsupported: return "현재 Mac 호스트는 소리 전송을 지원하지 않습니다."
            case .noSource: return "Mac 화면을 선택하면 소리를 켤 수 있습니다."
            case .available: return "Mac 소리 꺼짐 · 연결이 바뀌면 다시 켜야 합니다."
            }
        }
    }
}
