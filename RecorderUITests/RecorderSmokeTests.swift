import XCTest
final class RecorderSmokeTests: XCTestCase {
    func testMinimalHomeAndMenuNavigationWithoutCapture() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.navigationBars["Pete Recorder"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["recordButton"].exists)
        XCTAssertTrue(app.buttons["microphoneControl"].exists)
        XCTAssertFalse(app.buttons["Find available microphones"].exists)
        XCTAssertFalse(app.staticTexts["Your saved recordings will appear here."].exists)
        XCTAssertFalse(app.staticTexts["notice"].exists)
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "Minimal capture home"; home.lifetime = .keepAlways; add(home)
        app.buttons["menuButton"].tap()
        XCTAssertTrue(app.navigationBars["Menu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Vocabulary"].exists); XCTAssertTrue(app.buttons["Identity"].exists)
        let menu = XCTAttachment(screenshot: app.screenshot()); menu.name = "Menu"; menu.lifetime = .keepAlways; add(menu)
        app.buttons["Vocabulary"].tap()
        XCTAssertTrue(app.buttons["Add correction"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Identity"].tap()
        XCTAssertTrue(app.secureTextFields["Paste nsec"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["Create PIN (4–12 digits)"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout: 10))
    }
}

extension RecorderSmokeTests {
    func testSyntheticTranscriptWordCorrectionAndRawRetention() {
        let app = XCUIApplication(); app.launchArguments = ["--synthetic-review"]; app.launch()
        XCTAssertTrue(app.buttons["menuButton"].waitForExistence(timeout: 10)); app.buttons["menuButton"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic transcript review")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Recording"].waitForExistence(timeout: 5))
        let transcript = app.textViews.firstMatch
        app.swipeUp()
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        // First linked word: tap near the beginning of native text, never microphone capture.
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 25, dy: 17)).tap()
        XCTAssertTrue(app.navigationBars["Correct word"].waitForExistence(timeout: 5))
        let field = app.textFields["Replacement"]; field.tap()
        field.press(forDuration: 1)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap(); field.typeText("nostr") }
        else { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "nostr") }
        app.buttons["Apply"].tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertTrue((transcript.value as? String)?.contains("nostr, 123. nosta!") == true)
        app.buttons["Original transcript"].tap()
        XCTAssertTrue(app.staticTexts["nosta, 123. nosta!"].exists)
        XCTAssertFalse(app.navigationBars["Edit transcript"].exists)
        XCTAssertTrue(app.navigationBars["Recording"].exists)
        let review = XCTAttachment(screenshot: app.screenshot()); review.name = "Synthetic word correction retains original"; review.lifetime = .keepAlways; add(review)
    }
}

extension RecorderSmokeTests {
    func testNStackSetupAndHistoryWithoutSecretsOrCapture() {
        let app = XCUIApplication(); app.launchArguments = ["--synthetic-review"]; app.launch()
        XCTAssertTrue(app.buttons["menuButton"].waitForExistence(timeout:10)); app.buttons["menuButton"].tap()
        app.buttons["NStack"].tap()
        XCTAssertTrue(app.navigationBars["NStack"].waitForExistence(timeout:5))
        XCTAssertTrue(app.textFields["https://your-nstack.example"].exists)
        XCTAssertFalse(app.buttons["Discover workspaces"].isEnabled)
        let setup = XCTAttachment(screenshot:app.screenshot()); setup.name = "NStack setup locked identity"; setup.lifetime = .keepAlways; add(setup)
        app.navigationBars.buttons.element(boundBy:0).tap(); app.buttons["NStack uploads"].tap()
        XCTAssertTrue(app.navigationBars["NStack uploads"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["No uploads yet. Configure NStack or use Upload on a saved recording."].exists)
        let history = XCTAttachment(screenshot:app.screenshot()); history.name = "NStack upload history"; history.lifetime = .keepAlways; add(history)
    }
}
