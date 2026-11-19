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
        XCTAssertTrue(app.buttons["Cancel invitation"].waitForExistence(timeout: 3))
        app.buttons["Cancel invitation"].tap()
        XCTAssertFalse(app.buttons["Cancel invitation"].exists)

        let sync = app.buttons["Sync now"]
        for _ in 0..<4 where !sync.isHittable { app.swipeUp() }
        XCTAssertTrue(sync.isHittable)
        sync.tap()
        let syncSummary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "↑ ")).firstMatch
        XCTAssertFalse(syncSummary.waitForExistence(timeout: 2))

        tabs.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Setup guide"].waitForExistence(timeout: 3))
        app.buttons["Setup guide"].tap()
        XCTAssertTrue(app.buttons["Later"].waitForExistence(timeout: 3))
        app.buttons["Later"].tap()
        XCTAssertTrue(app.buttons["Setup guide"].waitForExistence(timeout: 3))
    }
}
