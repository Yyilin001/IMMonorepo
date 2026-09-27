import XCTest

final class IMAppResourceRecoveryUITests: XCTestCase {
    @MainActor
    func testDepartedGroupOperationSurvivesBackgroundAndRelaunchUntilAbandoned() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), scope = UUID().uuidString
        let arguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-scope", scope,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments = arguments
        addTeardownBlock { @MainActor () async throws -> Void in
            let cleanup = XCUIApplication()
            cleanup.terminate()
            cleanup.launchArguments = arguments + ["-v2-ui-testing-resource-cleanup"]
            cleanup.launch()
            XCTAssertTrue(cleanup.staticTexts["v2.resource-test.cleaned"].waitForExistence(timeout: 10))
            cleanup.terminate()
        }
        app.launch()
        openPending(app)
        openOperation(app)
        XCTAssertFalse(app.buttons["v2.group.avatar.choose"].isEnabled)
        XCTAssertFalse(app.buttons["v2.group.avatar.remove"].isEnabled)
        let query = app.buttons["v2.group.avatar.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.tap()
        waitUntilEnabled(app.buttons["v2.group.avatar.close"])
        XCUIDevice.shared.press(.home)
        app.activate()
        let close = app.buttons["v2.group.avatar.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        waitUntilEnabled(close); close.tap()
        XCTAssertTrue(app.buttons["v2.group.avatar.abandon"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Departed group operation permanently closed"
        screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["v2.group.avatar.done"].tap()
        XCTAssertTrue(app.buttons["v2.group.avatar.pending.item"].firstMatch.waitForExistence(timeout: 10))

        app.terminate(); app.launch()
        openPending(app); openOperation(app)
        let abandon = app.buttons["v2.group.avatar.abandon"]
        XCTAssertTrue(abandon.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["v2.group.avatar.retry-closed"].isEnabled)
        abandon.tap()
        XCTAssertTrue(app.staticTexts["v2.group.avatar.focus-completed"].waitForExistence(timeout: 10))
        app.buttons["v2.group.avatar.done"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "v2.group.avatar.pending.empty").firstMatch.waitForExistence(timeout: 10))
        app.buttons["v2.group.avatar.pending.done"].tap()
        openPending(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "v2.group.avatar.pending.empty").firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor private func openPending(_ app: XCUIApplication) {
        let menu = app.buttons["v2.account-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        let pending = app.buttons["v2.group.avatar.pending.open"]
        XCTAssertTrue(pending.waitForExistence(timeout: 5)); pending.tap()
    }
    @MainActor private func openOperation(_ app: XCUIApplication) {
        let item = app.buttons["v2.group.avatar.pending.item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10)); item.tap()
    }
    @MainActor private func waitUntilEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
}
