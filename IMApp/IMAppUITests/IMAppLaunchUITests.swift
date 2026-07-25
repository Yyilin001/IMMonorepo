import XCTest

final class IMAppLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFreshLaunchShowsPasswordSignInControls() throws {
        let app = XCUIApplication()
        app.launch()

        let accountHandle = app.textFields["v2.password.account-handle"]
        XCTAssertTrue(accountHandle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["v2.password.value"].exists)
        XCTAssertTrue(app.buttons["v2.password.submit"].exists)
        XCTAssertTrue(app.buttons["v2.passkey.sign-in"].exists)
    }
}
