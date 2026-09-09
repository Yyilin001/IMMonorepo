import Foundation
import IMV2ClientKit
import IMV2Core
import XCTest

final class IMAppLegacyRegistrationUITests: XCTestCase {
    @MainActor
    func testLegacyCleanupSurvivesTerminationBeforeAcknowledgement() async throws {
        continueAfterFailure = true
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20))
        let handle = "legacyapp_" + suffix
        let password = "local-legacy-app-password"
        let old = try DeviceID(UUID().uuidString)
        let pending = try V2PendingDeviceCredentialRegistration.prepare(deviceID: old, operationID: UUID())
        let assertion = try await post("v2/account-auth/password/register", body: ["accountHandle": handle,
            "password": password, "deviceID": old.rawValue, "publicHandle": "legacyapp" + suffix, "displayName": "Legacy recovery"])
        var issue: [String: Any] = ["accountAssertion": try XCTUnwrap(assertion["accountAssertion"] as? String),
            "deviceID": old.rawValue, "operationID": pending.operationID.uuidString]
        issue["cancellation"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pending.cancellation))
        let credentials = try await post("v2/device-credentials", body: issue)
        let oldAccess = try XCTUnwrap(credentials["accessToken"] as? String)
        let app = XCUIApplication()
        let scoped = ["-v2-ui-testing-live-local-account", "-v2-ui-testing-e2e-scope", UUID().uuidString,
            "-v2-ui-testing-unavailable-realtime"]
        let login = ["-v2-ui-testing-account-handle", handle, "-v2-ui-testing-local-password", password]
        defer {
            app.terminate()
            app.launchArguments = scoped + ["-v2-ui-testing-cleanup-local-account"]
            app.launch()
            XCTAssertTrue(app.staticTexts["v2.local-e2e.cleanup.completed"].waitForExistence(timeout: 15))
            app.terminate()
        }
        app.launchArguments = scoped + login + ["-v2-ui-testing-legacy-registration",
            "-v2-ui-testing-legacy-device", old.rawValue, "-v2-ui-testing-legacy-operation", pending.operationID.uuidString]
        app.launch()
        guard app.buttons["v2.password.submit"].waitForExistence(timeout: 15) else { XCTFail("Legacy fixture must reach real sign-in."); return }
        app.buttons["v2.password.submit"].tap()
        _ = try await post("__fixture__/interruption-ready", body: ["phase": "legacy"], expected: 204)
        guard app.wait(for: .notRunning, timeout: 30) else { XCTFail("Harness must terminate App before cleanup acknowledgement."); return }

        // No seeding arguments on this or later launches. The retry must be
        // sourced from the first process's actual Keychain archive.
        app.launchArguments = scoped + login
        app.launch()
        guard app.buttons["v2.password.submit"].waitForExistence(timeout: 15) else { XCTFail("Cold recovery must permit reauthentication."); return }
        app.buttons["v2.password.submit"].tap()
        guard app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 30) else { XCTFail("Replayed legacy cleanup must allow new login."); return }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://localhost:8443/v2/devices")))
        request.setValue("Bearer " + oldAccess, forHTTPHeaderField: "Authorization")
        request.setValue(old.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 401)
        app.terminate()
        app.launchArguments = scoped + ["-v2-ui-testing-restore-local-account"]
        app.launch()
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Restored new session after interrupted legacy cleanup"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func post(_ path: String, body: [String: Any], expected: Int = 200) async throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://localhost:8443/" + path)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, expected)
        return data.isEmpty ? [:] : try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
