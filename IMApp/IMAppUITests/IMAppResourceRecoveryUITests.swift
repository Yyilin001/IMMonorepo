import XCTest

final class IMAppResourceRecoveryUITests: XCTestCase {
    @MainActor
    func testAvatarOutcomeRecoversWithoutAnAccountTaskOrManualConfirmation() throws {
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
        openAvatar(app)
        XCTAssertTrue(app.descendants(matching: .any)["v2.group.avatar.updating"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["v2.group.avatar.query"].exists)
        XCTAssertFalse(app.buttons["v2.group.avatar.close"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["v2.group.avatar.updating"].waitForExistence(timeout: 10))

        app.terminate()
        app.launchArguments = arguments + ["-v2-ui-testing-resource-resolve"]
        app.launch()
        openAvatar(app)
        XCTAssertTrue(app.buttons["v2.group.avatar.retry-closed"].waitForExistence(timeout: 30))
        // Permission loss prevents a new mutation, while account recovery still
        // settles the original operation without any user action.
        XCTAssertFalse(app.buttons["v2.group.avatar.retry-closed"].isEnabled)
        XCTAssertFalse(app.buttons["v2.group.avatar.query"].exists)
        XCTAssertFalse(app.buttons["v2.group.avatar.close"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Avatar outcome recovered automatically"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor private func openAvatar(_ app: XCUIApplication) {
        let avatar = app.buttons["v2.resource-test.avatar.open"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["v2.group.avatar.pending.open"].exists)
        XCTAssertFalse(app.staticTexts["待处理群头像"].exists)
        avatar.tap()
    }
}
