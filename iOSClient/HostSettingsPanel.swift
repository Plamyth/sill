import SwiftUI
import UIKit
import StreamProtocol

/// The Settings panel: the Mac's streaming settings, changed from here the way the Sill menu on
/// the Mac changes them (one change, one apply, at most one short restart; Sill.app saves them).
///
/// A panel in the view hierarchy, mirroring the Apps drawer on the trailing edge; not a sheet,
/// popover or Menu. The client has no system presentation anywhere; sheets and popovers adapt by
/// size class, which is unknown for the Duo; the layout harness draws a fake Duo screen inside an
/// iPad window, which a system presentation would escape; and a tall sheet or a flipped popover
/// could cross the half-folded crease. Its height follows its content; only the middle scrolls,
/// where the room under the bar is short (259 pt in the compact halves at 500×710, an iPad window
/// that narrow; 275 on an iPhone SE on its side), so the header and Disconnect are always in reach.
///
/// Every control shows `client.settings.displayed` (the Mac's value with this device's unanswered
/// pick over it) and sends through `client.changeSettings`, one field per control, from its action
/// only. Errors show inline, never in alerts. After the Mac's settings come the device's own groups:
/// This iPad (or iPhone), whose switch is a preference here (`StreamClient.gesturesKey`) and sends
/// nothing to the Mac, and whose rows, as accessibility actions, do their gestures
/// (`client.sendGesture`), since VoiceOver keeps three fingers for itself; then Take the Tour.
struct HostSettingsPanel: View {
    @ObservedObject var client: StreamClient
    /// Done, Esc or ⌘., and the VoiceOver escape gesture.
    let close: () -> Void
    /// Pair This iPad…: the stream screen puts the panel away and covers the stream with the
    /// pairing overlay.
    var pairThisDevice: () -> Void = {}
    /// Take the Tour: the stream screen puts the panel away and shows the tour of its layout.
    var takeTour: () -> Void = {}

    @AccessibilityFocusState private var headerFocused: Bool
    /// Two seconds on this connection and still no state: the Mac runs a Sill without settings.
    @State private var olderMac = false
    /// Bumped when Low Power Mode toggles, so the frame rate note is read again.
    @State private var powerState = 0
    /// This device's switch for three-finger gestures (docs/trackpad-gestures-plan.md §8): on unless
    /// turned off, read by `StreamClient.sendGesture` at each gesture, never sent.
    @AppStorage(StreamClient.gesturesKey) private var gesturesOn = true
    /// VoiceOver is on: it keeps three-finger swipes and taps for itself, so the This iPad group says
    /// its rows do the gestures instead.
    @State private var voiceOver = HostSettingsPanel.voiceOverRunning

    private var mac: String { client.macName.isEmpty ? "Mac" : client.macName }
    private static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    /// DEBUG `-SillSettingsEnd 1`: the rows start scrolled to their end, so a photo of a short
    /// screen shows the last groups (Direct Wireless, Away from home, This iPad, Take the Tour).
    private static var startsAtEnd: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "SillSettingsEnd")
        #else
        return false
        #endif
    }
    /// DEBUG `-SillSettingsScroll gestures`: the rows start scrolled to the This iPad group, so a
    /// photo of a short screen shows its switch and rows, which the footnote under them pushes out
    /// of `-SillSettingsEnd`'s view.
    private static var startsAtGestures: Bool {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "SillSettingsScroll") == "gestures"
        #else
        return false
        #endif
    }
    private static let gesturesGroupID = "thisDevice"
    /// `UIAccessibility.isVoiceOverRunning`; DEBUG `-SillVoiceOver 1` says it is, for the harness's
    /// photos of the group's VoiceOver footnote.
    static var voiceOverRunning: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SillVoiceOver") { return true }
        #endif
        return UIAccessibility.isVoiceOverRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // The rows at their own height when they fit, a scroll view in the room left when not.
            ViewThatFits(in: .vertical) {
                middle
                ScrollViewReader { reader in
                    ScrollView { middle }
                        .scrollIndicatorsFlash(onAppear: true)
                        .scrollBounceBehavior(.basedOnSize)
                        .defaultScrollAnchor(Self.startsAtEnd ? .bottom : .top)
                        .onAppear { if Self.startsAtGestures { reader.scrollTo(Self.gesturesGroupID, anchor: .top) } }
                }
            }
            foot
        }
        .padding(14)
        .background(Self.shape.fill(Palette.bar))
        .overlay(Self.shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.65), radius: 30, x: 0, y: 24)
        .tint(Palette.accent)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        // VoiceOver stays inside while it is open, the escape gesture closes it, and focus starts
        // on the Mac's name.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        .onAppear { headerFocused = true }
        // A refused change: the control has already gone back to the Mac's value, and the reason
        // is in the footer or the note. The haptic is a no-op on an iPad.
        .sensoryFeedback(.warning, trigger: client.settingsRefusals)
        .onChange(of: client.settingsRefusals) { _, _ in
            AccessibilityNotification.Announcement("\(mac)의 설정이 변경되지 않았습니다").post()
        }
        .onChange(of: client.settingsProblem) { _, problem in
            if let problem { AccessibilityNotification.Announcement(problem).post() }
        }
        .task(id: client.connectedAt) {
            olderMac = false
            let elapsed = client.connectedAt.map { Date().timeIntervalSince($0) } ?? 0
            if elapsed < 2 { try? await Task.sleep(for: .seconds(2 - elapsed)) }
            if !Task.isCancelled { olderMac = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            powerState += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification).receive(on: RunLoop.main)) { _ in
            voiceOver = Self.voiceOverRunning
        }
    }

    // MARK: Header and foot (pinned)

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.macName.isEmpty ? "Mac" : client.macName)
                    .font(.headline)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headerFocused)
                if let state = client.settings.host {
                    VStack(alignment: .leading, spacing: 1) {
                        // Wraps rather than cutting the bitrate off at larger text sizes; each
                        // value keeps its unit (no-break spaces), and a wrap falls after a "·".
                        // It ends in how this device's connection reaches the Mac, the connect
                        // screen's word; "Direct" is the old "Connected directly" line.
                        Text(Self.readout(state.stream, route: client.route))
                            .fixedSize(horizontal: false, vertical: true)
                        // Its own line: beside the numbers it never fit the panel's width, and it
                        // is what confirms the Virtual Display switch took effect.
                        if state.stream?.onVirtualDisplay == true {
                            Text("가상 디스플레이에서 스트리밍 중")
                        }
                        // From afar, how, with the round trip (it needs no clock agreement between
                        // the two devices, unlike frame age); the readout above then ends in the
                        // bitrate. Wraps like the readout (larger text on the outer display cut it
                        // off), after a "·" as the readout does, and never inside the route: its
                        // spaces are no-break ones, as on the Mac's card (at xxLarge on the outer
                        // display it read "Connected through" / "Tailscale · 48 ms").
                        if let r = remoteRoute {
                            Text("연결됨 · \(r.localizedPhrase.replacingOccurrences(of: " ", with: "\u{00A0}"))\u{00A0}· \(Self.rttText(client.linkStats))")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Away from home (docs/remote-bundle-plan.md §5.8): which quality this
                        // connection's Mac runs for it, from the Mac's word. Its own line, wrapping
                        // like the readout; the quality kept whole.
                        if let line = AwayCopy.headerLine(state.away) {
                            Text(line.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.spokenReadout(state.stream, route: client.route, remote: remoteRoute,
                                                           rttMs: client.linkStats?.rtt?.median)
                                        + (AwayCopy.headerLine(state.away)?.spoken ?? ""))
                }
            }
            Spacer(minLength: 8)
            // A 44 pt tall tap area (the word alone is about 42×22) without moving the header: the
            // padding and the shape sit inside the label, which is what the button hit-tests, and
            // the layout takes them back outside.
            Button(action: close) {
                Text("완료")
                    .padding(.vertical, 11)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .padding(.vertical, -11)
            .padding(.horizontal, -4)
            .font(.body.weight(.semibold))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }

    /// Disconnect, in Leave's old place of honour: the bar's last slot is Settings now.
    private var foot: some View {
        Button(action: { client.disconnect() }) {
            // The header already names the Mac: when a long name leaves no room, "Disconnect"
            // alone says enough (a truncated "Disconnect from…ah's MacBook Pro" read badly).
            ViewThatFits(in: .horizontal) {
                Label("\(mac) 연결 해제", systemImage: "xmark.circle").lineLimit(1)
                Label("연결 해제", systemImage: "xmark.circle").lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accent)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.control))
        .accessibilityLabel("\(mac) 연결 해제")
        .padding(.top, 10)
    }

    // MARK: Middle (scrolls when short)

    #if os(iOS)
    private var sentryReport: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("센트리")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.text)
            Text(client.sentryObservation.statusText)
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHint("수신한 호스트 보고입니다. 현재 보호 효과나 입력 허가를 뜻하지 않습니다.")
            if !client.sentryControl.statusText.isEmpty {
                Text(client.sentryControl.statusText)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = client.sentryControl.problem {
                Text(problem).font(.footnote).foregroundStyle(Palette.muted)
            }
            if client.sentryControl.canSet {
                HStack {
                    Button { client.setIPadSentry(desired: true) } label: {
                        Text("센트리 켜기").frame(minHeight: 44)
                    }
                        .disabled(!client.sentryControl.canSet(desired: true))
                        .accessibilityHint("호스트에 센트리 보호를 켜도록 요청합니다.")
                    Button { client.setIPadSentry(desired: false) } label: {
                        Text("센트리 끄기").frame(minHeight: 44)
                    }
                        .disabled(!client.sentryControl.canSet(desired: false))
                        .accessibilityHint("호스트의 화면 보호와 로컬 입력 차단 해제를 요청합니다. 오디오와 시스템 권한은 바꾸지 않습니다.")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            if client.sentryControl.canQuery {
                Button { client.queryIPadSentry() } label: {
                    Text("이전 센트리 요청 결과 확인").frame(minHeight: 44)
                }
                    .buttonStyle(.bordered)
                    .accessibilityHint("저장한 원래 요청 그대로 결과만 조회합니다.")
            }
            sentryReturnControls
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sentryHostReport")
    }

    private var sentryReturnControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mac 인증 복귀").font(.subheadline.weight(.semibold))
            Text(client.sentryReturn.statusText).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Text(client.hasIPadSentryReturnKey ? "등록된 iPad 전용 인증 키 있음" : "등록된 iPad 전용 인증 키 미확인")
                .font(.footnote).foregroundStyle(Palette.muted)
            Text("인증 성공, 과거 복귀 완료, 현재 보호·오디오·입력 상태는 각각 확인합니다. 키 등록·회전·해제는 복귀를 실행하지 않습니다.")
                .font(.footnote).foregroundStyle(Palette.muted)
            Button { client.requestIPadSentryReturn(mode: .macLocal) } label: {
                Text("Mac에서 인증하고 복귀").frame(minHeight: 44)
            }
            .disabled(!client.sentryReturn.canRequest || client.sentryReturn.context?.capability.macLocal != true)
            Button { client.requestIPadSentryReturn(mode: .deviceBoundKey) } label: {
                Text("이 iPad에서 인증하고 복귀").frame(minHeight: 44)
            }
            .disabled(!client.sentryReturn.canRequest || client.sentryReturn.context?.capability.deviceBoundKey != true || !client.hasIPadSentryReturnKey)
            .accessibilityHint("등록된 전용 키로 이 요청의 서명에 생체 인증 또는 기기 암호를 사용합니다.")
            Button { client.queryIPadSentryReturn() } label: {
                Text("인증 복귀 상태 조회").frame(minHeight: 44)
            }.disabled(!client.sentryReturn.canQuery)
            Button { client.cancelIPadSentryReturn() } label: {
                Text("인증 복귀 취소").frame(minHeight: 44)
            }.disabled(!client.sentryReturn.canCancel && client.sentryReturnKeyOperation == nil)
            ForEach([SentryReturnKeyEnrollment.Action.enroll, .rotate, .revoke], id: \.rawValue) { action in
                Button { client.manageIPadSentryReturnKey(action) } label: {
                    Text(action == .enroll ? "iPad 인증 키 등록" : action == .rotate ? "iPad 인증 키 회전" : "iPad 인증 키 해제")
                        .frame(minHeight: 44)
                }
                .disabled(!client.canManageIPadSentryReturnKey(action))
            }
            if let problem = client.sentryReturnKeyProblem { Text(problem).font(.footnote).foregroundStyle(.orange) }
        }
        .buttonStyle(.bordered)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sentryReturnControls")
    }
    #endif

    @ViewBuilder private var middle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: client.showAudioRoutes) {
                Label("오디오 입력·출력 선택…", systemImage: "arrow.triangle.swap")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("openAudioRoutes")
            .padding(.bottom, 12)
            IPadRemoteAudioControl(client: client)
                .padding(.bottom, 12)
            IPadMicrophoneControl(client: client)
                .padding(.bottom, 12)
            #if os(iOS)
            sentryReport
                .padding(.bottom, 12)
            #endif
            if let state = client.settings.host, let shown = client.settings.displayed {
                if state.softwareEncoder {
                    // Neither a restart nor a return is promised: hosts before 2026-09-25 keep the
                    // software encoder until they relaunch, newer ones go back by themselves.
                    Callout(text: "\(mac)의 하드웨어 인코더가 사용 중이거나 응답하지 않아 현재는 표준 해상도, 최대 60 fps로 스트리밍합니다.")
                }
                if let problem = client.settingsProblem {
                    Callout(text: problem)
                }
                // The link cannot carry the quality (the Mac's own judgement, docs/remote-bundle-plan.md
                // §6.7): what it recommends, with a button that picks it. From an older Mac, which
                // judges nothing, the round-trip test away from home as before.
                if let callout = AwayCopy.callout(link: state.link, away: state.away, mac: mac) {
                    Callout(text: callout.text, button: callout.button.map { b in
                        Callout.Action(title: b.title, spoken: b.spoken) { client.changeSettings(b.change) }
                    })
                } else if AwayCopy.showsRttCallout(away: state.away, remote: remoteRoute != nil, slowLink: client.slowLink) {
                    Callout(text: "\(mac)에서 화면이 느리게 전송되고 있습니다. 화질을 ‘낮음’으로 또는 해상도를 ‘표준’으로 설정하세요.")
                }
                streamRows(shown)
                Footnote(text: streamFooter)
                // Which quality these rows set, away from home or at home.
                if let note = AwayCopy.footnote(state.away, mac: mac, remoteAccessOn: client.macInfo?.remoteAccess == true) {
                    Footnote(text: note, top: 0)
                }
                // As in the Mac's Settings › Streaming: its own group, the Mac's name for it, and
                // what it trades away.
                Rows {
                    Toggle(isOn: binding(shown.prioritizeSpeed) { HostSettingsChange(prioritizeSpeed: $0) }) {
                        RowTitle(title: "인코딩 속도 우선", since: client.settings.pendingSince(.prioritizeSpeed))
                    }
                    .rowFrame()
                }
                Footnote(text: "\(mac)이 사용 중일 때 지연을 줄입니다. 화면 선명도는 낮아집니다.")
                Rows {
                    let unavailable = !state.virtualDisplayAvailable && !shown.virtualDisplay
                    Toggle(isOn: binding(shown.virtualDisplay) { HostSettingsChange(virtualDisplay: $0) }) {
                        RowTitle(title: "가상 디스플레이", since: client.settings.pendingSince(.virtualDisplay))
                    }
                    // Off and impossible on this host: disabled, the reason under it. On, it can
                    // always be turned off, as from the Mac's own menu.
                    .disabled(unavailable)
                    .accessibilityHint(state.virtualDisplayNote ?? "")
                    .rowFrame()
                }
                if let note = state.virtualDisplayNote {
                    Footnote(text: note, warning: true)
                } else {
                    Footnote(text: "선택한 창을 스트리밍하는 동안 \(mac)의 보이지 않는 디스플레이로 이동합니다. 다른 창에 가려져도 화면이 계속 갱신됩니다.")
                }
                Footnote(text: "\(mac)에서 스트리밍하는 모든 기기에 적용됩니다. 스트리밍이 잠시 재시작됩니다.")
                // Direct Wireless Connection: how devices reach the Mac, not how it streams; after the
                // closing footer, whose "the stream restarts" is not true of it, and last, the least
                // changed row with the longest footer (the compact halves' 259 pt shows the rest
                // first). Disabled only away from home (the Mac refuses it from a remote connection):
                // off from a directly connected device is allowed, as on the Mac, and its consequence
                // is written beside it. No row for a host without it.
                if let direct = shown.directWireless {
                    Rows {
                        Toggle(isOn: binding(direct) { HostSettingsChange(directWireless: $0) }) {
                            RowTitle(title: "직접 무선 연결", since: client.settings.pendingSince(.directWireless))
                        }
                        // A warning about turning it off, so only while the switch shows on.
                        .accessibilityHint(client.connectedDirectly && direct ? "끄면 이 \(device)의 연결이 끊어집니다." : "")
                        // From afar the Mac refuses it anyway: how devices near the Mac reach it is
                        // theirs and the Mac's to change.
                        .disabled(remoteRoute != nil)
                        .rowFrame()
                    }
                    Footnote(text: remoteRoute != nil ? "\(mac)이나 근처에 있는 기기에서 변경하세요." : directFooter(on: direct))
                }
                if !state.persistent {
                    Footnote(text: "SillHost가 종료될 때까지 이 설정을 유지합니다.")
                }
                awayFromHome
            } else if olderMac {
                Label("여기서 설정을 변경하려면 \(mac)의 Sill을 업데이트하세요.", systemImage: "arrow.down.circle")
                    .font(.body)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 4)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Palette.muted)
                    Text("설정을 불러오는 중…")
                }
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 4)
            }
            // After everything of the Mac's, whatever state its settings are in: while they load, and
            // for a Mac without them too. Both are this device's own: its gestures, then the tour.
            thisDevice
            tour
        }
    }

    /// The last group: this device's, not the Mac's, so after everything about the Mac, and there
    /// whatever the Mac is (while settings load, and for a Mac without them). It sends nothing. It
    /// comes after This iPad's gestures, under their footnote, so it needs no space of its own above
    /// it even while the Mac's settings load.
    @ViewBuilder private var tour: some View {
        Rows {
            Button(action: takeTour) {
                Text(TourPolicy.takeTourTitle)
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(TourPolicy.takeTourHint(device: device))
            .rowFrame()
        }
        Footnote(text: TourPolicy.takeTourFootnote(device: device))
    }

    /// Most-changed first, so the compact halves' 259 pt shows Quality, Resolution and Frame Rate
    /// before anything scrolls.
    private func streamRows(_ shown: StreamSettings) -> some View {
        Rows {
            AdaptiveRow(title: "화질", since: client.settings.pendingSince(.bitrate)) {
                Picker("화질", selection: binding(shown.bitrate) { HostSettingsChange(bitrate: $0) }) {
                    ForEach(QualityPreset.allCases) { Text($0.localizedTitle).tag($0.rawValue) }
                    if QualityPreset(rawValue: shown.bitrate) == nil {
                        // Set by hand on the Mac: shown, never offered (the Mac's menu does the same).
                        Text(QualityPreset.localizedTitle(forBitrate: shown.bitrate)).tag(shown.bitrate)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()     // one line; the row stacks instead when it does not fit beside the title
            }
            RowDivider()
            AdaptiveRow(title: "해상도", since: client.settings.pendingSince(.captureScale)) {
                Picker("해상도", selection: binding(shown.captureScale) { HostSettingsChange(captureScale: $0) }) {
                    Text("레티나").tag(2.0)
                    Text("표준").tag(1.0)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            RowDivider()
            AdaptiveRow(title: "프레임률", since: client.settings.pendingSince(.maxFPS)) {
                // A Mac-held value such as 90 selects no segment, as on the Mac.
                Picker("프레임률", selection: binding(shown.maxFPS) { HostSettingsChange(maxFPS: $0) }) {
                    Text("60 fps").tag(60)
                    Text("120 fps").tag(120)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    /// Shows the value the panel displays; moving the control sends that one field. Nothing else
    /// ever sends (not `onChange(of:)`, not a state arriving).
    private func binding<V>(_ value: V, _ change: @escaping (V) -> HostSettingsChange) -> Binding<V> {
        Binding(get: { value }, set: { client.changeSettings(change($0)) })
    }

    // MARK: Away from home

    /// This connection's way in from afar, when it is one.
    private var remoteRoute: RemoteRoute? { client.remoteRoute }

    /// The Mac's last group (docs/remote-access-plan.md §7.11, docs/home-pairing-plan.md §7.6):
    /// whether this device is paired with the Mac and can reach it away from home, from the Mac's
    /// kind 18 (DiscoveryPolicy.awayFromHome). "Paired" for a saved Mac, however it paired; Pair This
    /// iPad… only in an unpaired session: at home over TLS on a Mac that lets any device in (it pairs
    /// at this session's own door, Remote Access on or not), or over a plain door with Remote Access
    /// on (through the remote door, as before). None from an older Mac (no kind 18 on this
    /// connection).
    @ViewBuilder private var awayFromHome: some View {
        if let info = client.macInfo {
            Text("외부에서 연결")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            switch DiscoveryPolicy.awayFromHome(saved: client.macInfoSaved, remoteSession: remoteRoute != nil,
                                                remoteAccess: info.remoteAccess, tlsAtHome: client.sessionAtHomeOverTLS) {
            case .paired(let reach):
                Rows {
                    Label("페어링됨", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.text)
                        .rowFrame()
                }
                switch reach {
                case .connected:
                    if let r = remoteRoute { Footnote(text: "\(r.localizedPhrase) 연결되었습니다.") }
                case .reaches:
                    Footnote(text: "외부에서는 \(Self.reach(info)) \(mac)에 연결합니다.")
                case .turnOnRemoteAccess:
                    Footnote(text: Self.turnOnRemoteAccess(mac))
                }
            case .pairThisDevice(let atHome):
                if client.manualPairingUIEnabled {
                    Rows {
                        Button(action: pairThisDevice) {
                            Text("이 \(device) 페어링…")
                                .foregroundStyle(Palette.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .rowFrame()
                    }
                    Footnote(text: atHome ? DiscoveryPolicy.HomeCopy.pairThisDeviceAtHome(mac: mac, device: device)
                                          : "한 번 페어링하면 VPN이나 인터넷으로 \(mac)에 연결할 수 있습니다. \(mac)에 표시된 코드를 이 \(device)로 스캔하세요.")
                } else {
                    Footnote(text: "이 기기의 소유 Mac 자동 등록을 확인하지 못했습니다. 저장된 Mac과 기기 키를 유지한 채 연결 상태를 확인하세요.")
                }
            case .turnOnRemoteAccess:
                Footnote(text: Self.turnOnRemoteAccess(mac))
            }
        }
    }

    /// With Remote Access off on the Mac: how to reach it away from home.
    static func turnOnRemoteAccess(_ mac: String) -> String {
        "외부에서 \(mac)에 연결하려면 Mac의 Sill 설정에서 원격 접근을 켜세요."
    }

    // MARK: This device

    /// This device's own group, after the Mac's: its switch for three-finger gestures, and what each
    /// does when the Mac takes them (Take the Tour follows it). After the Mac's rows because it is
    /// the least changed, and the compact halves' 259 pt show the Mac's rows first. The switch
    /// reaches nothing; a row, activated by VoiceOver, Voice Control or Switch Control, does its
    /// gesture on the Mac as three fingers would (`sendGesture`: the switch, the Mac's `gestures`,
    /// the Desktop first while a window streams).
    @ViewBuilder private var thisDevice: some View {
        Text("이 \(device)")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
            .id(Self.gesturesGroupID)
        Rows {
            Toggle(isOn: $gesturesOn) {
                Text("세 손가락 제스처").foregroundStyle(Palette.text)
            }
            .rowFrame()
            if gesturesOn, macTakesGestures {
                ForEach(Self.gestureRows, id: \.gesture) { row in
                    RowDivider()
                    GestureRow(symbol: row.symbol, gesture: row.gesture, action: row.action, does: row.does) {
                        _ = client.sendGesture($0, fingers: 3)
                    }
                }
            }
        }
        Footnote(text: gesturesFooter)
    }

    /// The Mac's window list said it takes the gestures (`WindowList.gestures`).
    private var macTakesGestures: Bool { (client.hostGestures ?? 0) >= TrackpadGesture.generation }

    /// What each gesture does on the Mac, and what the row does as an accessibility action: its one
    /// gesture, or, for the Spaces, one action each way (natural direction: a swipe left brings the
    /// Space on the right). The pinch opens Launchpad on macOS 14 and 15, from the same key.
    private static let gestureRows: [(symbol: String, gesture: String, action: String, does: [GestureRow.Action])] = [
        ("arrow.up", "위로 쓸어넘기기", "미션 컨트롤", [GestureRow.Action(name: "미션 컨트롤", gesture: .swipeUp)]),
        ("arrow.down", "아래로 쓸어넘기기", "앱 윈도우 보기", [GestureRow.Action(name: "앱 윈도우 보기", gesture: .swipeDown)]),
        ("arrow.left.and.right", "좌우로 쓸어넘기기", "데스크탑 공간", [GestureRow.Action(name: "오른쪽 데스크탑 공간", gesture: .swipeLeft),
                                                                   GestureRow.Action(name: "왼쪽 데스크탑 공간", gesture: .swipeRight)]),
        ("arrow.down.right.and.arrow.up.left", "오므리기", "앱", [GestureRow.Action(name: "앱", gesture: .pinch)]),
        ("arrow.up.left.and.arrow.down.right", "펼치기", "데스크탑 보기", [GestureRow.Action(name: "데스크탑 보기", gesture: .spread)]),
    ]

    /// Under the switch: where the gestures go and what they do, or why nothing happens.
    private var gesturesFooter: String {
        guard gesturesOn else { return "끄면 세 손가락 제스처가 작동하지 않습니다." }
        guard macTakesGestures else { return "사용하려면 \(mac)의 Sill을 업데이트하세요." }
        // VoiceOver keeps three-finger swipes and taps for itself, and no touch of them reaches Sill.
        var text = voiceOver ? "VoiceOver에서 세 손가락 제스처를 사용하므로, 위 항목을 선택하면 \(mac)에서 해당 동작을 실행합니다."
            : "트랙패드나 스트리밍 화면에서 세 손가락을 사용하세요."
        text += " 창을 스트리밍하는 동안 제스처를 사용하면 먼저 데스크탑이 표시됩니다. 반대 제스처는 열린 화면을 닫습니다. \(mac)의 키보드 단축키로 실행하므로, Mac 키보드 설정에서 꺼진 단축키는 작동하지 않습니다."
        if device == "iPad" { text += " 네 손가락 쓸어넘기기와 Magic Keyboard 트랙패드 제스처는 iPadOS에서 처리합니다." }
        return text
    }

    /// "through Tailscale (mac-mini.tail1234.ts.net)": the first VPN or internet address the Mac
    /// gave; otherwise "through your VPN or the internet".
    static func reach(_ info: MacInfo) -> String {
        guard let a = info.addresses.first(where: { $0.kind == MacAddress.vpn || $0.kind == MacAddress.internet }) else {
            return "VPN이나 인터넷으로"
        }
        if a.kind == MacAddress.internet { return "인터넷(\(a.host))으로" }
        let name = a.via.isEmpty || a.via.hasPrefix("VPN (") ? "VPN" : a.via
        return "\(name)(\(a.host))을 통해"
    }

    // MARK: Copy

    /// Under the Mac's name: what actually runs, which confirms a change took effect and shows
    /// what the software encoder caps, then how this device's connection reaches the Mac
    /// ("… · 15 Mbps · Wi-Fi"; StreamClient.route), when its path says (never on a remote session:
    /// its route line says how instead). Whether it runs on the virtual display is a line of its
    /// own (see `header`). A no-break space before each "·" keeps it with the value before it, so a
    /// wrap at larger text never starts a line with one.
    static func readout(_ stream: RunningStream?, route: DiscoveryPolicy.Method? = nil) -> String {
        let values = stream.map { ["\($0.width)×\($0.height)", "\($0.fps)\u{00A0}fps", "\($0.mbps)\u{00A0}Mbps"] } ?? ["스트리밍 중 아님"]
        return (values + [route?.word].compactMap { $0 }).joined(separator: "\u{00A0}· ")
    }

    /// "48 ms", the last second's median round trip; "–" for a second without a pong.
    static func rttText(_ stats: StreamClient.LinkStats?) -> String {
        stats?.rtt.map { "\($0.median)\u{00A0}ms" } ?? "–"
    }

    /// The readout as VoiceOver says it, ending in how this device reaches the Mac: its link, or
    /// from afar the remote route with the round trip, which wins (a remote session has no link
    /// word; see `header`).
    static func spokenReadout(_ stream: RunningStream?, route: DiscoveryPolicy.Method? = nil, remote: RemoteRoute? = nil,
                              rttMs: Int? = nil) -> String {
        var link = route.map { ", " + spoken($0) } ?? ""
        if let remote {
            link = ", \(remote.localizedPhrase) 연결됨" + (rttMs.map { ", 왕복 지연 \($0)밀리초" } ?? "")
        }
        guard let s = stream else { return "스트리밍 중 아님" + link }
        return "화면 \(s.width) 곱하기 \(s.height), 초당 \(s.fps)프레임, 초당 \(s.mbps)메가비트로 스트리밍 중"
            + (s.onVirtualDisplay ? ", 가상 디스플레이 사용 중" : "") + link
    }

    /// The route as VoiceOver says it: a sentence's end rather than the bare word.
    private static func spoken(_ route: DiscoveryPolicy.Method) -> String {
        switch route {
        case .wired: return "케이블로 연결됨"
        case .wifi: return "Wi-Fi로 연결됨"
        case .direct: return "직접 연결됨"
        }
    }

    /// "iPhone" or "iPad", for copy about this device.
    private var device: String { UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad" }

    /// Under the Direct Wireless Connection row: what it does and costs, and, while the switch shows
    /// on and this device is connected over it, what turning it off does to this device: the Mac
    /// disconnects every device on peer-to-peer Wi-Fi once its listener has changed (1.5 s), and a
    /// device still connected directly shares no network the Mac is listed on (one that does moves
    /// to it by itself), so it cannot come back until it does. Once the switch shows off (turned
    /// off here or on the Mac, with this connection still up for that moment) the warning is moot.
    private func directFooter(on: Bool) -> String {
        var text = "AirDrop처럼 같은 Wi-Fi 네트워크에 접속하지 않아도 \(mac)에 연결할 수 있습니다. 켜져 있는 동안 Wi-Fi 스트리밍이 끊길 수 있습니다."
        if on, client.connectedDirectly { text += " 이 \(device)는 직접 연결 중입니다. 끄면 연결이 끊어집니다." }
        return text
    }

    /// Under the stream rows: what Quality counts and what its top presets need (the Mac's
    /// Settings › Streaming says the same). A frame rate limit above what this screen shows changes
    /// nothing for it, which is worth saying on a 60 Hz device; away from home this device asks
    /// for 60 fps.
    private var streamFooter: String {
        _ = powerState
        var text = "화질은 60 fps 기준이며, 120 fps에서는 두 배의 데이터를 사용합니다. " + QualityPreset.localizedFastLinkNote
        let away = client.awayCapsFrameRate
        let wanted = StreamClient.wantedFPS(remote: away)
        guard wanted < 120 else { return text }
        if away, StreamClient.wantedFPS() > wanted {
            text += " 외부에서는 이 \(device)가 \(wanted) fps로 요청하여 Mac의 전송 데이터를 절반으로 줄입니다."
        } else if ProcessInfo.processInfo.isLowPowerModeEnabled, StreamClient.screenMaximumFPS() >= 120 {
            text += " 저전력 모드에서는 이 \(device)의 프레임률이 \(wanted) fps로 제한됩니다."
        } else {
            text += " 이 \(device)는 최대 \(wanted) fps로 표시합니다."
        }
        return text
    }
}

// MARK: - Rows

/// An inset group of rows on the drawer's control colour.
private struct Rows<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.control))
    }
}

/// A row's title with the pending spinner beside it.
private struct RowTitle: View {
    let title: String
    let since: Double?
    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(Palette.text)
            PendingSpinner(since: since)
        }
    }
}

/// A title with its control beside it, or under it when larger text leaves no room beside.
private struct AdaptiveRow<Control: View>: View {
    let title: String
    let since: Double?
    let control: Control
    /// A text size change while the panel is open left the menu picker measured at the old size
    /// (seen going from accessibility sizes back to Large: the row stayed stacked), so the row is
    /// rebuilt, and measured afresh, whenever it changes.
    @Environment(\.dynamicTypeSize) private var typeSize
    init(title: String, since: Double?, @ViewBuilder control: () -> Control) {
        self.title = title; self.since = since; self.control = control()
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                label
                Spacer(minLength: 8)
                control
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                control
            }
            .padding(.vertical, 8)
        }
        .id(typeSize)
        .rowFrame()
    }
    /// The control carries the same title for VoiceOver, so this one is not read twice.
    private var label: some View { RowTitle(title: title, since: since).accessibilityHidden(true) }
}

/// One gesture and what it does on the Mac: the words side by side when they fit and stacked when
/// larger text leaves no room, never cut off; one VoiceOver element ("Swipe Up, Mission Control").
/// A touch does nothing here; activated by VoiceOver, Voice Control or Switch Control (which cannot
/// make three-finger strokes, or keep them) it does its gesture: a button for one, a named action
/// each way for the Spaces.
private struct GestureRow: View {
    struct Action { let name: String; let gesture: TrackpadGestures.Gesture }
    let symbol: String
    let gesture: String
    let action: String
    let does: [Action]
    let perform: (TrackpadGestures.Gesture) -> Void
    /// Measured afresh when the text size changes, as `AdaptiveRow` is.
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if let only = does.first, does.count == 1 {
            row.accessibilityAddTraits(.isButton).accessibilityAction { perform(only.gesture) }
        } else {
            row.accessibilityActions {
                ForEach(does, id: \.name) { item in Button(item.name) { perform(item.gesture) } }
            }
        }
    }
    private var row: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                icon
                Text(gesture).foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Text(action).foregroundStyle(Palette.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(gesture).foregroundStyle(Palette.text)
                    Text(action).foregroundStyle(Palette.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
        }
        .id(typeSize)
        .rowFrame()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(gesture), \(action)")
    }
    private var icon: some View {
        Image(systemName: symbol)
            .foregroundStyle(Palette.muted)
            .frame(width: 24)
            .accessibilityHidden(true)
    }
}

/// A hairline between rows, inset like the system's.
private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 14)
    }
}

/// A small spinner shown only once a pick has waited 300 ms for its answer: a quick Mac never
/// makes it flicker.
private struct PendingSpinner: View {
    let since: Double?
    @State private var shown = false
    var body: some View {
        ZStack {
            if shown { ProgressView().controlSize(.small).tint(Palette.muted) }
        }
        .frame(width: shown ? nil : 0)
        .accessibilityHidden(true)
        .task(id: since) {
            shown = false
            guard let since else { return }
            let wait = 0.3 - (ProcessInfo.processInfo.systemUptime - since)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled { shown = true }
        }
    }
}

/// A group's footer: small, muted, from the leading edge; orange with a warning sign for a problem.
/// `top` 0 continues the footer above it.
private struct Footnote: View {
    let text: String
    var warning = false
    var top: CGFloat = 6
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if warning { Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true) }
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(warning ? Color.orange : Palette.muted)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, top)
        .padding(.bottom, 12)
    }
}

/// Something to know before touching anything: the Mac did not answer, its hardware encoder is
/// down, or the link cannot carry the quality, with a button that picks what the Mac recommends
/// (at least 44 pt tall, like the rows). Above the groups.
private struct Callout: View {
    struct Action {
        let title: String
        let spoken: String
        let perform: () -> Void
    }
    let text: String
    var button: Action? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text(text).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if let button {
                Button(action: button.perform) {
                    Text(button.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.control))
                .accessibilityLabel(button.spoken)
            }
        }
        .font(.footnote)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.14)))
        .accessibilityElement(children: .contain)
        .padding(.bottom, 10)
    }
}

private extension View {
    /// A row inside a group: at least 44 pt tall, inset 14 pt.
    func rowFrame() -> some View {
        frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 14)
    }
}
