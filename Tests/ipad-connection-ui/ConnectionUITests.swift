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
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 5), "AX 요소 미노출")
        XCTAssertEqual(query.count, 1, "동일 AX 요소가 여러 개면 조작하지 않습니다.")
        guard query.count == 1 else { throw NSError(domain: "ConnectionUI", code: 2) }
        return query.element(boundBy: 0)
    }

    private func ensureToolbarVisible(_ app: XCUIApplication) throws {
        let monitor = app.buttons.matching(identifier: "macDisplayChooser")
        if monitor.count == 1, monitor.firstMatch.isHittable { return }
        let toggle = try unique(app.buttons.matching(identifier: "iPadToolbarToggle"))
        guard toggle.label == "상단 메뉴 표시", toggle.isHittable else {
            throw NSError(domain: "ConnectionUI", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "숨겨진 상단바의 정확한 표시 버튼 미확인"])
        }
        capture(app, name: "before-toolbar-reveal")
        toggle.tap()
        let reflected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "상단 메뉴 숨기기"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [reflected], timeout: 2), .completed,
                       "상단바 표시 AX 라벨 미반영. 재탭하지 않습니다.")
        let chooser = try unique(monitor)
        XCTAssertTrue(chooser.isHittable, "표시 후 모니터 AX가 조작 가능하지 않습니다.")
        capture(app, name: "after-toolbar-reveal")
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
        let element = try unique(query)
        guard element.isHittable else {
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
        try ensureToolbarVisible(app)
        capture(app, name: "before-native-menu")
        let audio = app.menuBars.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "오디오"))
        if audio.count == 1, audio.firstMatch.isHittable {
            try tapUnique(audio)
            capture(app, name: "native-audio-menu")
            try tapUnique(menuAction(app, label: "입력·출력 선택…"))
        } else {
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
}
