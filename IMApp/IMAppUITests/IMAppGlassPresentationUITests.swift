import XCTest

final class IMAppGlassPresentationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch(_ screen: String = "messages") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-mock-preview", "-v2-mock-hide-controls", "-v2-mock-screen", screen]
        app.launch()
        return app
    }

    @MainActor
    func testRoundUnreadBadgeAndCompactComposerCanSend() {
        let app = launch()
        let room = "00000000-0000-0000-0000-000000000101"
        let badge = app.descendants(matching: .any)["v2.conversation.unread.\(room)"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertEqual(badge.frame.width, badge.frame.height, accuracy: 1)
        app.buttons["v2.conversation.group.\(room)"].tap()
        let draft = app.textFields["v2.message.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertLessThan(draft.frame.height, 65)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        XCTAssertFalse(app.buttons["v2.message.reply.mock-message-0"].exists)
        app.staticTexts["大家早上好！我们今天一起看一下新的界面。"].press(forDuration: 1)
        let reply = app.buttons["v2.message.reply.mock-message-0"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        XCTAssertTrue(app.buttons["v2.message.reply.cancel"].waitForExistence(timeout: 5))
        app.buttons["v2.message.reply.cancel"].tap()
        draft.tap()
        draft.typeText("Glass mock send")
        app.buttons["v2.message.send"].tap()
        XCTAssertTrue(app.staticTexts["Glass mock send"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testConsecutiveSendsCaptureTimelinePositions() {
        let app = launch("chat")
        let draft = app.textFields["v2.message.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        for index in 1...3 {
            draft.tap()
            draft.typeText("Scroll regression message \(index)")
            app.buttons["v2.message.send"].tap()
            let completed = NSPredicate { _, _ in
                let send = app.buttons["v2.message.send"]
                return send.exists && !send.isEnabled
                    && app.staticTexts["v2.message.send-feedback"].exists
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: completed, object: nil)], timeout: 10), .completed)
            // Hosted MessagingUI cells do not expose their text to XCUI.
            // Retain each settled frame for visual verification of the tail.
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Timeline after send \(index)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testCachedContactCanOpenChatWithoutRelationshipRefresh() {
        // The preview source deliberately has no remote social-baseline service.
        let app = launch("contacts")
        let contact = app.buttons["v2.contacts.friend.00000000-0000-0000-0000-000000000201"]
        XCTAssertTrue(contact.waitForExistence(timeout: 10))
        contact.tap()
        let message = app.buttons["v2.user.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.isEnabled)
        message.tap()
        XCTAssertTrue(app.textFields["v2.message.draft"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["v2.user.message"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Contact opened chat from local identity"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testNativeTabsPrivacyAndChatMenusRemainReachable() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["联系人"].waitForExistence(timeout: 10))
        app.tabBars.buttons["联系人"].tap()
        XCTAssertTrue(app.staticTexts["小林"].waitForExistence(timeout: 10))
        app.tabBars.buttons["我的"].tap()
        app.buttons["v2.privacy.open"].tap()
        XCTAssertTrue(app.switches["v2.privacy.allow-stranger-messages"].waitForExistence(timeout: 10))
        app.buttons["v2.privacy.done"].tap()
        app.tabBars.buttons["消息"].tap()
        app.buttons["v2.conversation.tools"].tap()
        XCTAssertTrue(app.buttons["v2.conversation.new-group"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-v2-mock-preview", "-v2-mock-hide-controls", "-v2-mock-screen", "chat"]
        app.launch()
        XCTAssertTrue(app.textFields["v2.message.draft"].waitForExistence(timeout: 10))
        app.buttons["v2.message.composer.options"].tap()
        XCTAssertTrue(app.buttons["v2.message.attachment.add"].waitForExistence(timeout: 5))
    }
}
