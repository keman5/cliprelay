import XCTest
import UIKit

final class HistoryUITests: XCTestCase {
    @MainActor func testKeyboardCapturesCopiedURL() {
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        func named(_ labels: [String], in app: XCUIApplication) -> XCUIElement {
            app.cells.staticTexts.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        }
        func open(_ labels: [String]) {
            let item = named(labels, in: settings)
            for _ in 0..<6 where !item.isHittable { settings.swipeUp() }
            XCTAssertTrue(item.isHittable, settings.debugDescription)
            item.tap()
        }
        open(["General", "通用"])
        open(["Keyboard", "键盘"])
        let keyboards = settings.cells["KEYBOARDS"]
        for _ in 0..<6 where !settings.frame.contains(CGPoint(x: keyboards.frame.midX, y: keyboards.frame.midY)) {
            settings.swipeDown()
        }
        XCTAssertTrue(keyboards.isHittable)
        keyboards.tap()
        let extensionName = ["ClipRelay", "随贴"]
        if !named(extensionName, in: settings).exists {
            settings.cells["AddNewKeyboard"].tap()
            open(extensionName)
        }
        open(extensionName)
        let fullAccess = settings.switches.matching(NSPredicate(format: "label IN %@", ["Allow Full Access", "允许完全访问"])).firstMatch
        XCTAssertTrue(fullAccess.waitForExistence(timeout: 5))
        if fullAccess.value as? String != "1" {
            fullAccess.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let allow = settings.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许"])).firstMatch
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        }
        XCTAssertEqual(fullAccess.value as? String, "1")

        let app = XCUIApplication()
        app.launchArguments = ["--history-ui-qa", "-AppleLanguages", "(en)", "-setupGuide.dismissed", "YES", "-ui.language", "en"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Keyboard preferences"].tap()
        let capture = app.switches["Automatically save copied text and links"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        let manual = ProcessInfo.processInfo.environment["CLIPRELAY_KEYBOARD_MANUAL"] == "1"
        let captureValue = manual ? "0" : "1"
        if capture.value as? String != captureValue { capture.switches.firstMatch.tap() }
        XCTAssertEqual(capture.value as? String, captureValue)
        app.tabBars.buttons["History"].tap()
        app.textFields["New text"].tap()
        let globe = app.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@", ["Next keyboard", "Globe", "下一个键盘", "切换键盘"]
        )).firstMatch
        let clipboardTab = app.buttons.matching(NSPredicate(format: "label IN %@", ["Clipboard", "剪贴板"])).firstMatch
        if !clipboardTab.exists {
            XCTAssertTrue(globe.waitForExistence(timeout: 5))
            globe.press(forDuration: 0.8)
            let keyboard = app.cells.matching(NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "ClipRelay", "随贴"
            )).firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            keyboard.tap()
        }
        XCTAssertTrue(clipboardTab.waitForExistence(timeout: 5))
        let suffix = UUID().uuidString.prefix(8)
        let url = URL(string: "https://example.com/keyboard?test=\(suffix)#clipboard")!
        UIPasteboard.general.setItems([["public.url": url]], options: [.localOnly: true])
        allowPasteIfAsked()
        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", url.absoluteString)).firstMatch
        if manual || !saved.waitForExistence(timeout: 3) {
            let paste = app.descendants(matching: .any)["keyboard.paste"].firstMatch
            XCTAssertTrue(paste.waitForExistence(timeout: 5))
            paste.tap()
        }
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
    }

    @MainActor func testSafariCopyLink() throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["CLIPRELAY_SAFARI_URL"])
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let app = openClipboardHistory()
        let enable = app.buttons["Enable automatic saving"]
        if enable.waitForExistence(timeout: 2) { enable.tap() }
        safari.open(try XCTUnwrap(URL(string: fixture)))

        let link = safari.links["ClipRelay test link"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.press(forDuration: 1.3)
        let copy = safari.buttons.matching(NSPredicate(format: "label IN %@", ["Copy Link", "拷贝链接", "复制链接"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        app.activate()
        allowPasteIfAsked()
        XCTAssertTrue(app.staticTexts[fixture + "?copied=link#history"].waitForExistence(timeout: 8))
    }

    @MainActor func testSafariCopyAddress() throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["CLIPRELAY_SAFARI_URL"])
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let app = openClipboardHistory()
        let enable = app.buttons["Enable automatic saving"]
        if enable.waitForExistence(timeout: 2) { enable.tap() }

        let addressURL = fixture + "?copied=address#history"
        let page = try XCTUnwrap(URL(string: addressURL))
        func copyAddress() {
            safari.open(page)
            XCTAssertTrue(safari.links["ClipRelay test link"].waitForExistence(timeout: 5))
            let address = safari.textFields.matching(NSPredicate(
                format: "identifier IN %@", ["URL", "TabBarItemTitle"]
            )).firstMatch
            if address.exists {
                address.press(forDuration: 1.2)
            } else {
                safari.coordinate(withNormalizedOffset: CGVector(dx: 0.54, dy: 0.93)).press(forDuration: 1.2)
            }
            let copy = safari.descendants(matching: .any).matching(
                NSPredicate(format: "label IN %@", ["Copy", "拷贝", "复制"])
            ).firstMatch
            XCTAssertTrue(copy.waitForExistence(timeout: 6))
            copy.tap()
        }
        copyAddress()
        app.activate()
        allowPasteIfAsked()
        let rows = clipboardRows(in: app, startingWith: addressURL)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8))
        let removedID = deleteClipboardRow(rows.firstMatch, in: app)
        safari.activate()
        app.activate()
        let unexpectedReturn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                                         object: rows.firstMatch)
        unexpectedReturn.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedReturn], timeout: 2), .completed)

        copyAddress()
        app.activate()
        allowPasteIfAsked()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8), "Copying the same Safari address again should restore it to history")
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotEqual(rows.firstMatch.identifier, removedID)
    }

    @MainActor private func clipboardRows(in app: XCUIApplication, startingWith text: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history.row.' AND label BEGINSWITH %@", text))
    }

    @MainActor @discardableResult private func deleteClipboardRow(_ row: XCUIElement, in app: XCUIApplication) -> String {
        let id = row.identifier
        app.buttons[id.replacingOccurrences(of: "history.row.", with: "history.actions.")].tap()
        app.buttons["Delete"].tap()
        app.alerts["Delete clipboard item?"].buttons["Delete"].tap()
        XCTAssertTrue(app.buttons[id].waitForNonExistence(timeout: 5))
        return id
    }

    @MainActor func testManualPasteURL() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--history-ui-qa", "-AppleLanguages", "(en)", "-setupGuide.dismissed", "YES", "-ui.language", "en"]
        let url = URL(string: "https://example.com/manual-clipboard?test=url#history")!
        UIPasteboard.general.setItems([["public.url": url]], options: [.localOnly: true])
        app.launch()
        app.buttons["Paste"].tap()
        allowPasteIfAsked()
        XCTAssertTrue(app.staticTexts[url.absoluteString].waitForExistence(timeout: 8))
    }

    @MainActor private func openClipboardHistory() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--history-ui-qa", "--test-clipboard", "-AppleLanguages", "(en)", "-setupGuide.dismissed", "YES", "-ui.language", "en"]
        app.launch()
        return app
    }

    @MainActor private func allowPasteIfAsked() {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = system.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Allow Paste", "允许粘贴", "允許貼上"])).firstMatch
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    @MainActor func testClipboardImportOnReturn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--history-ui-qa", "--test-clipboard", "-AppleLanguages", "(en)", "-setupGuide.dismissed", "YES", "-ui.language", "en"]
        app.launch()

        let captureSwitch = app.switches["Save clipboard while app is open"]
        let tabs = app.tabBars.firstMatch
        tabs.buttons["Settings"].tap()
        app.buttons["Privacy & Security"].tap()
        XCTAssertTrue(captureSwitch.waitForExistence(timeout: 5))
        if captureSwitch.value as? String == "1" { captureSwitch.switches.firstMatch.tap() }
        tabs.buttons["History"].tap()

        let enable = app.buttons["Enable automatic saving"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        enable.tap()
        XCTAssertTrue(enable.waitForNonExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        let text = "Clipboard collected on return"
        let url = URL(string: "https://example.com/clipboard?test=url#history")!
        let items: [[String: Any]] = [["public.utf8-plain-text": text], ["public.url": url]]
        UIPasteboard.general.setItems(items, options: [.localOnly: true])
        app.activate()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowPaste = springboard.alerts.buttons.matching(NSPredicate(
            format: "label IN %@", ["Allow Paste", "允许粘贴", "允許貼上"]
        )).firstMatch
        if allowPaste.waitForExistence(timeout: 5) { allowPaste.tap() }
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[url.absoluteString].waitForExistence(timeout: 5))

        tabs.buttons["Settings"].tap()
        captureSwitch.switches.firstMatch.tap()
        XCTAssertEqual(captureSwitch.value as? String, "0")
    }

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
