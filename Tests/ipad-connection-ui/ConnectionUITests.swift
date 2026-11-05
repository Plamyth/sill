import XCTest

@MainActor
final class ConnectionUITests: XCTestCase {
    private func existingApp() throws -> XCUIApplication {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["CCR_CONNECTION_UI_APPROVED"] == "1" else {
            throw XCTSkip("Root의 runner 설치·기기 조율 후에만 실행합니다.")
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

    private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    func test01ReadDefaultMonitorAX() throws {
        let app = try existingApp()
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

    func test02OpenNativeAudioChooserOnly() throws {
        let app = try existingApp()
        capture(app, name: "before-native-menu")
        let audio = try unique(app.menuBars.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "오디오")))
        XCTAssertTrue(audio.isHittable, "네이티브 메뉴 미노출. 좌표나 키로 대체하지 않습니다.")
        guard audio.isHittable else { throw NSError(domain: "ConnectionUI", code: 3) }
        audio.tap()
        capture(app, name: "native-audio-menu")
        let choose = try unique(app.descendants(matching: .menuItem).matching(
            NSPredicate(format: "label == %@", "입력·출력 선택…")))
        XCTAssertTrue(choose.isHittable)
        guard choose.isHittable else { throw NSError(domain: "ConnectionUI", code: 4) }
        choose.tap()
        XCTAssertTrue(app.navigationBars["오디오 입력·출력"].waitForExistence(timeout: 5))
        capture(app, name: "audio-input-output-chooser")
    }
}
