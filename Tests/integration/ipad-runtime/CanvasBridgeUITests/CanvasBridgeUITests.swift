import XCTest
import UIKit

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

    private func assertRotatedLinkPixels(_ app: XCUIApplication, degrees: Double) throws {
        let node = app.descendants(matching:.any).matching(identifier:"canvasNode-\(nodeID)").firstMatch
        let other = app.descendants(matching:.any).matching(identifier:"canvasNode-42478F2C-F81D-4AC9-B714-ECBD9DDAC411").firstMatch
        XCTAssertTrue(node.exists && other.exists)
        let unit = other.frame.width / 260
        XCTAssertGreaterThan(unit,0)
        let angle = degrees * .pi / 180
        let a = CGPoint(x:node.frame.midX + cos(angle)*130*unit,
                        y:node.frame.midY + sin(angle)*130*unit)
        let b = CGPoint(x:other.frame.minX,y:other.frame.midY)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot:screenshot)
        attachment.name = "rotation-link-pixel-check-\(degrees)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size:app.frame.size,format:format).image { _ in
            screenshot.image.draw(in:CGRect(origin:.zero,size:app.frame.size))
        }
        let image = try XCTUnwrap(normalized.cgImage)
        let width=image.width, height=image.height
        var bytes=[UInt8](repeating:0,count:width*height*4)
        let decoded = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            return true
        }
        XCTAssertTrue(decoded)
        let sx=Double(width)/app.frame.width, sy=Double(height)/app.frame.height
        let radius=max(2,Int(ceil(2*max(sx,sy))))
        for t in [0.03,0.15,0.35,0.6,0.8,0.97] {
            let x=Int(((a.x+(b.x-a.x)*t)-app.frame.minX)*sx)
            let y=Int(((a.y+(b.y-a.y)*t)-app.frame.minY)*sy)
            guard x-radius >= 0 && y-radius >= 0 && x+radius < width && y+radius < height else {
                XCTFail("연결선 검사 좌표가 화면 밖입니다")
                continue
            }
            var cyan=false
            for py in max(0,y-radius)...min(height-1,y+radius) {
                for px in max(0,x-radius)...min(width-1,x+radius) {
                    let i=(py*width+px)*4
                    if bytes[i]<100 && bytes[i+1]>150 && bytes[i+2]>150 { cyan=true }
                }
            }
            XCTAssertTrue(cyan,"회전한 경계와 연결선의 실제 화면 픽셀이 일치해야 합니다: \(degrees), \(t), \(x), \(y)")
        }
    }

    private func rotationHandle(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["요소 이동"].firstMatch.tap()
        let node = app.descendants(matching:.any).matching(identifier:"canvasNode-\(nodeID)").firstMatch
        XCTAssertTrue(node.waitForExistence(timeout:8))
        node.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        let handle = app.descendants(matching:.any).matching(identifier:"canvasNodeRotate-\(nodeID)").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout:5))
        return handle
    }

    func testRotateAndSave() throws {
        let app = try app()
        let handle = rotationHandle(app)
        let node = app.descendants(matching:.any).matching(identifier:"canvasNode-\(nodeID)").firstMatch
        let center = CGPoint(x:node.frame.midX,y:node.frame.midY)
        let start = CGPoint(x:handle.frame.midX,y:handle.frame.midY)
        let dx = start.x-center.x, dy = start.y-center.y
        let delta = Double(ProcessInfo.processInfo.environment["CCR_ROTATION_DELTA"] ?? "45") ?? 45
        let degrees = ProcessInfo.processInfo.environment["CCR_ROTATION_EXPECTED"] ?? "45"
        let angle = CGFloat(delta)*CGFloat.pi/180
        let end = CGPoint(x:center.x+dx*cos(angle)-dy*sin(angle),y:center.y+dx*sin(angle)+dy*cos(angle))
        let origin = app.coordinate(withNormalizedOffset:.zero)
        origin.withOffset(CGVector(dx:start.x,dy:start.y)).press(forDuration:0.15,
            thenDragTo:origin.withOffset(CGVector(dx:end.x,dy:end.y)))
        let changed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@",degrees),object:handle)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:8),.completed)
        XCTAssertTrue(app.staticTexts["Pencil 그림과 구조 데이터가 Obsidian에 저장됐습니다."].waitForExistence(timeout:20))
        try assertRotatedLinkPixels(app,degrees:Double(degrees)!)
        let shot = XCTAttachment(screenshot:app.screenshot())
        shot.name = "rotation-and-following-link-saved"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testReopenRotatedScene() throws {
        let app = try app()
        let handle = rotationHandle(app)
        let degrees = ProcessInfo.processInfo.environment["CCR_ROTATION_EXPECTED"] ?? "45"
        XCTAssertTrue((handle.value as? String ?? "").contains(degrees))
        let link = app.descendants(matching:.any).matching(identifier:"canvasLink-8FBAA143-E660-4E64-8EC1-3B20CE1E2DF9").firstMatch
        XCTAssertTrue(link.exists)
        try assertRotatedLinkPixels(app,degrees:Double(degrees)!)
        let shot = XCTAttachment(screenshot:app.screenshot())
        shot.name = "rotation-reopened-\(degrees)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testLiveRotatedRemoteRevision() throws {
        let app = try app()
        _ = rotationHandle(app)
        let updated = app.staticTexts["Obsidian 그림의 최신 내용을 iPad에 반영했습니다."]
        XCTAssertFalse(updated.exists)
        print("CCR_ROTATION_LIVE_READY")
        fflush(stdout)
        XCTAssertTrue(updated.waitForExistence(timeout:30))
        let handle = rotationHandle(app)
        XCTAssertTrue((handle.value as? String ?? "").contains("90"))
        try assertRotatedLinkPixels(app,degrees:90)
        let shot = XCTAttachment(screenshot:app.screenshot())
        shot.name = "rotation-live-Mac-update-90"
        shot.lifetime = .keepAlways
        add(shot)
    }

}
