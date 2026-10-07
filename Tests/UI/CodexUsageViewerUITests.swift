import XCTest

@MainActor
final class CodexUsageViewerUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["A little more headspace."].waitForExistence(timeout: 10))
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
        for name in ["Personal", "Studio", "Projects"] {
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

    func testRenameThroughNativeMenuAndKeyboard() {
        let app = launch()
        defer { app.terminate() }

        openRename(in: app, account: "account-1")
        let nameField = app.textFields["codexusageviewer.rename.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("My studio")
        nameField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["My studio"].waitForExistence(timeout: 3))
        XCTAssertFalse(nameField.exists)

        openRename(in: app, account: "account-1")
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("Discard me")
        nameField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["My studio"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Discard me"].exists)
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
        XCTAssertFalse(app.menuItems["Rename account"].isEnabled)
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

    private func openRename(in app: XCUIApplication, account: String) {
        let options = app.descendants(matching: .any).matching(identifier: "codexusageviewer.options.\(account)").firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 3))
        options.click()
        let rename = app.menuItems["Rename account"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        rename.click()
    }
}
