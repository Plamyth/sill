import XCTest
import PencilKit

final class CanvasBridgeUITests: XCTestCase {
    func testNativeInkRenderingMask() {
        let app = XCUIApplication(bundleIdentifier:"com.ambrion.rea.appaudit")
        app.launchArguments = ["--native-ink-render-probe"]
        app.terminate(); app.launch()
        XCTAssertTrue(app.wait(for:.runningForeground,timeout:10))
        let result = app.staticTexts["nativeInkProbeResult"]
        XCTAssertTrue(result.waitForExistence(timeout:10))
        let completed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"label BEGINSWITH %@","완료"),object:result)
        XCTAssertEqual(XCTWaiter.wait(for:[completed],timeout:20),.completed)
        print("NATIVE_INK_RENDER_UI " + result.label)
        XCTAssertTrue(result.label.contains("\"nativeLeftInk\":true"))
        XCTAssertTrue(result.label.contains("\"nativeRightInk\":true"))
        XCTAssertTrue(result.label.contains("\"nativeGapInk\":false"))
        XCTAssertTrue(result.label.contains("\"exportLeftInk\":true"))
        XCTAssertTrue(result.label.contains("\"exportRightInk\":true"))
        XCTAssertTrue(result.label.contains("\"exportGapInk\":false"))
        XCTAssertTrue(result.label.contains("\"legacyGapInk\":true"))
        XCTAssertTrue(result.label.contains("\"malformedRefused\":true"))
        XCTAssertTrue(result.label.contains("\"invalidDrawingRefused\":true"))
        XCTAssertTrue(result.label.contains("\"emptyDrawingGapInk\":false"))
    }

}
