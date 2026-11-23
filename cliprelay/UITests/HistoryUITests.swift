import XCTest

final class HistoryUITests: XCTestCase {
    @MainActor func testHistoryActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--history-ui-qa", "-AppleLanguages", "(en)", "-setupGuide.dismissed", "YES", "-ui.language", "en"]
        app.launch()

        let draft = app.textFields["New text"]
        if app.buttons["Later"].waitForExistence(timeout: 2) { app.buttons["Later"].tap() }
        XCTAssertTrue(draft.waitForExistence(timeout: 5))

        func add(_ text: String) {
            draft.tap()
            draft.typeText(text)
            app.buttons["Add item"].tap()
        }

        func rowActions(_ prefix: String) -> XCUIElementQuery {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.\(prefix)."))
        }

        add("Original entry")
        let original = rowActions("actions").firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        let id = original.identifier
        add("Recent entry")
        XCTAssertEqual(rowActions("actions").count, 2)
        XCTAssertFalse(rowActions("send").firstMatch.isEnabled)

        app.buttons[id].tap()
        app.buttons["Pin"].tap()
        XCTAssertLessThan(app.staticTexts["Original entry"].frame.minY, app.staticTexts["Recent entry"].frame.minY)
        app.buttons[id].tap()
        app.buttons["Unpin"].tap()
        XCTAssertGreaterThan(app.staticTexts["Original entry"].frame.minY, app.staticTexts["Recent entry"].frame.minY)

        add("Original entry")
        XCTAssertEqual(rowActions("actions").count, 2)
        XCTAssertTrue(app.buttons[id].exists)
        XCTAssertLessThan(app.staticTexts["Original entry"].frame.minY, app.staticTexts["Recent entry"].frame.minY)

        let copyID = id.replacingOccurrences(of: "history.actions.", with: "history.copy.")
        app.buttons[copyID].tap()
        XCTAssertTrue(app.staticTexts["Copied"].waitForExistence(timeout: 3))

        app.buttons[id].tap()
        app.buttons["Preview"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        app.buttons[id].tap()
        app.buttons["Share item"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        app.buttons[id].tap()
        app.buttons["Delete"].tap()
        let confirmation = app.alerts["Delete clipboard item?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons[id].exists)

        app.buttons[id].tap()
        app.buttons["Delete"].tap()
        confirmation.buttons["Delete"].tap()
        XCTAssertFalse(app.buttons[id].exists)
        XCTAssertEqual(rowActions("actions").count, 1)

        let tabs = app.tabBars.firstMatch
        tabs.buttons["Devices"].tap()
        XCTAssertTrue(app.buttons["Show pairing code"].waitForExistence(timeout: 3))
        app.buttons["Show pairing code"].tap()
        let cancelInvitation = app.buttons["Cancel invitation"]
        for _ in 0..<3 where !cancelInvitation.isHittable { app.swipeUp() }
        XCTAssertTrue(cancelInvitation.waitForExistence(timeout: 3))
        app.buttons["Cancel invitation"].tap()
        XCTAssertFalse(app.buttons["Cancel invitation"].exists)

        let sync = app.buttons["Sync now"]
        for _ in 0..<6 where !sync.isHittable { app.swipeUp() }
        XCTAssertTrue(sync.waitForExistence(timeout: 3))
        XCTAssertFalse(sync.isEnabled, "Syncing requires a paired device")
        XCTAssertFalse(app.staticTexts["Pending"].exists)

        tabs.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Setup guide"].waitForExistence(timeout: 3))
        app.buttons["Setup guide"].tap()
        XCTAssertTrue(app.buttons["Later"].waitForExistence(timeout: 3))
        app.buttons["Later"].tap()
        XCTAssertTrue(app.buttons["Setup guide"].waitForExistence(timeout: 3))
    }
    @MainActor func testMobileHistoryAndPrivacy() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--history-ui-qa", "--fixture-history", "-AppleLanguages", "(en)", "-setupGuide.dismissed", "YES", "-ui.language", "en"]
        app.launch()
        let tabs = app.tabBars.firstMatch
        tabs.buttons["Settings"].tap()
        app.buttons["Privacy & Security"].tap()
        XCTAssertTrue(app.switches["Lock history"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Save clipboard while app is open"].exists)
        tabs.buttons["History"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("tangerine")
        let actions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history.actions.'"))
        XCTAssertTrue(actions.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(actions.count, 1)
        actions.firstMatch.tap()
        app.buttons["Preview"].tap()
        let burn = app.switches["Delete after copying"]
        XCTAssertTrue(burn.waitForExistence(timeout: 5))
        burn.switches.firstMatch.tap()
        XCTAssertEqual(burn.value as? String, "1")
        app.buttons["history.detail.copy"].tap()
        XCTAssertTrue(actions.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["history.detail.copy"].waitForNonExistence(timeout: 3))
    }

    @MainActor func testChineseWorkspace() {
        let app = XCUIApplication()
        app.launchArguments = ["--history-ui-qa", "--fixture-history", "-AppleLanguages", "(zh-Hans)", "-setupGuide.dismissed", "YES", "-ui.language", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.staticTexts["项目会议纪要 · 周三确认交付时间"].waitForExistence(timeout: 5))
        for (tab, name) in [(0, "history"), (1, "devices"), (2, "settings")] {
            if tab > 0 { app.tabBars.buttons.element(boundBy: tab).tap() }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "ClipRelay-iPhone-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testBatchAndTypeFilter() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--history-ui-qa", "--fixture-history", "-AppleLanguages", "(en)", "-setupGuide.dismissed", "YES", "-ui.language", "en"]
        app.launch()
        app.buttons["Filter"].tap()
        let code = app.switches["Code"]
        XCTAssertTrue(code.waitForExistence(timeout: 3))
        code.switches.firstMatch.tap()
        app.buttons["Done"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history.row.'"))
        XCTAssertEqual(rows.count, 1)
        app.buttons["Select"].tap()
        rows.firstMatch.tap()
        app.buttons["Delete"].tap()
        let confirm = app.alerts["Delete clipboard item?"]
        confirm.buttons["Cancel"].tap()
        XCTAssertEqual(rows.count, 1)
        app.buttons["Delete"].tap()
        confirm.buttons["Delete"].tap()
        XCTAssertTrue(rows.firstMatch.waitForNonExistence(timeout: 5))
    }

}
