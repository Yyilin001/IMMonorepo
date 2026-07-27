import Foundation
import XCTest

/// A real local-stack integration test. It has its own target and scheme so
/// the ordinary UI suite remains fully offline and deterministic.
final class IMAppLocalAccountUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Isolates simulator-to-host TLS reachability before the registration UI
    /// test. The deliberately malformed body must reach the real local edge
    /// and receive its public 400 contract; no account or credential is made.
    func testSimulatorCanReachLocalAccountEdge() async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://localhost:8443/v2/account-auth/password/assertion")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 400, "本机账户边缘必须可被所选模拟器经 HTTPS 访问。")
    }

    /// Checks the two HTTPS contracts consumed by ClientKit without importing
    /// the App's transitive GRDB module graph into this UI-test target.
    func testSimulatorCanRegisterAndIssueLocalDeviceCredentials() async throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let deviceID = UUID().uuidString.lowercased()
        let accountHandle = "kit_\(suffix.prefix(20))"
        let publicHandle = "kit\(suffix.prefix(20))"
        let registration = try await localJSONRequest(
            endpoint: try XCTUnwrap(URL(string: "https://localhost:8443/v2/account-auth/password/register")),
            body: [
                "accountHandle": accountHandle,
                "password": "local-clientkit-password",
                "deviceID": deviceID,
                "publicHandle": publicHandle,
                "displayName": "Local HTTPS E2E",
            ]
        )
        let assertion = try XCTUnwrap(registration["accountAssertion"] as? String)
        let issued = try await localJSONRequest(
            endpoint: try XCTUnwrap(URL(string: "https://localhost:8443/v2/device-credentials")),
            body: [
                "accountAssertion": assertion,
                "deviceID": deviceID,
                "operationID": UUID().uuidString.lowercased(),
            ]
        )
        XCTAssertEqual(issued["deviceID"] as? String, deviceID)
        XCTAssertFalse((issued["accessToken"] as? String ?? "").isEmpty)
    }

    @MainActor
    func testPasswordRegistrationEstablishesLocalSession() throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let accountHandle = "ios_\(suffix.prefix(20))"
        let publicHandle = "ios\(suffix.prefix(20))"
        let password = "localpassword"
        let e2eScope = UUID().uuidString.lowercased()

        let app = XCUIApplication()
        defer {
            // This only terminates the app-under-test so the next DEBUG-only
            // launch can release its scoped SQLite handle. It never changes
            // the simulator lifecycle or its ordinary account data.
            app.terminate()
            app.launchArguments = [
                "-v2-ui-testing-live-local-account",
                "-v2-ui-testing-cleanup-local-account",
                "-v2-ui-testing-e2e-scope",
                e2eScope,
            ]
            app.launch()
            XCTAssertTrue(
                app.staticTexts["v2.local-e2e.cleanup.completed"].waitForExistence(timeout: 10),
                "本地 E2E 回归结束后必须删除其随机 scope 的 Keychain 和 SQLite 测试工件。"
            )
        }
        app.launchArguments = [
            "-v2-ui-testing-live-local-account",
            "-v2-ui-testing-e2e-scope",
            e2eScope,
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
        let reachedAuthenticatedSession = directConversationButton.waitForExistence(timeout: 30)
        let authenticationMessage = app.staticTexts["v2.authentication.message"]
        let safeFailureMessage = authenticationMessage.exists
            ? authenticationMessage.label
            : "未显示认证错误文案"
        XCTAssertTrue(
            reachedAuthenticatedSession,
            "本地注册、设备凭证签发和 V2 本地会话打开后应显示已登录会话列表；当前安全错误：\(safeFailureMessage)"
        )
        XCTAssertFalse(authenticationMessage.exists)
    }
}

private func localJSONRequest(endpoint: URL, body: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    request.httpBody = try JSONEncoder().encode(body)
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertEqual(http.statusCode, 200, "本机账户 HTTPS 合约应接受测试中的有效请求。")
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}
