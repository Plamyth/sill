import XCTest

@MainActor
final class ConnectionUITests: XCTestCase {
    private func existingApp() throws -> XCUIApplication {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["CCR_CONNECTION_UI_APPROVED"] == "1" else {
            throw XCTSkip("Root의 runner 설치·기기 조율 후에만 실행합니다.")
        }
        guard ProcessInfo.processInfo.environment["CCR_CONNECTION_UI_AUDIO_OFF_VERIFIED"] == "1" else {
            throw XCTSkip("직전 기기·Host metadata의 오디오 OFF를 부모가 확인한 뒤에만 활성화합니다.")
        }
        return try activateExistingApp()
    }

    private func existingMediaApp() throws -> XCUIApplication {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["CCR_CONNECTION_UI_MEDIA_APPROVED"] == "1" else {
            throw XCTSkip("부모의 명시적 media 승인과 별도 테스트 선택 후에만 실행합니다.")
        }
        return try activateExistingApp()
    }

    private func activateExistingApp() throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.ambrion.sillcanvas.ipad")
        guard [.runningForeground, .runningBackground, .runningBackgroundSuspended].contains(app.state) else {
            throw XCTSkip("정상 앱이 실행 중이지 않습니다. 이 후보는 앱을 launch하지 않습니다.")
        }
        app.activate()
        guard app.wait(for: .runningForeground, timeout: 10) else {
            throw NSError(domain: "ConnectionUI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "정상 앱 활성화 미확인"])
        }
        return app
    }

    private func unique(_ query: XCUIElementQuery) throws -> XCUIElement {
        var count = query.count
        if count == 0 {
            guard query.firstMatch.waitForExistence(timeout: 5) else {
                throw NSError(domain: "ConnectionUI", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "AX 요소 미노출"])
            }
            count = query.count
        }
        guard count == 1 else {
            throw NSError(domain: "ConnectionUI", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "동일 AX 요소가 여러 개면 조작하지 않습니다."])
        }
        return query.element(boundBy: 0)
    }

    private func ensureToolbarVisible(_ app: XCUIApplication) throws {
        let toggles = app.buttons.matching(identifier: "iPadToolbarToggle")
        let count = toggles.count
        guard count <= 1 else { throw NSError(domain: "ConnectionUI", code: 10) }
        if count == 0 { return }
        let toggle = toggles.element(boundBy: 0)
        let label = toggle.label
        if label == "상단 메뉴 숨기기" { return }
        guard label == "상단 메뉴 표시", toggle.isHittable, toggle.isEnabled else {
            throw NSError(domain: "ConnectionUI", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "숨겨진 상단바의 정확한 표시 버튼 미확인"])
        }
        toggle.tap()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    func test01ReadDefaultMonitorAX() throws {
        let app = try existingApp()
        try ensureToolbarVisible(app)
        let chooser = try unique(app.buttons.matching(identifier: "macDisplayChooser"))
        let value = try XCTUnwrap(chooser.value as? String, "기본 모니터 AX 값 미노출")
        XCTAssertFalse(value.isEmpty)
        let data = try JSONSerialization.data(withJSONObject: [
            "identifier": chooser.identifier, "label": chooser.label, "value": value,
            "meaning": "현재 AX 관측값. 기본 모니터 일치 판정은 별도 원본 대조가 필요합니다."
        ], options: [.prettyPrinted, .sortedKeys])
        let ax = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        ax.name = "default-monitor-ax"
        ax.lifetime = .keepAlways
        add(ax)
        capture(app, name: "default-monitor")
    }

    private func tapUnique(_ query: XCUIElementQuery) throws {
        try tapChecked(unique(query))
    }

    private func tapChecked(_ element: XCUIElement) throws {
        guard element.isHittable, element.isEnabled else {
            throw NSError(domain: "ConnectionUI", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "정확한 native AX 요소가 조작 가능하지 않습니다."])
        }
        element.tap()
    }

    private func menuAction(_ app: XCUIApplication, label: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)", label,
            Int(XCUIElement.ElementType.button.rawValue), Int(XCUIElement.ElementType.menuItem.rawValue)))
    }

    func test02OpenNativeAudioChooserOnly() throws {
        let app = try existingApp()
        try openAudioChooser(app)
    }

    private func openAudioChooser(_ app: XCUIApplication) throws {
        let audio = app.menuBars.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "오디오"))
        let count = audio.count
        guard count <= 1 else { throw NSError(domain: "ConnectionUI", code: 11) }
        let nativeAudio = count == 1 ? audio.element(boundBy: 0) : nil
        if let nativeAudio, nativeAudio.isHittable {
            try tapChecked(nativeAudio)
            capture(app, name: "native-audio-menu")
            try tapUnique(menuAction(app, label: "입력·출력 선택…"))
        } else {
            try ensureToolbarVisible(app)
            try tapUnique(app.buttons.matching(identifier: "workspaceOverflow"))
            capture(app, name: "workspace-native-menu")
            try tapUnique(menuAction(app, label: "설정"))
            capture(app, name: "host-settings-panel")
            try tapUnique(app.buttons.matching(NSPredicate(
                format: "identifier == %@ AND label == %@", "openAudioRoutes", "오디오 입력·출력 선택…")))
        }
        XCTAssertTrue(app.navigationBars["오디오 입력·출력"].waitForExistence(timeout: 5))
        capture(app, name: "audio-input-output-chooser")
    }

    private func captureMediaState(_ app: XCUIApplication, name: String) {
        capture(app, name: name)
        let ax = XCTAttachment(string: app.debugDescription)
        ax.name = name + "-native-ax"
        ax.lifetime = .keepAlways
        add(ax)
    }

    private func requireAudioChooser(_ app: XCUIApplication) throws {
        let chooser = try unique(app.navigationBars.matching(identifier: "오디오 입력·출력"))
        guard chooser.isHittable else { throw NSError(domain: "ConnectionUI", code: 7) }
    }

    func test03EnableIPadFullDuplex() async throws {
        let app = try existingMediaApp()
        if !app.navigationBars["오디오 입력·출력"].exists {
            try openAudioChooser(app)
        }
        try requireAudioChooser(app)
        captureMediaState(app, name: "before-enable-full-duplex")
        let fullDuplex = try unique(app.buttons.matching(identifier: "useIPadFullDuplex"))
        guard fullDuplex.isHittable, fullDuplex.isEnabled else {
            throw NSError(domain: "ConnectionUI", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "full-duplex 버튼이 비활성 또는 미노출입니다."])
        }
        fullDuplex.tap()
        captureMediaState(app, name: "after-enable-full-duplex")
        try await Task.sleep(nanoseconds: 10_000_000_000)
        captureMediaState(app, name: "ten-seconds-after-enable-full-duplex")
    }

    func test04DisableIPadAudio() async throws {
        let app = try existingMediaApp()
        if !app.navigationBars["오디오 입력·출력"].exists {
            try openAudioChooser(app)
        }
        try requireAudioChooser(app)
        try tapUnique(app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "stopIPadAudio", "iPad 입출력 중지")))
        captureMediaState(app, name: "after-explicit-stop-ipad-audio")
        try await Task.sleep(nanoseconds: 10_000_000_000)
        captureMediaState(app, name: "ten-seconds-after-explicit-stop-ipad-audio")
    }
}
