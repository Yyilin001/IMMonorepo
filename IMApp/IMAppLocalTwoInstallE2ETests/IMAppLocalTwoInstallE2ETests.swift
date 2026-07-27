import XCTest

/// The orchestration script starts the already-installed App with one random
/// launch fixture per stage. Each test then attaches to that independent App
/// process instead of passing account state through XCTest's own process.
final class IMAppLocalTwoInstallE2ETests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testReceiverRegistersIndependentInstallation() throws {
        let app = XCUIApplication()
        app.activate()

        let account = app.textFields["v2.password.account-handle"]
        let password = app.secureTextFields["v2.password.value"]
        let submit = app.buttons["v2.password.submit"]
        XCTAssertTrue(account.waitForExistence(timeout: 15))
        XCTAssertFalse((account.value as? String ?? "").isEmpty)
        XCTAssertTrue(password.exists)
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(
            app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 30),
            "接收端独立 App 安装必须通过真实密码注册、设备凭据和本地会话初始化。"
        )
        XCTAssertTrue(
            app.buttons["v2.account-menu"].exists,
            "账户菜单必须作为会话列表导航栏的一部分出现。"
        )
        try auditOrdinaryChatSurface(in: app)
        app.terminate()
    }

    @MainActor
    func testSenderOpensDirectConversationAndSendsFromIndependentInstallation() throws {
        let app = XCUIApplication()
        app.activate()

        let submit = app.buttons["v2.password.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 15))
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        let newDirect = app.buttons["v2.conversation.new-direct"]
        XCTAssertTrue(newDirect.waitForExistence(timeout: 30))
        newDirect.tap()

        let target = app.textFields["v2.conversation.direct-target"]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        XCTAssertFalse((target.value as? String ?? "").isEmpty)
        let start = app.buttons["v2.conversation.direct-submit"]
        XCTAssertTrue(start.isEnabled)
        start.tap()

        let draft = app.textFields["v2.message.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 30))
        XCTAssertFalse((draft.value as? String ?? "").isEmpty)
        XCTAssertFalse(
            app.buttons["v2.account-menu"].exists,
            "账户菜单不能遗留在会话详情页并遮挡消息输入与发送操作。"
        )
        try auditOrdinaryChatSurface(in: app)
        // The conversation detail is app-rendered rather than UIKit Form
        // chrome, so its visible message/composer state can also gate contrast.
        try app.performAccessibilityAudit(for: [.contrast])
        let send = app.buttons["v2.message.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let feedback = app.staticTexts["v2.message.send-feedback"]
        let feedbackAppeared = feedback.waitForExistence(timeout: 30)
        if !feedbackAppeared {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "two-install-sender-send-feedback-missing"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("发送端必须在真实 App 会话中收到普通消息已被网关接受或持久化重试的反馈。")
        }
        XCTAssertTrue(feedback.label.contains("已发送") || feedback.label.contains("已安全保存"))
        app.terminate()
    }

    @MainActor
    func testReceiverRestoresScopedInstallationAndProjectsOfflineMessage() throws {
        let app = XCUIApplication()
        app.activate()

        let refresh = app.buttons["v2.conversation.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 30))
        refresh.tap()
        let firstConversation = app.cells.firstMatch
        XCTAssertTrue(
            firstConversation.waitForExistence(timeout: 30),
            "接收端重启后必须通过自身 SQLite 同步投影看到发送端离线期间投递的会话。"
        )
        firstConversation.tap()
        XCTAssertTrue(app.textFields["v2.message.draft"].waitForExistence(timeout: 15))
        let deliveredMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.row.")
        ).firstMatch
        XCTAssertTrue(
            deliveredMessage.waitForExistence(timeout: 15),
            "接收端会话详情必须包含发送端离线期间投递、经同步投影恢复的消息。"
        )
        app.terminate()
    }

    @MainActor
    func testCleansOnlyRequestedIndependentInstallationScope() throws {
        let app = XCUIApplication()
        app.activate()
        XCTAssertTrue(
            app.staticTexts["v2.local-e2e.cleanup.completed"].waitForExistence(timeout: 15),
            "跨安装回归结束后必须清理仅该随机 scope 的 Keychain 和 SQLite 工件。"
        )
        app.terminate()
    }

    @MainActor
    private func auditOrdinaryChatSurface(in app: XCUIApplication) throws {
        // UIKit-owned navigation and form chrome is not app-controlled for
        // contrast. The remaining categories keep the signed-in list and
        // composer usable for Dynamic Type and VoiceOver users.
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .dynamicType,
            .textClipped,
            .trait,
        ])
    }
}
