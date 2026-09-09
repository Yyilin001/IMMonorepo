import Foundation
import XCTest

/// Selected only by the disposable HTTPS harness with --interrupted-issuance.
/// The proxy commits real requests, then terminates this App before forwarding
/// either the issuance response or the first cancellation response.
final class IMAppInterruptedRegistrationUITests: XCTestCase {
    @MainActor
    func testColdRestartCancelsIssuedSessionAfterTwoInterruptedResponses() async throws {
        continueAfterFailure = true
        let scope = UUID().uuidString.lowercased()
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20))
        let handle = "interrupt_" + suffix
        let password = "local-interrupted-registration-password"
        let app = XCUIApplication()
        let scoped = ["-v2-ui-testing-live-local-account", "-v2-ui-testing-e2e-scope", scope,
            "-v2-ui-testing-unavailable-realtime"]
        defer {
            app.terminate()
            app.launchArguments = scoped + ["-v2-ui-testing-cleanup-local-account"]
            app.launch()
            XCTAssertTrue(app.staticTexts["v2.local-e2e.cleanup.completed"].waitForExistence(timeout: 15))
            app.terminate()
        }
        app.launchArguments = scoped + ["-v2-ui-testing-password-register", "-v2-ui-testing-local-password", password,
            "-v2-ui-testing-account-handle", handle, "-v2-ui-testing-public-handle", "interrupt" + suffix,
            "-v2-ui-testing-display-name", "Interrupted registration acceptance"]
        app.launch()
        XCTAssertTrue(app.buttons["v2.password.submit"].waitForExistence(timeout: 15))
        app.buttons["v2.password.submit"].tap()
        try await allowInterruption("issue")
        guard app.wait(for: .notRunning, timeout: 30) else {
            XCTFail("The harness must terminate the actual App after issuance commit.")
            return
        }

        // No issued bytes reached this process. Its Keychain pending proof is
        // the only cancellation authority available to the cold App owner.
        app.launchArguments = scoped + ["-v2-ui-testing-restore-local-account"]
        app.launch()
        try await allowInterruption("cancel")
        guard app.wait(for: .notRunning, timeout: 30) else {
            XCTFail("The harness must terminate the App before cancellation acknowledgement.")
            return
        }

        // The durable job survives a second process boundary and retries with
        // the original proof. A later login must use a fresh device identity.
        app.launchArguments = scoped + ["-v2-ui-testing-local-password", password, "-v2-ui-testing-account-handle", handle]
        app.launch()
        XCTAssertTrue(app.buttons["v2.password.submit"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["v2.conversation.new-direct"].exists)
        app.buttons["v2.password.submit"].tap()
        guard app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 30) else {
            XCTFail("Fresh login must succeed after recovery from both interrupted responses.")
            return
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Fresh login after two process interruptions"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func allowInterruption(_ phase: String) async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://localhost:8443/__fixture__/interruption-ready")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["phase": phase])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 204)
    }
}
