import XCTest

/// Walks through the app in demo mode (`-ChelateDemo`, fixture server, no network) and attaches
/// a screenshot of every main screen. CI exports the attachments from the xcresult bundle.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-ChelateDemo"] + extra
        app.launch()
        openOverviewIfNeeded()
    }

    /// On iPhone the split view may start on the server list.
    private func openOverviewIfNeeded() {
        let node = element("node-pve")
        if node.waitForExistence(timeout: 5) { return }
        let overview = app.buttons["总览"].firstMatch
        if overview.exists { overview.tap() }
        XCTAssertTrue(node.waitForExistence(timeout: 15), "overview did not load")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Lets loading finish and animations settle before a screenshot.
    private func settle(_ seconds: TimeInterval = 1.5) {
        let expectation = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { expectation.fulfill() }
        wait(for: [expectation], timeout: seconds + 5)
    }

    private func tap(_ identifier: String, scrolling: Bool = true) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 15), "missing \(identifier)")
        if scrolling {
            var attempts = 0
            while !target.isHittable && attempts < 6 {
                app.swipeUp()
                attempts += 1
            }
        }
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: target)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "\(identifier) is disabled")
        target.tap()
    }

    private func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
    }

    func testScreenshots() {
        launch()
        settle()
        snapshot("01-overview")

        tap("node-pve")
        XCTAssertTrue(app.staticTexts["PVE"].waitForExistence(timeout: 10))
        settle()
        snapshot("02-node-detail")

        tap("node-charts")
        XCTAssertTrue(element("chart-cpu").waitForExistence(timeout: 10))
        settle(2)
        snapshot("03-node-monitor")
        // Exercise the long-press + drag selection gesture once.
        let chart = element("chart-memory")
        if chart.waitForExistence(timeout: 5) {
            let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            let end = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            start.press(forDuration: 0.6, thenDragTo: end)
        }
        goBack()

        tap("node-tasks")
        XCTAssertTrue(element("task-row").waitForExistence(timeout: 10))
        settle()
        snapshot("09-tasks")
        goBack()
        goBack()

        tap("guest-100")
        XCTAssertTrue(element("guest-charts").waitForExistence(timeout: 10))
        settle()
        snapshot("05-guest-detail")
        goBack()

        tap("storage-local")
        XCTAssertTrue(element("storage-download-url").waitForExistence(timeout: 10))
        settle()
        snapshot("06-storage-detail")

        tap("storage-download-url", scrolling: false)
        XCTAssertTrue(element("download-filename-field").waitForExistence(timeout: 10))
        settle(2.5) // metadata lookup is debounced
        snapshot("07-download-url")
        app.buttons["取消"].firstMatch.tap()
        settle(1)

        tap("storage-templates", scrolling: false)
        XCTAssertTrue(app.staticTexts["Debian 13 (standard)"].waitForExistence(timeout: 10))
        settle()
        snapshot("08-templates")
        app.buttons["关闭"].firstMatch.tap()
    }

    /// Long-press popover on the node CPU chart (selection pinned by the demo launch argument,
    /// since a screenshot cannot be taken while XCUITest holds a gesture).
    func testChartSelectionScreenshot() {
        launch(["-ChelateDemoChartSelection"])
        tap("node-pve")
        tap("node-charts")
        XCTAssertTrue(element("chart-cpu").waitForExistence(timeout: 10))
        settle(2)
        snapshot("04-node-monitor-selection")
    }
}
