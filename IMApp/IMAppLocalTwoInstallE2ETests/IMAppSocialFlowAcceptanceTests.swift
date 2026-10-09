import XCTest

/// Attach to the explicitly prepared two-account local installations.
final class IMAppSocialFlowAcceptanceTests: XCTestCase {
    @MainActor private func openPeerProfile() throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.activate()
        if app.buttons["关闭"].exists { app.buttons["关闭"].tap() }
        let header = app.buttons["v2.chat.peer-profile"]
        if !header.exists {
            let chat = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.conversation.direct.")).firstMatch
            XCTAssertTrue(chat.waitForExistence(timeout: 30))
            chat.tap()
        }
        XCTAssertTrue(header.waitForExistence(timeout: 20))
        header.tap()
        XCTAssertTrue(app.staticTexts["v2.user.relationship"].waitForExistence(timeout: 30))
        return app
    }
    @MainActor private func waitForRelationship(_ text: String, app: XCUIApplication) {
        let status = app.staticTexts["v2.user.relationship"]
        let ready = expectation(for: NSPredicate(format: "label == %@", text), evaluatedWith: status)
        wait(for: [ready], timeout: 35)
    }
    @MainActor func testSenderRequestsFriendshipFromChat() throws {
        let app = try openPeerProfile()
        let add = app.buttons["v2.user.add-friend"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        waitForRelationship("好友申请已发送，等待对方接受", app: app)
        XCTAssertTrue(app.buttons["v2.user.cancel-request"].exists)
    }
    @MainActor func testReceiverAcceptsFriendshipFromChat() throws {
        let app = try openPeerProfile()
        let accept = app.buttons["v2.user.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 30))
        accept.tap()
        waitForRelationship("已是好友", app: app)
    }
    @MainActor func testFriendCanBlockAndUnblockFromProfile() throws {
        let app = try openPeerProfile()
        waitForRelationship("已是好友", app: app)
        app.buttons["v2.user.block"].tap()
        let confirm = app.buttons["屏蔽"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        waitForRelationship("你已屏蔽此用户", app: app)
        app.buttons["v2.user.unblock"].tap()
        waitForRelationship("对方还不是你的好友", app: app)
        XCTAssertTrue(app.buttons["v2.user.add-friend"].exists)
    }
    @MainActor func testChatSettingsCanPinAndArchiveAndRestore() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.activate()
        if app.buttons["关闭"].exists { app.buttons["关闭"].tap() }
        let chat = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.conversation.direct.")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 30))
        chat.tap()
        let menu = app.buttons["v2.conversation.detail.tools"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let details = app.buttons["聊天详情"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()
        for id in ["v2.chat-settings.pin", "v2.chat-settings.archive"] {
            let toggle = app.switches[id]
            XCTAssertTrue(toggle.waitForExistence(timeout: 15))
            XCTAssertEqual(toggle.value as? String, "0")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            let enabled = expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
            wait(for: [enabled], timeout: 20)
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            let disabled = expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
            wait(for: [disabled], timeout: 20)
        }
        app.buttons["关闭"].tap()
    }
    @MainActor func testCommittedMessageClearsWaitingFeedback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.activate()
        if app.buttons["关闭"].exists { app.buttons["关闭"].tap() }
        let chat = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.conversation.direct.")).firstMatch
        if chat.exists { chat.tap() }
        let draft = app.textFields["v2.message.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 30))
        draft.tap()
        let text = "social-flow-" + String(UUID().uuidString.prefix(8))
        draft.typeText(text)
        XCTAssertEqual(draft.value as? String, text)
        app.buttons["v2.message.send"].tap()
        let body = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "v2.message.body.", text)).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 40))
        XCTAssertTrue(body.isHittable)
        let feedback = app.staticTexts["v2.message.send-feedback"]
        let settled = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: feedback)
        wait(for: [settled], timeout: 30)
    }
}
