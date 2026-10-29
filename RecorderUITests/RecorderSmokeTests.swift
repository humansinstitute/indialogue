import XCTest
final class RecorderSmokeTests: XCTestCase {
    func testMinimalHomeAndMenuNavigationWithoutCapture() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.navigationBars["In Dialogue"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["recordButton"].exists)
        XCTAssertTrue(app.buttons["microphoneControl"].exists)
        XCTAssertTrue(app.segmentedControls["dialogueMode"].exists)
        XCTAssertFalse(app.buttons["routeSettings"].exists)
        XCTAssertTrue(app.buttons["recordButton"].label.contains("New recording"))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@", "Use only when it is safe")).firstMatch.exists)
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
    func testConversationUsesLargeStatusAndRecordControlsWithoutRecipientHeadline() {
        let app = XCUIApplication(); app.launchArguments = ["--synthetic-conversation"]; app.launch()
        XCTAssertTrue(app.otherElements["recentConversations"].waitForExistence(timeout:10))
        let statusButtons = app.buttons.matching(identifier:"conversationPlayStatus")
        let recordButtons = app.buttons.matching(identifier:"conversationRecord")
        XCTAssertEqual(statusButtons.count,2)
        XCTAssertEqual(recordButtons.count,2)
        XCTAssertGreaterThan(statusButtons.element(boundBy:0).frame.width,100)
        XCTAssertGreaterThan(recordButtons.element(boundBy:0).frame.width,100)
        XCTAssertFalse(app.staticTexts["Rick"].exists)
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "Large conversation play and record controls"; shot.lifetime = .keepAlways; add(shot)
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


extension RecorderSmokeTests {
    func testSyntheticUnlockSwitchingManualLockAndColdLaunch() {
        let app = XCUIApplication(); app.launchArguments = ["--synthetic-review", "--synthetic-unlock"]; app.launch()
        let unlock = app.buttons["identityUnlockButton"]
        XCTAssertTrue(unlock.waitForExistence(timeout:10))
        XCTAssertTrue(app.secureTextFields["identityUnlockPIN"].exists)
        XCTAssertFalse(app.secureTextFields["Paste nsec"].exists)
        let locked = XCTAttachment(screenshot:app.screenshot()); locked.name = "Focused foreground identity unlock"; locked.lifetime = .keepAlways; add(locked)
        app.buttons["Continue locked"].tap()
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout:5))
        app.buttons["menuButton"].tap(); app.buttons["Vocabulary"].tap()
        XCTAssertFalse(unlock.exists)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(unlock.waitForExistence(timeout:10))
        let pin = app.secureTextFields["identityUnlockPIN"]; pin.tap(); pin.typeText("999999"); unlock.tap()
        XCTAssertTrue(app.staticTexts["Incorrect PIN or damaged identity vault. Existing identity has been retained."].waitForExistence(timeout:5))
        pin.tap(); pin.typeText("123456"); unlock.tap()
        XCTAssertFalse(unlock.waitForExistence(timeout:2))
        XCTAssertTrue(app.buttons["menuButton"].waitForExistence(timeout:5))
        app.buttons["menuButton"].tap(); app.buttons["Identity"].tap()
        XCTAssertTrue(app.staticTexts["Imported identity · unlocked"].waitForExistence(timeout:5))
        let opened = XCTAttachment(screenshot:app.screenshot()); opened.name = "Synthetic identity authenticated"; opened.lifetime = .keepAlways; add(opened)
        app.navigationBars.buttons.element(boundBy:0).tap(); app.buttons["Vocabulary"].tap()
        app.navigationBars.buttons.element(boundBy:0).tap(); app.buttons["Identity"].tap()
        XCTAssertTrue(app.staticTexts["Imported identity · unlocked"].exists)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.staticTexts["Imported identity · unlocked"].waitForExistence(timeout:10))
        XCTAssertFalse(unlock.exists)
        app.buttons["Lock"].tap()
        XCTAssertTrue(app.staticTexts["Imported identity · locked"].waitForExistence(timeout:5))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(unlock.waitForExistence(timeout:10))
        let manualPIN = app.secureTextFields["identityUnlockPIN"]; manualPIN.tap(); manualPIN.typeText("123456"); unlock.tap()
        XCTAssertTrue(app.buttons["menuButton"].waitForExistence(timeout:5))
        app.terminate(); app.launch()
        XCTAssertTrue(unlock.waitForExistence(timeout:10))
    }
}

extension RecorderSmokeTests {
    func testSyntheticMeterWithoutMicrophoneCapture() {
        let app = XCUIApplication(); app.launchArguments = ["--synthetic-meter"]; app.launch()
        XCTAssertTrue(app.otherElements["captureLevelHistory"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["microphoneControl"].label.contains("Synthetic microphone"))
        XCTAssertFalse(app.alerts["Recorder notice"].exists)
        app.buttons["microphoneControl"].tap()
        XCTAssertTrue(app.navigationBars["Microphone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Actual current route"].exists)
        XCTAssertTrue(app.buttons["System default"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "If iOS substitutes another input")).firstMatch.exists)
        app.buttons["Done"].tap()
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Synthetic live recording levels"; image.lifetime = .keepAlways; add(image)
    }
}

extension RecorderSmokeTests {
    func testRetentionSettingsValidationAndSaveWithoutUserLibrary() {
        let app = XCUIApplication(); app.launchArguments = ["--synthetic-retention"]; app.launch()
        XCTAssertTrue(app.buttons["menuButton"].waitForExistence(timeout: 10)); app.buttons["menuButton"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Saved: automatic deletion is off."].waitForExistence(timeout: 5))
        let toggle = app.switches["retentionEnabled"]
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let days = app.textFields["retentionDays"]; days.tap()
        days.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "0")
        app.buttons["saveRetention"].tap()
        XCTAssertTrue(app.staticTexts["Enter a whole number of days from 1 to 3650."].waitForExistence(timeout: 5))
        days.tap(); days.typeText(XCUIKeyboardKey.delete.rawValue + "7")
        app.buttons["saveRetention"].tap()
        XCTAssertTrue(app.staticTexts["Saved: delete after 7 days."].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Retention Settings"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["Settings"].buttons["BackButton"].tap(); app.buttons["Settings"].tap()
        XCTAssertEqual(days.value as? String, "7")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Deletes local recordings, audio, transcripts and finished local upload copies. Uploaded workspace copies remain."].exists)
    }
}

extension RecorderSmokeTests {
    func testReplyVoiceSelectorAndPreviewWithoutCapture() {
        let app = XCUIApplication(); app.launchArguments = ["--synthetic-review"]; app.launch()
        XCTAssertTrue(app.buttons["menuButton"].waitForExistence(timeout: 10))
        app.buttons["menuButton"].tap()
        app.buttons["Reply voice"].tap()
        XCTAssertTrue(app.navigationBars["Reply voice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["replyVoicePicker"].exists)
        XCTAssertTrue(app.buttons["previewReplyVoice"].isEnabled)
        app.buttons["previewReplyVoice"].tap()
        app.buttons["Stop preview"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Native reply voice settings"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["replyVoicePicker"].tap()
        XCTAssertTrue(app.buttons["System Default"].waitForExistence(timeout: 5))
        app.buttons["System Default"].tap()
    }
}


extension RecorderSmokeTests {
    func testManualDiagnosticsWithoutSetupShowsVisibleFailureWithoutCapture() {
        let app = XCUIApplication(); app.launchArguments = ["--synthetic-retention"]; app.launch()
        XCTAssertTrue(app.buttons["menuButton"].waitForExistence(timeout:10)); app.buttons["menuButton"].tap()
        let send = app.buttons["sendDiagnostics"]
        for _ in 0..<3 where !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isHittable); send.tap()
        XCTAssertTrue(app.staticTexts["diagnosticsNotice"].waitForExistence(timeout:5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Diagnostics sent")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot:app.screenshot()); screenshot.name = "Manual diagnostics setup notice"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
