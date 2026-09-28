import Foundation
import IMV2ClientKit
import IMV2Core
import XCTest

/// Opt-in local account acceptance, separate from the ordinary offline UI
/// suite and the existing registration/delivery test class.
final class IMAppLocalAuthenticationTerminationUITests: XCTestCase {
    @MainActor
    func testPendingMessageRetriesAfterBackgroundReturn() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IMV2_B07_SCENE_RETRY"] == "1")
        // The disposable native harness owns the Gateway control endpoint.
        // Registration and all message writes still use normal production APIs.
        continueAfterFailure = true
        let scope = UUID().uuidString.lowercased()
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20))
        let app = XCUIApplication()
        let scoped = ["-v2-ui-testing-live-local-account", "-v2-ui-testing-e2e-scope", scope]
        defer {
            app.terminate()
            app.launchArguments = scoped + ["-v2-ui-testing-cleanup-local-account"]
            app.launch()
            XCTAssertTrue(app.staticTexts["v2.local-e2e.cleanup.completed"].waitForExistence(timeout: 15))
            app.terminate()
        }
        app.launchArguments = scoped + ["-v2-ui-testing-password-register",
            "-v2-ui-testing-local-password", "local-background-retry-password",
            "-v2-ui-testing-account-handle", "retry_" + suffix,
            "-v2-ui-testing-public-handle", "retry" + suffix,
            "-v2-ui-testing-display-name", "Background retry",
            "-v2-ui-testing-group-title", "Background retry group"]
        app.launch()
        let register = app.buttons["v2.password.submit"]
        guard register.waitForExistence(timeout: 15), register.isEnabled else { XCTFail("Registration unavailable"); return }
        register.tap()
        let newGroup = app.buttons["v2.conversation.new-group"]
        guard newGroup.waitForExistence(timeout: 30) else { XCTFail("Normal registration did not complete"); return }
        newGroup.tap()
        let create = app.buttons["v2.conversation.group-submit"]
        guard create.waitForExistence(timeout: 15), create.isEnabled else { XCTFail("Group creation unavailable"); return }
        create.tap()
        let draft = app.textViews["v2.message.draft"]
        guard draft.waitForExistence(timeout: 30) else { XCTFail("Group did not open"); return }
        _ = try await post("__fixture__/b07/stop", body: [:], expectedStatus: 204)
        draft.tap()
        draft.typeText("q")
        XCTAssertEqual(draft.value as? String, "q")
        app.buttons["v2.message.send"].tap()
        let feedback = app.staticTexts["v2.message.send-feedback"]
        guard feedback.waitForExistence(timeout: 30) else { XCTFail("Send did not finish locally"); return }
        XCTAssertEqual(feedback.label, "已安全保存，连接恢复后会重试。")
        XCUIDevice.shared.press(.home)
        guard app.wait(for: .runningBackground, timeout: 15) || app.state == .runningBackgroundSuspended else { XCTFail("App did not enter background"); return }
        _ = try await post("__fixture__/b07/start", body: [:], expectedStatus: 204)
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningBackgroundSuspended)
        _ = try await post("__fixture__/b07/check-background", body: [:], expectedStatus: 204)
        app.activate()
        guard draft.waitForExistence(timeout: 30) else { XCTFail("Conversation did not survive foreground recovery"); return }
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "q")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 30))
        _ = try await post("__fixture__/b07/check-delivered", body: [:], expectedStatus: 204)
    }

    @MainActor
    func testRemoteDeviceRevocationReturnsToLoginAndSurvivesRelaunch() async throws {
        try await revocationReturnsToLogin(useGateway: false)
    }

    @MainActor
    func testGatewayDeviceRevocationReturnsToLoginAndSurvivesRelaunch() async throws {
        try await revocationReturnsToLogin(useGateway: true)
    }

    @MainActor
    private func revocationReturnsToLogin(useGateway: Bool) async throws {
        // Async UI tests must unwind their Swift task and scoped cleanup even
        // when an assertion fails; prerequisites below return explicitly.
        continueAfterFailure = true
        let scope = UUID().uuidString.lowercased()
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20))
        let handle = "revoke_" + suffix
        let password = "local-revocation-test-password"
        let app = XCUIApplication()
        let scopeArguments = ["-v2-ui-testing-live-local-account", "-v2-ui-testing-e2e-scope", scope]
            + (useGateway ? [] : ["-v2-ui-testing-unavailable-realtime"])
        defer {
            app.terminate()
            app.launchArguments = scopeArguments + ["-v2-ui-testing-cleanup-local-account"]
            app.launch()
            XCTAssertTrue(app.staticTexts["v2.local-e2e.cleanup.completed"].waitForExistence(timeout: 15))
            app.terminate()
        }
        app.launchArguments = scopeArguments + [
            "-v2-ui-testing-password-register", "-v2-ui-testing-local-password", password,
            "-v2-ui-testing-account-handle", handle, "-v2-ui-testing-public-handle", "revoke" + suffix,
            "-v2-ui-testing-display-name", "Local authentication lifecycle"
        ]
        app.launch()
        let submit = app.buttons["v2.password.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 15))
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        guard app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 30) else {
            let feedback = app.staticTexts["v2.authentication.message"]
            XCTFail("Real registration must activate the local session: " + (feedback.exists ? feedback.label : "no authentication feedback"))
            return
        }

        // The second device authenticates normally; no database mutation or
        // test-only account endpoint stands in for the revocation transaction.
        let otherDevice = UUID().uuidString.lowercased()
        let assertion = try await post("v2/account-auth/password/assertion", body: [
            "accountHandle": handle, "password": password, "deviceID": otherDevice])
        let pending = try V2PendingDeviceCredentialRegistration.prepare(deviceID: DeviceID(otherDevice), operationID: UUID())
        let issued = try await post("v2/device-credentials", body: [
            "accountAssertion": try XCTUnwrap(assertion["accountAssertion"] as? String),
            "deviceID": otherDevice, "operationID": pending.operationID.uuidString], cancellation: pending.cancellation)
        let access = try XCTUnwrap(issued["accessToken"] as? String)

        app.buttons["v2.account-menu"].tap()
        let devices = app.buttons["v2.device-sessions.open"]
        XCTAssertTrue(devices.waitForExistence(timeout: 5))
        devices.tap()
        let originalSessions = try await sessions(access: access, device: otherDevice)
        let currentDevice = try XCTUnwrap(originalSessions.first {
            ($0["deviceID"] as? String)?.lowercased() != otherDevice.lowercased()
        }?["deviceID"] as? String)
        let canonicalDevice = try XCTUnwrap(UUID(uuidString: currentDevice)).uuidString
        guard app.descendants(matching: .any).matching(identifier: "v2.device-sessions.row." + canonicalDevice).firstMatch.waitForExistence(timeout: 15) else {
            XCTFail("The authenticated device inventory must include this installation.")
            return
        }
        try await revokeObservedDevice(target: DeviceID(currentDevice), access: access, device: otherDevice)
        let refresh = app.buttons["v2.device-sessions.refresh"]
        if !useGateway {
            XCTAssertTrue(refresh.exists)
            refresh.tap()
        }
        XCTAssertTrue(app.buttons["v2.password.submit"].waitForExistence(timeout: 20),
                      "Terminal authentication must remove the signed-in view and its settings sheet.")
        // Login may enter the accessibility tree while the previous sheet
        // is still being removed. Observe both terminal conditions instead
        // of sampling one immediate frame of the dismissal transition.
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["v2.device-sessions.refresh"].waitForNonExistence(timeout: 5))

        // Foreground and cold restore cannot resurrect deleted credentials or
        // the old account's local presentation while the gateway is offline.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["v2.password.submit"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = scopeArguments + ["-v2-ui-testing-restore-local-account"]
        app.launch()
        XCTAssertTrue(app.buttons["v2.password.submit"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["v2.conversation.new-direct"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = (useGateway ? "Gateway" : "HTTP") + " authentication required after cold restore"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // A new interactive login must not reuse the revoked device identity,
        // including when the registration owner itself was cold restarted.
        app.terminate()
        app.launchArguments = scopeArguments + ["-v2-ui-testing-local-password", password,
            "-v2-ui-testing-account-handle", handle]
        app.launch()
        XCTAssertTrue(app.buttons["v2.password.submit"].waitForExistence(timeout: 15))
        app.buttons["v2.password.submit"].tap()
        guard app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 30) else {
            XCTFail("The same account must log in again with a fresh device after revocation.")
            return
        }
        let afterLogin = try await sessions(access: access, device: otherDevice)
        let activeIDs = afterLogin.compactMap { ($0["deviceID"] as? String)?.lowercased() }
        XCTAssertEqual(activeIDs.count, 2)
        XCTAssertTrue(activeIDs.contains(otherDevice.lowercased()))
        XCTAssertFalse(activeIDs.contains(currentDevice.lowercased()))
    }

    @MainActor
    private func revokeObservedDevice(target: DeviceID, access: String, device: String) async throws {
        func request(_ path: String, body: Data? = nil) async throws -> Data {
            var request = URLRequest(url: try XCTUnwrap(URL(string: "https://localhost:8443/" + path)), timeoutInterval: 15)
            request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
            request.setValue(device, forHTTPHeaderField: "X-IM-Device-ID")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 200)
            return data
        }
        let baseline = try await JSONDecoder().decode(V2RemoteDeviceRevocationBaseline.self,
            from: request("v2/devices/revocation-baseline"))
        let command = try V2RemoteDeviceRevocationCommand(operationID: UUID(), baseline: baseline,
            selection: .device(target), firstSubmissionDeadlineMilliseconds: baseline.expiresAtMilliseconds)
        let result = try await JSONDecoder().decode(V2RemoteDeviceRevocationResult.self,
            from: request("v2/devices/remote-revocations/submit", body: JSONEncoder().encode(command)))
        guard case .receipt(let proof) = result, case .revoked = proof.outcome else {
            throw V2RemoteDeviceRevocationValidationError.invalidReceipt
        }
        XCTAssertTrue(proof.validates(command))
        let recovered = try await JSONDecoder().decode(V2RemoteDeviceRevocationResult.self,
            from: request("v2/devices/remote-revocations/operations/recover",
                body: JSONEncoder().encode(V2RemoteDeviceRevocationRecoveryRequest(command: command, action: .query))))
        XCTAssertEqual(recovered, result)
    }

    @MainActor
    private func sessions(access: String, device: String) async throws -> [[String: Any]] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://localhost:8443/v2/devices?page_size=100")))
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        request.setValue(device, forHTTPHeaderField: "X-IM-Device-ID")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 200)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(body["sessions"] as? [[String: Any]])
    }

    @MainActor
    private func post(_ path: String, body: [String: String], access: String? = nil,
                      device: String? = nil, expectedStatus: Int = 200,
                      cancellation: V2DeviceRegistrationCancellation? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://localhost:8443/" + path)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let access { request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization") }
        if let device { request.setValue(device, forHTTPHeaderField: "X-IM-Device-ID") }
        var payload: [String: Any] = body
        if let cancellation { payload["cancellation"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cancellation)) }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, expectedStatus) // Never log secret response bodies.
        if expectedStatus == 204 { return [:] }
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let cancellation {
            let confirmation = try XCTUnwrap(result["registrationCancellation"])
            let decoded = try JSONDecoder().decode(V2DeviceRegistrationCancellation.self,
                from: JSONSerialization.data(withJSONObject: confirmation))
            XCTAssertTrue(decoded == cancellation, "Issuer must confirm original cancellation binding.")
        }
        return result
    }
}
