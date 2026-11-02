import XCTest

final class FrameLinkUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testNativeBackAndCancelledSwipes() {
        app.launch()
        let cases: [(String, UIDeviceOrientation)] = [
            ("Preview Mode", .portrait), ("Camera Mode", .portrait),
            ("Preview Mode", .landscapeLeft), ("Camera Mode", .landscapeRight)
        ]
        for (mode, orientation) in cases {
            XCUIDevice.shared.orientation = orientation
            openMode(mode)
            capture("\(mode)-\(orientation.rawValue)")

            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
            start.press(forDuration: 0.05,
                        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)),
                        withVelocity: .slow, thenHoldForDuration: 0.5)
            XCTAssertTrue(app.navigationBars[mode].exists, "An incomplete swipe must stay in the mode")
            XCTAssertFalse(app.alerts["Frame Link"].exists, "Cancelling a swipe must not restart the camera")

            start.press(forDuration: 0.05,
                        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            XCTAssertTrue(app.navigationBars[mode].waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["Frame Link"].exists)
            XCTAssertTrue(modeButton(mode).isHittable, "The main menu must be usable after swiping back")

            openMode(mode)
            app.navigationBars[mode].buttons["Frame Link"].tap()
            XCTAssertTrue(app.navigationBars[mode].waitForNonExistence(timeout: 5))
        }
    }

    func testLargeTextCameraLayout() {
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        openMode("Camera Mode")
        XCTAssertTrue(app.buttons["Photo timer"].exists)
        XCTAssertTrue(app.buttons["Recent photos"].isHittable)
        XCTAssertLessThan(app.buttons["Recent photos"].frame.midX, app.buttons["Take photo"].frame.midX,
                          "Large text must not make portrait use the landscape shutter column")
        capture("Camera-accessibility-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        let compact = app.scrollViews["Compact camera layout"]
        XCTAssertTrue(app.buttons["Photo timer"].exists)
        XCTAssertTrue(app.buttons["Recent photos"].isHittable)
        if compact.exists {
            for _ in 0..<2 {
                compact.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.9))
                    .press(forDuration: 0.05, thenDragTo: compact.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.1)))
            }
        }
        XCTAssertLessThanOrEqual(app.buttons["Switch front and rear cameras"].frame.maxY, app.frame.maxY,
                                 "The shutter column must be visible, scrolling if needed")
        capture("Camera-accessibility-landscape")
    }

    private func modeButton(_ mode: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", mode)).firstMatch
    }

    private func openMode(_ mode: String) {
        let button = modeButton(mode)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        for _ in 0..<5 where !button.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        button.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        let errorOK = app.alerts["Frame Link"].buttons["OK"]
        if errorOK.waitForExistence(timeout: 1) { errorOK.tap() }
        XCTAssertTrue(app.navigationBars[mode].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
