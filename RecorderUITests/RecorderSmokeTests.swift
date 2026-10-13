import XCTest
final class RecorderSmokeTests: XCTestCase {
    func testLaunchAndMicrophoneDenial() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Pete Recorder"].waitForExistence(timeout: 10))
        let record = app.buttons["recordButton"]
        XCTAssertTrue(record.exists)
        record.tap()
        let notice = app.staticTexts["notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("Microphone access denied"))
        XCTAssertTrue(app.buttons["Start recording"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Microphone denial preserves recorder UI"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout: 10))
    }
}
