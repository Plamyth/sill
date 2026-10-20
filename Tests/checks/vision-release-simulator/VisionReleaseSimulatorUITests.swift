import XCTest

final class VisionReleaseSimulatorUITests: XCTestCase {
    func testWorkspaceFixture() throws {
        continueAfterFailure = false
        let context = try XCTUnwrap(ProcessInfo.processInfo.environment["CCR_VISION_RELEASE_CONTEXT"])
        let app = XCUIApplication(bundleIdentifier: "dev.ambrion.SillVision.ReleaseTest")
        app.launchArguments = ["--ccr-release-context", "{}"]
        app.launch()
        XCTAssertTrue(app.staticTexts["격리 테스트 실행 정보가 없거나 일치하지 않습니다."].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["입력 초안"].exists)
        app.terminate()
        app.launchArguments = ["--ccr-release-context", context]
        app.launch()
        let open = app.buttons["입력 초안"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        XCTAssertTrue(open.isEnabled)
        open.tap()
        let editor = app.textViews["Mac 입력 초안"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons["검토"].tap()
        let rejected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "조합 중이거나 받아쓰기 결과가")).firstMatch
        XCTAssertTrue(rejected.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("isolated draft 27")
        app.buttons["검토"].tap()
        XCTAssertTrue(app.buttons["Mac 입력"].waitForExistence(timeout: 5))
        app.buttons["다시 편집"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "isolated draft 27")
        app.buttons["검토"].tap()
        app.buttons["Mac 입력"].tap()
        XCTAssertTrue(app.staticTexts["전송 경로에 전달했습니다. 원래 Mac 화면에서 입력 결과를 확인하세요."].waitForExistence(timeout: 5))
        app.buttons["닫고 초안 지우기"].tap()
        XCTAssertTrue(app.staticTexts["release.provider-output"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["release.provider-output"].label, "isolated draft 27")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "실제 초안 UI에서 입력하고 격리 공급자가 재조회한 결과"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["연결 해제"].tap()
        XCTAssertTrue(app.staticTexts["Mac 화면을 공간 창에서 사용합니다"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["입력 초안"].exists)
    }
}
