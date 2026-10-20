import XCTest

final class CanvasBridgeUITests: XCTestCase {
    private let nodeID = "D29DDF60-B4C6-48DD-A75A-219C8F2A52A7"

    private func app() throws -> XCUIApplication {
        continueAfterFailure = false
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["CCR_TEST_RUNTIME_ID"])
        let bundle = try XCTUnwrap(ProcessInfo.processInfo.environment["CCR_TEST_BUNDLE"])
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["--ccr-test-runtime", id]
        app.launch()
        XCTAssertTrue(app.buttons["요소 이동"].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func edit(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["요소 이동"].firstMatch.tap()
        let node = app.descendants(matching: .any).matching(identifier: "canvasNode-\(nodeID)").firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 8))
        node.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["도구"].firstMatch.tap()
        app.buttons["구조 데이터"].tap()
        XCTAssertTrue(app.buttons["내용 수정"].waitForExistence(timeout: 5))
        app.buttons["내용 수정"].tap()
        let editor = app.textViews["canvasNodeTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        return editor
    }

    func testEditAndSave() throws {
        let app = try app()
        let editor = edit(app)
        let value = editor.value as? String ?? ""
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.1)).tap()
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        editor.typeText("👩🏽‍💻 앞 뒤")
        XCTAssertEqual(editor.value as? String, "👩🏽‍💻 앞 뒤")
        let erase = app.buttons["선택 글자 지우기"].firstMatch
        XCTAssertFalse(erase.isEnabled)
        editor.doubleTap()
        let select = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Select", "선택"])).firstMatch
        if select.waitForExistence(timeout: 1) { select.tap() }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: erase)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        erase.tap()
        XCTAssertEqual(editor.value as? String, "👩🏽‍💻 앞 ")
        app.toolbars.buttons["실행 취소"].firstMatch.tap()
        XCTAssertEqual(editor.value as? String, "👩🏽‍💻 앞 뒤")
        app.toolbars.buttons["다시 실행"].firstMatch.tap()
        XCTAssertEqual(editor.value as? String, "👩🏽‍💻 앞 ")
        app.buttons["확정"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pencil 그림과 구조 데이터가 Obsidian에 저장됐습니다."].waitForExistence(timeout: 20))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.lifetime = .keepAlways
        add(image)
    }

    func testReopenRemoteRevision() throws {
        let app = try app()
        XCTAssertTrue(app.staticTexts["Mac에서 수정한 시험 글자"].waitForExistence(timeout: 20))
        let editor = edit(app)
        XCTAssertEqual(editor.value as? String, "Mac에서 수정한 시험 글자")
        app.buttons["나중에"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
    }
}
