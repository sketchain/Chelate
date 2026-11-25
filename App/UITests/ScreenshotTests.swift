import XCTest

/// Walks through the app in demo mode (`-ChelateDemo`, fixture server, no network) and attaches
/// a screenshot of every main screen. CI exports the attachments from the xcresult bundle.
///
/// The screens are split into small test classes, each with a light and a dark subclass, so CI
/// can spread them over parallel simulator clones (`-parallel-testing-enabled`).
class ScreenshotTestCase: XCTestCase {
    var app: XCUIApplication!

    /// Overridden by the dark subclasses.
    var appearance: XCUIDevice.Appearance { .light }

    /// Light / dark suffix appended to every screenshot name.
    var appearanceSuffix: String { appearance == .dark ? "dark" : "light" }

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    /// Runs `body` in this class's appearance (system appearance, so sheets and dialogs follow
    /// too); screenshot names get a "-light" / "-dark" suffix.
    func inAppearance(_ body: () -> Void) {
        XCUIDevice.shared.appearance = appearance
        body()
        app.terminate()
    }

    func launch(_ extra: [String] = [], openOverview: Bool = true) {
        app = XCUIApplication()
        app.launchArguments = ["-ChelateDemo"] + extra
        app.launch()
        if openOverview { openOverviewIfNeeded() }
    }

    /// On iPhone the app starts on the home screen (server list).
    func openOverviewIfNeeded() {
        let node = element("node-pve")
        let overview = app.buttons["总览"].firstMatch
        if overview.waitForExistence(timeout: 10), !node.exists { overview.tap() }
        XCTAssertTrue(node.waitForExistence(timeout: 15), "overview did not load")
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)-\(appearanceSuffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Lets loading finish and animations settle before a screenshot.
    func settle(_ seconds: TimeInterval = 1.5) {
        let expectation = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { expectation.fulfill() }
        wait(for: [expectation], timeout: seconds + 5)
    }

    func tap(_ identifier: String, scrolling: Bool = true) {
        let target = element(identifier)
        // Rows of long lists only exist once scrolled into view.
        if scrolling && !target.waitForExistence(timeout: 5) {
            var attempts = 0
            while !target.exists && attempts < 6 {
                app.swipeUp()
                attempts += 1
            }
        }
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

    func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
    }
}

class WalkthroughScreenshots: ScreenshotTestCase {
    func testScreenshots() {
        inAppearance(walkthrough)
    }

    func walkthrough() {
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

        // Tap a row in the middle: the confirmation dialog is anchored on that row.
        let rows = app.descendants(matching: .any).matching(identifier: "template-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let hittable = rows.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(hittable.isEmpty, "no visible template rows")
        hittable[hittable.count / 2].tap()
        XCTAssertTrue(app.buttons["复制下载链接"].waitForExistence(timeout: 10), "template dialog did not open")
        settle()
        snapshot("08-templates-dialog")
    }
}

final class WalkthroughScreenshotsDark: WalkthroughScreenshots {
    override var appearance: XCUIDevice.Appearance { .dark }
}

class HomeScreenshots: ScreenshotTestCase {
    /// Home (server list) after the title's highlight sweep has finished. iPhone launches on it.
    /// Also checks the title position: its top should be about 20 pt below the top of the safe
    /// area (the top of the navigation bar on the next screen).
    func testHomeScreenshot() {
        inAppearance {
            launch(openOverview: false)
            let title = element("home-title")
            XCTAssertTrue(title.waitForExistence(timeout: 10), "app did not launch on the home screen")
            XCTAssertFalse(element("node-pve").exists, "app should not open the overview on launch")
            settle(2.5) // the sweep runs once for about 1 s
            snapshot("00-home")

            // The identifier can also surface on the containing list cell; use the tightest
            // match, which is the title text itself.
            let matches = app.descendants(matching: .any).matching(identifier: "home-title").allElementsBoundByIndex
            let titleTop = (matches.min { $0.frame.height < $1.frame.height } ?? title).frame.minY
            app.buttons["总览"].firstMatch.tap()
            let bar = app.navigationBars.firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 10))
            let gap = titleTop - bar.frame.minY
            let note = XCTAttachment(string: "home title top \(titleTop), safe area top \(bar.frame.minY), gap \(gap)")
            note.name = "home-title-gap-\(appearanceSuffix)"
            note.lifetime = .keepAlways
            add(note)
            XCTAssertGreaterThanOrEqual(gap, 14, "home title too high (\(gap) pt)")
            XCTAssertLessThanOrEqual(gap, 26, "home title too low (\(gap) pt)")
        }
    }
}

final class HomeScreenshotsDark: HomeScreenshots {
    override var appearance: XCUIDevice.Appearance { .dark }
}

class SettingsScreenshots: ScreenshotTestCase {
    /// Settings, a server's settings and (demo only) the widget gallery.
    func testSettingsScreenshots() {
        inAppearance {
            launch(openOverview: false)
            tap("home-settings")
            XCTAssertTrue(element("settings-auto-refresh").waitForExistence(timeout: 10), "settings did not open")
            settle()
            snapshot("10-settings")

            tap("settings-server-Homelab")
            XCTAssertTrue(element("server-fingerprint").waitForExistence(timeout: 10), "server settings did not open")
            settle()
            snapshot("11-server-settings")
            goBack()

            tap("settings-widget-gallery")
            XCTAssertTrue(element("widget-gallery").waitForExistence(timeout: 10), "widget gallery did not open")
            settle()
            snapshot("12-widget-gallery")
        }
    }
}

final class SettingsScreenshotsDark: SettingsScreenshots {
    override var appearance: XCUIDevice.Appearance { .dark }
}

class ChartSelectionScreenshots: ScreenshotTestCase {
    /// Long-press popover on the node CPU chart (selection pinned by the demo launch argument,
    /// since a screenshot cannot be taken while XCUITest holds a gesture).
    func testChartSelectionScreenshot() {
        inAppearance {
            launch(["-ChelateDemoChartSelection"])
            tap("node-pve")
            tap("node-charts")
            XCTAssertTrue(element("chart-cpu").waitForExistence(timeout: 10))
            settle(2)
            snapshot("04-node-monitor-selection")
        }
    }
}

final class ChartSelectionScreenshotsDark: ChartSelectionScreenshots {
    override var appearance: XCUIDevice.Appearance { .dark }
}

class WizardScreenshots: ScreenshotTestCase {
    func nextStep() {
        let next = app.buttons["wizard-next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: next)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "next step is disabled")
        next.tap()
        settle(1)
    }

    /// Create VM wizard: general, OS, system, disks and the confirm page.
    func testVMWizardScreenshots() {
        inAppearance {
            launch()
            tap("overview-menu", scrolling: false)
            app.buttons["新建虚拟机"].firstMatch.tap()
            XCTAssertTrue(element("wizard-step-0").waitForExistence(timeout: 10), "VM wizard did not open")
            settle(2)
            snapshot("13-vm-wizard-general")
            nextStep()
            let noMedia = app.buttons["不使用任何介质"].firstMatch
            if noMedia.waitForExistence(timeout: 5) { noMedia.tap() }
            settle()
            snapshot("13-vm-wizard-os")
            nextStep()
            snapshot("13-vm-wizard-system")
            nextStep()
            snapshot("13-vm-wizard-disks")
            nextStep() // CPU
            nextStep() // memory
            nextStep() // network
            nextStep() // confirm
            XCTAssertTrue(app.buttons["wizard-create"].waitForExistence(timeout: 10), "confirm page missing")
            snapshot("13-vm-wizard-confirm")
        }
    }

    /// Create CT wizard: general, template, disks and the confirm page.
    func testCTWizardScreenshots() {
        inAppearance {
            launch()
            tap("overview-menu", scrolling: false)
            app.buttons["新建容器"].firstMatch.tap()
            XCTAssertTrue(element("wizard-step-0").waitForExistence(timeout: 10), "CT wizard did not open")
            settle(2)
            let password = app.secureTextFields["密码"].firstMatch
            XCTAssertTrue(password.waitForExistence(timeout: 5))
            password.tap()
            password.typeText("demo-password")
            let confirm = app.secureTextFields["确认密码"].firstMatch
            confirm.tap()
            confirm.typeText("demo-password")
            snapshot("14-ct-wizard-general")
            nextStep()
            let picker = app.buttons["模板"].firstMatch
            if picker.waitForExistence(timeout: 5) {
                picker.tap()
                let item = app.buttons["debian-13-standard_13.1-2_amd64.tar.zst"].firstMatch
                if item.waitForExistence(timeout: 5) { item.tap() }
            }
            settle()
            snapshot("14-ct-wizard-template")
            nextStep()
            snapshot("14-ct-wizard-disks")
            nextStep() // CPU
            nextStep() // memory
            nextStep() // network
            nextStep() // DNS
            nextStep() // confirm
            XCTAssertTrue(app.buttons["wizard-create"].waitForExistence(timeout: 10), "confirm page missing")
            snapshot("14-ct-wizard-confirm")
        }
    }
}

final class WizardScreenshotsDark: WizardScreenshots {
    override var appearance: XCUIDevice.Appearance { .dark }
}

class GuestManagementScreenshots: ScreenshotTestCase {
    func cancelSheet() {
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        settle(1)
    }

    /// Backups, backup now, restore, clone, migrate, remove and the hardware page.
    func testGuestManagementScreenshots() {
        inAppearance {
            launch()
            tap("guest-100")
            XCTAssertTrue(element("guest-charts").waitForExistence(timeout: 10))
            tap("backup-row")
            XCTAssertTrue(element("restore-start").waitForExistence(timeout: 10), "restore form did not open")
            settle(2)
            snapshot("17-restore")
            cancelSheet()
            snapshot("15-backups")

            tap("backup-now")
            XCTAssertTrue(element("backup-start").waitForExistence(timeout: 10), "backup form did not open")
            settle(2)
            snapshot("16-backup-now")
            cancelSheet()

            tap("guest-clone")
            XCTAssertTrue(element("clone-start").waitForExistence(timeout: 10), "clone form did not open")
            settle(2)
            snapshot("18-clone")
            cancelSheet()

            tap("guest-migrate")
            XCTAssertTrue(element("migrate-start").waitForExistence(timeout: 10), "migrate form did not open")
            settle(2)
            snapshot("19-migrate")
            cancelSheet()

            app.swipeDown()
            app.swipeDown()
            tap("guest-hardware")
            XCTAssertTrue(element("hardware-edit-cpu").waitForExistence(timeout: 10), "hardware page did not open")
            settle()
            snapshot("21-hardware")
            goBack()
            goBack()

            tap("guest-201")
            XCTAssertTrue(element("guest-charts").waitForExistence(timeout: 10))
            tap("guest-destroy")
            XCTAssertTrue(element("destroy-confirmation").waitForExistence(timeout: 10), "remove form did not open")
            settle()
            snapshot("20-destroy")
        }
    }
}

final class GuestManagementScreenshotsDark: GuestManagementScreenshots {
    override var appearance: XCUIDevice.Appearance { .dark }
}

class NodeAndDatacenterScreenshots: ScreenshotTestCase {
    /// System log, updates, the datacenter page and its firewall.
    func testNodeAndDatacenterScreenshots() {
        inAppearance {
            launch()
            tap("node-pve")
            tap("node-syslog")
            XCTAssertTrue(element("syslog-list").waitForExistence(timeout: 10), "system log did not open")
            settle(2)
            snapshot("22-syslog")
            goBack()

            tap("node-updates")
            XCTAssertTrue(element("apt-package").waitForExistence(timeout: 10), "updates did not open")
            settle()
            snapshot("23-updates")
            app.terminate()

            launch(openOverview: false)
            tap("home-datacenter")
            XCTAssertTrue(element("datacenter-firewall").waitForExistence(timeout: 15), "datacenter did not open")
            settle(2)
            snapshot("24-datacenter")
            tap("datacenter-firewall")
            XCTAssertTrue(element("firewall-enable").waitForExistence(timeout: 10), "firewall did not open")
            settle()
            snapshot("25-firewall")
        }
    }
}

final class NodeAndDatacenterScreenshotsDark: NodeAndDatacenterScreenshots {
    override var appearance: XCUIDevice.Appearance { .dark }
}
