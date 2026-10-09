import Foundation
import XCTest

extension IMAppLocalTwoInstallE2ETests {
    private struct SystemPushObservation: Decodable {
        let stage: String
        let delivered: Bool
        let projected: Bool
        let messageID: String?
        let originalMessageCount: Int?
        let remoteCallbackCount: Int
        let osLogReadSucceeded: Bool
    }

    @MainActor
    func testSystemPushCommitsRoomMessageWhileAppSuspended() async throws {
        let environment = ProcessInfo.processInfo.environment
        let token = try XCTUnwrap(environment["IMAPP_PUSH_FIXTURE_TOKEN"])
        let title = try XCTUnwrap(environment["IMAPP_PUSH_GROUP_TITLE"])
        let app = XCUIApplication()
        app.activate()
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 30))
        app.tabBars.buttons["我的"].tap()
        let privacy = app.descendants(matching: .any).matching(identifier: "v2.privacy.open").firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 10) && privacy.isHittable)
        privacy.tap()
        let toggle = app.switches["v2.push-wake.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable && toggle.isEnabled)
        if toggle.value as? String != "1" {
            let control = toggle.switches.firstMatch
            XCTAssertTrue(control.exists && control.isHittable)
            control.tap()
        }
        let status = app.staticTexts["v2.push-wake.registration-status"]
        let readyBy = ContinuousClock.now + .seconds(60)
        while status.label != "后台同步唤醒已就绪" && ContinuousClock.now < readyBy {
            if app.staticTexts["v2.push-wake.feedback"].exists {
                XCTFail("普通Push注册未完成：" + app.staticTexts["v2.push-wake.feedback"].label)
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(status.label, "后台同步唤醒已就绪")
        guard status.label == "后台同步唤醒已就绪" else { return }
        app.buttons["v2.privacy.done"].tap()
        app.tabBars.buttons["消息"].tap()
        let group = app.staticTexts[title].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30) && group.isHittable)
        group.tap()
        XCTAssertTrue(app.textFields["v2.message.draft"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        let suspendBy = ContinuousClock.now + .seconds(90)
        while app.state != .runningBackgroundSuspended && ContinuousClock.now < suspendBy {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(app.state, .runningBackgroundSuspended)
        XCTContext.runActivity(named: "system-push-app-confirmed-suspended") { _ in }

        func observe(start: Bool) async throws -> SystemPushObservation {
            var request = URLRequest(url: try XCTUnwrap(URL(string:
                "https://localhost:8443/__fixture__/push-wake/" + (start ? "start" : "state"))))
            request.httpMethod = start ? "POST" : "GET"
            request.setValue(token, forHTTPHeaderField: "X-Push-Fixture")
            request.timeoutInterval = 10
            if start {
                request.httpBody = try JSONEncoder().encode([
                    "accountHandle": try XCTUnwrap(environment["IMAPP_PUSH_ACCOUNT_HANDLE"]),
                    "scope": try XCTUnwrap(environment["IMAPP_PUSH_SCOPE"]), "title": title])
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try JSONDecoder().decode(SystemPushObservation.self, from: data)
        }
        var observation = try await observe(start: true)
        let finishBy = ContinuousClock.now + .seconds(100)
        while observation.stage != "passed" && observation.stage != "failed" && ContinuousClock.now < finishBy {
            XCTAssertTrue(app.state == .runningBackground || app.state == .runningBackgroundSuspended,
                          "系统唤醒期间不能激活前台以补齐消息。")
            try await Task.sleep(for: .milliseconds(200))
            observation = try await observe(start: false)
        }
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningBackgroundSuspended,
                      "核对原消息持久化结果前不能返回前台。")
        XCTAssertEqual(observation.stage, "passed")
        XCTAssertTrue(observation.delivered && observation.projected)
        XCTAssertEqual(observation.originalMessageCount, 1)
        XCTAssertTrue(observation.osLogReadSucceeded)
        XCTAssertGreaterThan(observation.remoteCallbackCount, 0, "必须证明系统远程通知回调实际到达，其他同步唤醒不能替代。")
        let messageID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(observation.messageID))).uuidString
        XCTContext.runActivity(named: "system-push-original-message-persisted-in-background") { _ in }
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "v2.message.body.\(messageID)")
            .firstMatch.waitForExistence(timeout: 30))
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }
}
