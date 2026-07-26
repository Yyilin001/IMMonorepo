import XCTest

final class IMAppLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFreshLaunchShowsPasswordSignInControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out"]
        app.launch()

        let accountHandle = app.textFields["v2.password.account-handle"]
        XCTAssertTrue(accountHandle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["v2.password.value"].exists)
        XCTAssertTrue(app.buttons["v2.password.submit"].exists)
        XCTAssertTrue(app.buttons["v2.passkey.sign-in"].exists)
    }

    @MainActor
    func testPasswordRegistrationRequiresPublicIdentityFieldsBeforeSubmit() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-v2-ui-testing-signed-out",
            "-v2-ui-testing-password-register",
        ]
        app.launch()

        let accountHandle = app.textFields["v2.password.account-handle"]
        let password = app.secureTextFields["v2.password.value"]
        let publicHandle = app.textFields["v2.identity.public-handle"]
        let displayName = app.textFields["v2.identity.display-name"]
        let submit = app.buttons["v2.password.submit"]

        XCTAssertTrue(accountHandle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["v2.password.mode"].exists)
        XCTAssertTrue(publicHandle.exists)
        XCTAssertTrue(displayName.exists)
        XCTAssertFalse(submit.isEnabled)

        accountHandle.tap()
        accountHandle.typeText("local_account")
        password.tap()
        password.typeText("twelve-byte-password")
        publicHandle.tap()
        publicHandle.typeText("local_public")
        displayName.tap()
        displayName.typeText("Local User")

        XCTAssertTrue(submit.isEnabled)
    }
}
