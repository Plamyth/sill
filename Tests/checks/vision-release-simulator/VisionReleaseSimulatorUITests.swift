import XCTest

final class VisionReleaseSimulatorUITests: XCTestCase {
    func testDraftKeyboardDelivery() throws {
        continueAfterFailure = false
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["CCR_VISION_RELEASE_CONTEXT"])
        var context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        context["profile"] = "text"
        let app = XCUIApplication(bundleIdentifier: "dev.ambrion.SillVision.ReleaseTest")
        app.launchArguments = ["--ccr-release-context", String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)]
        app.launch()
        defer { app.terminate() }
        let provider = app.staticTexts.matching(identifier: "release.provider-output")
        XCTAssertTrue(provider.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(provider.count, 1)
        XCTAssertTrue(app.buttons["입력 초안"].waitForExistence(timeout: 15))
        app.buttons["입력 초안"].tap()
        let editor = app.textViews["Mac 입력 초안"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("isolated draft 27")
        let delivered = editor.value as? String
        if delivered != "isolated draft 27" {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "초안 키보드 입력 실패 UI 계층"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(delivered, "isolated draft 27", "네이티브 편집기에 실제 입력된 값")
    }

    func testRemotePeerFixture() throws {
        continueAfterFailure = false
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["CCR_VISION_RELEASE_CONTEXT"])
        var context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let app = XCUIApplication(bundleIdentifier: "dev.ambrion.SillVision.ReleaseTest")
        context["profile"] = "unknown"
        app.launchArguments = ["--ccr-release-context", String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)]
        app.launch()
        XCTAssertTrue(app.staticTexts["격리 테스트 실행 정보가 없거나 일치하지 않습니다."].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["입력 초안"].exists)
        app.terminate()
        context["profile"] = "remote"
        app.launchArguments = ["--ccr-release-context", String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)]
        app.launch()
        XCTAssertTrue(app.staticTexts["release.remote-authenticated"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["release.remote-presented"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["release.provider-output"].exists)
        let open = app.buttons["입력 초안"]
        XCTAssertTrue(open.isEnabled)
        open.tap()
        let editor = app.textViews["Mac 입력 초안"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("remote fixture 41")
        XCTAssertEqual(editor.value as? String, "remote fixture 41", "네이티브 편집기에 실제 입력된 값")
        app.buttons["검토"].tap()
        app.buttons["Mac 입력"].tap()
        XCTAssertTrue(app.staticTexts["전송 경로에 전달했습니다. 원래 Mac 화면에서 입력 결과를 확인하세요."].waitForExistence(timeout: 5))
        app.buttons["닫고 초안 지우기"].tap()
        let received = app.staticTexts["release.remote-input"]
        let readback = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "remote fixture 41"), object: received)
        XCTAssertEqual(XCTWaiter.wait(for: [readback], timeout: 10), .completed)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "시뮬레이션 TLS 피어의 네이티브 영상과 실제 원격 입력 재조회"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["격리 공급자 초기화"].tap()
        XCTAssertTrue(app.staticTexts["release.remote-reset"].waitForExistence(timeout: 5))
        app.buttons["연결 해제"].tap()
        XCTAssertTrue(app.staticTexts["Mac 화면을 공간 창에서 사용합니다"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["입력 초안"].exists)
    }

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
        XCTAssertEqual(editor.value as? String, "isolated draft 27", "네이티브 편집기에 실제 입력된 값")
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
