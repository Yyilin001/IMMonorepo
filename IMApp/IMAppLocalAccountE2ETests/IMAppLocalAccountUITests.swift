import Foundation
import XCTest

/// A real local-stack integration test. It has its own target and scheme so
/// the ordinary UI suite remains fully offline and deterministic.
final class IMAppLocalAccountUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPasswordRegistrationEstablishesLocalSession() throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let accountHandle = "ios_\(suffix.prefix(20))"
        let publicHandle = "ios\(suffix.prefix(20))"
        let password = "localpassword"

        let app = XCUIApplication()
        app.launchArguments = [
            "-v2-ui-testing-live-local-account",
            "-v2-ui-testing-password-register",
            "-v2-ui-testing-local-password",
            password,
            "-v2-ui-testing-account-handle",
            accountHandle,
            "-v2-ui-testing-public-handle",
            publicHandle,
            "-v2-ui-testing-display-name",
            "Local iOS E2E",
        ]
        app.launch()

        let accountField = app.textFields["v2.password.account-handle"]
        let passwordField = app.secureTextFields["v2.password.value"]
        let publicHandleField = app.textFields["v2.identity.public-handle"]
        let displayNameField = app.textFields["v2.identity.display-name"]
        let submit = app.buttons["v2.password.submit"]

        XCTAssertTrue(accountField.waitForExistence(timeout: 10))
        XCTAssertTrue(passwordField.exists)
        XCTAssertTrue(publicHandleField.exists)
        XCTAssertTrue(displayNameField.exists)

        // The iOS 26.2 Simulator/XCTest runtime injects only one character per
        // field in this SwiftUI form. The DEBUG-only live-local mode preloads
        // these disposable values instead; this E2E still exercises the real
        // submit action, account HTTPS, device credentials and local session.
        XCTAssertTrue(submit.isEnabled)

        submit.tap()

        let directConversationButton = app.buttons["v2.conversation.new-direct"]
        XCTAssertTrue(
            directConversationButton.waitForExistence(timeout: 30),
            "本地注册、设备凭证签发和 V2 本地会话打开后应显示已登录会话列表。"
        )
        XCTAssertFalse(app.staticTexts["v2.authentication.message"].exists)
    }
}
