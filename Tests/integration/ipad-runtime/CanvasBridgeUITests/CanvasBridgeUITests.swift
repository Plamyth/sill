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

    func testPeleNodeEditAndSave() throws {
        let app = try app()
        app.buttons["다이어그램"].firstMatch.tap()
        let diagram = app.webViews["canvasPeleDiagram"].firstMatch
        XCTAssertTrue(diagram.waitForExistence(timeout:10))
        let node = diagram.buttons["시험 글자"].firstMatch
        XCTAssertTrue(node.waitForExistence(timeout:10))
        node.tap()
        XCTAssertTrue(app.buttons["내용 수정"].waitForExistence(timeout:5))
        app.buttons["내용 수정"].tap()
        let editor = app.textViews["canvasNodeTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout:5))
        XCTAssertEqual(editor.value as? String,"시험 글자")
        editor.coordinate(withNormalizedOffset:CGVector(dx:0.99,dy:0.1)).tap()
        editor.typeText(" · Pele 수정")
        let changed = try XCTUnwrap(editor.value as? String)
        app.buttons["확정"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout:5))
        XCTAssertTrue(diagram.buttons[changed].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Pencil 그림과 구조 데이터가 Obsidian에 저장됐습니다."].waitForExistence(timeout:20))
        app.terminate()
        app.launch()
        app.buttons["다이어그램"].firstMatch.tap()
        XCTAssertTrue(app.webViews["canvasPeleDiagram"].buttons[changed].waitForExistence(timeout:10))
        let image = XCTAttachment(screenshot:app.screenshot())
        image.lifetime = .keepAlways
        add(image)
    }

    func testModeSwitchDisablesHiddenOriginalAndRestoresIt() throws {
        let app = try app()
        let surface = app.descendants(matching:.any).matching(identifier:"canvasNavigationSurface").firstMatch
        let node = app.descendants(matching:.any).matching(identifier:"canvasNode-\(nodeID)").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout:5))
        let originalFrame = node.frame
        let viewport = surface.value as? String
        for mode in ["다이어그램","나란히 보기","원본 그림","나란히 보기","다이어그램","원본 그림"] {
            app.buttons[mode].firstMatch.tap()
            if mode == "다이어그램" {
                // XCTest still includes accessibilityHidden elements in queries on iPadOS 27.
                for element in [surface,node] {
                    let hidden = XCTNSPredicateExpectation(predicate:NSPredicate(format:"hittable == false"),object:element)
                    XCTAssertEqual(XCTWaiter.wait(for:[hidden],timeout:5),.completed)
                }
                XCTAssertTrue(app.webViews["canvasPeleDiagram"].waitForExistence(timeout:10))
            } else {
                XCTAssertTrue(surface.waitForExistence(timeout:5))
                for element in [surface,node] {
                    let restored = XCTNSPredicateExpectation(predicate:NSPredicate(format:"hittable == true"),object:element)
                    XCTAssertEqual(XCTWaiter.wait(for:[restored],timeout:5),.completed)
                }
                XCTAssertEqual(surface.value as? String,viewport)
                XCTAssertTrue(node.exists)
                if mode == "원본 그림" { XCTAssertEqual(node.frame,originalFrame) }
            }
        }
    }

    func testNativeModeLifetimeProbe() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CCR_MODE_LIFETIME_PROBE"] == "1",
            "전용 네이티브 수명 검사 앱에서 선택 실행합니다.")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier:try XCTUnwrap(ProcessInfo.processInfo.environment["CCR_TEST_BUNDLE"]))
        app.launchArguments = ["--ccr-test-runtime",try XCTUnwrap(ProcessInfo.processInfo.environment["CCR_TEST_RUNTIME_ID"])]
        app.launch()
        let result = app.staticTexts["canvasModeLifetimeResult"]
        XCTAssertTrue(result.waitForExistence(timeout:30))
        XCTAssertTrue(result.label.hasPrefix("CANVAS_MODE_LIFETIME total="),result.label)
        XCTAssertTrue(result.label.contains("failed=0"),result.label)
    }
    func testPencilCorrectionNativeProbe() throws {
        let app = XCUIApplication(bundleIdentifier:try XCTUnwrap(ProcessInfo.processInfo.environment["CCR_TEST_BUNDLE"]))
        app.launchArguments = ["--ccr-test-runtime",try XCTUnwrap(ProcessInfo.processInfo.environment["CCR_TEST_RUNTIME_ID"]),"--ccr-pencil-native-check"]
        app.launch()
        let result = app.staticTexts["pencilCorrectionNativeResult"]
        XCTAssertTrue(result.waitForExistence(timeout:30))
        XCTAssertTrue(result.label.hasPrefix("PENCIL_CORRECTION total="),result.label)
        XCTAssertTrue(app.staticTexts["Pencil 그림과 구조 데이터가 Obsidian에 저장됐습니다."].waitForExistence(timeout:25))
        let shot = XCTAttachment(screenshot:app.screenshot())
        shot.name = "pencil-correction-production-geometry-and-vault"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testLivePencilRemoteRevision() throws {
        let app = try app()
        XCTAssertTrue(app.staticTexts["Mac에서 수정한 시험 글자"].waitForExistence(timeout:20))
        print("CCR_PENCIL_LIVE_READY")
        fflush(stdout)
        XCTAssertTrue(app.staticTexts["Mac 실시간 교정 👩🏽‍💻"].waitForExistence(timeout:30))
        let shot = XCTAttachment(screenshot:app.screenshot())
        shot.name = "pencil-correction-remote-live"
        shot.lifetime = .keepAlways
        add(shot)
    }

}
