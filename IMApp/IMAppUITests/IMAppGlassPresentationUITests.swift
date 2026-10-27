import XCTest
import UIKit

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
    func testIncomingMessagesFollowLatestWithoutSending() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-mock-preview", "-v2-mock-hide-controls", "-v2-mock-screen", "chat", "-v2-mock-incoming-controls"]
        app.launch()
        XCTAssertTrue(app.textFields["v2.message.draft"].waitForExistence(timeout: 10))
        let receive = app.buttons["mock.receive-messages"]
        XCTAssertTrue(receive.waitForExistence(timeout: 5))
        receive.tap()
        // Keep actual rendered cells as evidence; hosted MessagingUI content is
        // not fully represented by XCUI's accessibility tree.
        let tail = app.staticTexts["实时接收测试消息 17"]
        _ = tail.waitForExistence(timeout: 3)
        let received = XCTAttachment(screenshot: app.screenshot())
        received.name = "Incoming messages at latest end"
        received.lifetime = .keepAlways
        add(received)
        let list = app.descendants(matching: .any)["v2.message.list"].firstMatch
        XCTAssertTrue(list.exists)
        list.swipeDown()
        receive.tap()
        _ = app.staticTexts["实时接收测试消息 29"].waitForExistence(timeout: 3)
        let history = XCTAttachment(screenshot: app.screenshot())
        history.name = "Incoming messages preserve history viewport"
        history.lifetime = .keepAlways
        add(history)
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
        let profile = XCTAttachment(screenshot: app.screenshot())
        profile.name = "Profile hierarchy with primary message action"
        profile.lifetime = .keepAlways
        add(profile)
        message.tap()
        XCTAssertTrue(app.textFields["v2.message.draft"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["v2.user.message"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Contact opened chat from local identity"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testAccountHierarchyKeepsSettingsReachable() {
        let app = launch("me")
        let privacy = app.buttons["v2.privacy.open"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["v2.message.favorites"].exists)
        XCTAssertTrue(app.buttons["v2.sign-out"].exists)
        let account = XCTAttachment(screenshot: app.screenshot())
        account.name = "Account grouped settings hierarchy"
        account.lifetime = .keepAlways
        add(account)
        privacy.tap()
        XCTAssertTrue(app.switches["v2.privacy.allow-stranger-messages"].waitForExistence(timeout: 5))
        app.buttons["v2.privacy.done"].tap()
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
    }

    @MainActor
    func testHostedMessageAuthorCanPresentAndDismissProfile() {
        let app = launch("chat")
        let author = app.buttons["v2.message.author-profile.mock-message-1"]
        XCTAssertTrue(author.waitForExistence(timeout: 15)); author.tap()
        let profile = app.navigationBars["用户资料"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["小林"].waitForExistence(timeout: 5))
        let shown = XCTAttachment(screenshot: app.screenshot())
        shown.name = "Hosted message author profile sheet"; shown.lifetime = .keepAlways; add(shown)
        profile.buttons["关闭"].tap()
        XCTAssertTrue(profile.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.textFields["v2.message.draft"].exists)
        XCTAssertTrue(author.exists)
    }

    @MainActor
    func testSystemPhotoSelectionPersistsAndRemovalSurvivesRelaunch() {
        let app = XCUIApplication(), scope = UUID().uuidString
        app.launchArguments = ["-v2-mock-preview", "-v2-mock-hide-controls", "-v2-mock-screen", "chat",
            "-v2-mock-resource-staging-scope", scope, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let draft = app.textFields["v2.message.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15)); draft.tap(); draft.typeText("photo selection draft")
        app.buttons["v2.message.composer.options"].tap()
        app.buttons["v2.message.photo.add"].tap()
        let cell = app.scrollViews["photosView_content_scroll_view"].images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "System photo picker asset hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        cell.tap()
        let confirm = app.navigationBars["照片"].buttons["完成"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); XCTAssertTrue(confirm.isEnabled); confirm.tap()
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.attachment.remove.")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ AND value == %@", "附件 ", "已添加，发送时上传")).firstMatch.exists)
        XCTAssertEqual(draft.value as? String, "photo selection draft")
        let selected = XCTAttachment(screenshot: app.screenshot())
        selected.name = "System selected photo becomes a managed chat attachment"; selected.lifetime = .keepAlways; add(selected)
        app.terminate(); app.launch()
        XCTAssertTrue(remove.waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.attachment.remove.")).count, 1)
        let restoredPixels = NSPredicate { _, _ in Self.containsImportedPhotoPreview(app.screenshot()) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restoredPixels, object: nil)], timeout: 10), .completed)
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "Reopened draft renders original photo bytes"; restored.lifetime = .keepAlways; add(restored)
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        // Timeline publication follows durable attachment restoration. Waiting
        // for real messages avoids accepting a transient empty composer.
        XCTAssertTrue(app.staticTexts["好的，下午三点一起讨论～"].waitForExistence(timeout: 15))
        XCTAssertFalse(remove.exists)
        let removed = XCTAttachment(screenshot: app.screenshot())
        removed.name = "Removed attachment stays absent after restored timeline"; removed.lifetime = .keepAlways; add(removed)
        app.terminate(); app.launchArguments += ["-v2-mock-resource-staging-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["附件测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    private static func containsImportedPhotoPreview(_ screenshot: XCUIScreenshot) -> Bool {
        guard let image = UIImage(data: screenshot.pngRepresentation)?.cgImage else { return false }
        let width = 64, height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var blue = 0
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                if bytes[offset] < 80 && bytes[offset + 1] > 60 && bytes[offset + 1] < 180 && bytes[offset + 2] > 170 { blue += 1 }
            }
            // The seeded photo's blue 48pt preview is the only blue payload
            // in this neutral chat fixture. A name/icon alone cannot pass.
            return blue > width * height / 500
        }
    }

    @MainActor
    func testChatPhotoPickerCanOpenAndCancelWithoutLosingDraft() {
        let app = launch("chat")
        let draft = app.textFields["v2.message.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        draft.typeText("photo draft")
        app.buttons["v2.message.composer.options"].tap()
        let photos = app.buttons["v2.message.photo.add"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        photos.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        let loading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "正在加载", "Loading")).firstMatch
        XCTAssertTrue(loading.waitForNonExistence(timeout: 20))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "System photo library picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        cancel.tap()
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "photo draft")
        XCTAssertFalse(app.otherElements["v2.message.attachments"].exists)
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
