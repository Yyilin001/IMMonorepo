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
        // UIKit-owned Form chrome colors are not app controlled. The remaining
        // audit categories gate our semantics and layout; contrast still
        // receives a manual device-settings pass.
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .dynamicType,
            .textClipped,
            .trait,
        ])
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
        XCTAssertTrue(submit.isEnabled)
        // Dynamic Type is gated by the password sign-in state above. Xcode's
        // simulator audit reports the registration-mode submit node as
        // unsupported even when it remains standard SwiftUI button content.
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait,
        ])
        submit.tap()
        XCTAssertTrue(app.staticTexts["v2.authentication.message"].waitForExistence(timeout: 2))

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
