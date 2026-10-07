import XCTest

@MainActor
final class CodexUsageViewerUITests: XCTestCase {
    private func visibleText(_ element: XCUIElement) -> String {
        // Native AXStaticText exposes its displayed string as value on macOS.
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }
    private func launch(connected: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (connected ? ["--ui-testing-connected"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["codexusageviewer.title"].waitForExistence(timeout: 10))
        return app
    }

    func testThreeEmptyAccountsAndHonestPreview() {
        let app = launch()
        defer { app.terminate() }

        for index in 1...3 {
            XCTAssertTrue(app.buttons["codexusageviewer.connect.account-\(index)"].exists)
        }
        XCTAssertTrue(app.staticTexts["0 of 3 connected"].exists)

        app.buttons["codexusageviewer.preview"].click()
        let previewBanner = app.descendants(matching: .any).matching(identifier: "codexusageviewer.preview.banner").firstMatch
        XCTAssertTrue(previewBanner.waitForExistence(timeout: 3))
        for name in ["Alex Morgan", "Sam Rivera", "Jordan Lee"] {
            XCTAssertTrue(app.staticTexts[name].exists)
        }
        XCTAssertTrue(previewBanner.label.contains("sample accounts and usage figures"))
        for (index, percent) in [72, 36, 88].enumerated() {
            let usage = app.descendants(matching: .any).matching(identifier: "codexusageviewer.usage.account-\(index + 1)").firstMatch
            XCTAssertTrue(usage.label.contains("\(percent) percent remaining"))
        }
        XCTAssertFalse(app.buttons["codexusageviewer.refresh"].isEnabled)

        app.buttons["codexusageviewer.preview"].click()
        XCTAssertTrue(app.staticTexts["0 of 3 connected"].waitForExistence(timeout: 3))
        XCTAssertFalse(previewBanner.exists)
        for index in 1...3 {
            XCTAssertTrue(app.buttons["codexusageviewer.connect.account-\(index)"].exists)
        }
    }

    func testSettingsWithPointerAndEscape() {
        let app = launch()
        defer { app.terminate() }

        app.buttons["codexusageviewer.settings"].click()
        let field = app.textFields["codexusageviewer.settings.executable"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        let originalValue = field.value as? String ?? ""
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("/tmp/codexusageviewer-ui-test-unused-codex")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["codexusageviewer.settings"].waitForExistence(timeout: 3))
        XCTAssertFalse(field.exists)

        app.buttons["codexusageviewer.settings"].click()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String ?? "", originalValue, "Escape should discard the staged path edit.")
        app.buttons["codexusageviewer.settings.done"].click()
        XCTAssertFalse(field.waitForExistence(timeout: 1))
    }

    func testFullAccountIdentityPlanAndLoggedInBadge() {
        let app = launch(connected: true)
        defer { app.terminate() }

        for (index, name) in ["Alex Morgan", "Sam Rivera", "Jordan Lee"].enumerated() {
            let title = app.staticTexts["codexusageviewer.name.account-\(index + 1)"]
            XCTAssertEqual(visibleText(title), name)
        }
        let plan = app.descendants(matching: .any).matching(identifier: "codexusageviewer.plan.account-1").firstMatch
        let badge = app.descendants(matching: .any).matching(identifier: "codexusageviewer.loggedIn.account-1").firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 3))
        XCTAssertTrue(badge.waitForExistence(timeout: 3))
        XCTAssertTrue(visibleText(plan).contains("Pro"))
        XCTAssertEqual(badge.label, "Logged In")
        XCTAssertTrue(plan.isHittable)
        XCTAssertTrue(badge.isHittable)

        let options = app.descendants(matching: .any).matching(identifier: "codexusageviewer.options.account-1").firstMatch
        options.click()
        XCTAssertTrue(app.menuItems["All usage limits"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["Rename account"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testVersionInDashboardAndStandardQuitMenu() {
        let app = launch()
        defer { app.terminate() }
        let version = app.staticTexts["codexusageviewer.version"]
        let versionText = visibleText(version)
        XCTAssertTrue(versionText == "Version 1.0" || versionText.hasPrefix("Version 1.0-"))
        for text in ["CODEX USAGE, IN ONE PLACE", "A little more headspace.", "Three accounts. A clear view of what’s left.", "YOUR ACCOUNTS"] {
            XCTAssertFalse(app.staticTexts[text].exists)
        }
        let appMenu = app.menuBars.menuBarItems["Codex Usage Viewer"]
        XCTAssertTrue(appMenu.exists)
        appMenu.click()
        let displayedVersion = String(versionText.dropFirst("Version ".count))
        let quit = app.menuItems["Quit Codex Usage Viewer \(displayedVersion)"]
        XCTAssertTrue(quit.waitForExistence(timeout: 3))
        quit.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 3))
    }

    func testAllUsageLimitsInPreviewWithPointerAndEscape() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["codexusageviewer.preview"].click()

        let options = app.descendants(matching: .any).matching(identifier: "codexusageviewer.options.account-1").firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 3))
        options.click()
        let allLimits = app.menuItems["All usage limits"]
        XCTAssertTrue(allLimits.waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["Rename account"].exists)
        XCTAssertFalse(app.menuItems["Reconnect"].isEnabled)
        allLimits.click()

        let title = app.staticTexts["codexusageviewer.limits.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Codex"].exists)
        XCTAssertTrue(app.staticTexts["Sample usage · preview mode"].exists)
        for (window, expected) in [("primary", "72%"), ("secondary", "58%")] {
            let limit = app.descendants(matching: .any).matching(identifier: "codexusageviewer.limit.codex.\(window)").firstMatch
            XCTAssertTrue(limit.label.contains(expected))
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(title.exists)

        options.click()
        allLimits.click()
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        app.buttons["codexusageviewer.limits.done"].click()
        XCTAssertFalse(title.exists)
    }

}
