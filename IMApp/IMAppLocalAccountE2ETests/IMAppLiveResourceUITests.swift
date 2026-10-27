import UIKit
import XCTest

/// Owned HTTPS/TLS/OSS stack only; selected by the resource acceptance driver.
/// Both identities are created through real UI and isolated Keychain scopes.
final class IMAppLiveResourceUITests: XCTestCase {
    @MainActor func testSystemFileSendsToIndependentAccountAndPreviewsAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication(), receiver = Identity(role: "file receiver"), author = Identity(role: "file author")
        let text = "Live file " + UUID().uuidString
        for identity in [author, receiver] {
            addTeardownBlock { @MainActor in
                app.terminate(); app.launchArguments = identity.scopeArguments + ["-v2-ui-testing-cleanup-local-account"]
                app.launch()
                XCTAssertTrue(app.staticTexts["v2.local-e2e.cleanup.completed"].waitForExistence(timeout: 15)); app.terminate()
            }
        }
        register(receiver, app: app); app.terminate()
        register(author, app: app, extra: ["-v2-ui-testing-direct-target", receiver.publicHandle])
        app.buttons["v2.conversation.new-direct"].tap()
        let start = app.buttons["v2.conversation.direct-submit"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        let draft = app.textFields["v2.message.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 45)); draft.tap(); draft.typeText(text)
        app.buttons["v2.message.composer.options"].tap(); app.buttons["v2.message.attachment.add"].tap()
        let initialBrowser = XCTAttachment(string: app.debugDescription)
        initialBrowser.name = "Initial system file import location"; initialBrowser.lifetime = .keepAlways; add(initialBrowser)
        let document = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "IM Resource UI input")).firstMatch
        if !document.waitForExistence(timeout: 5) {
            let browse = app.buttons["浏览"].firstMatch
            if browse.exists { browse.tap() }
            let local = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["我的iPhone", "我的 iPhone"])).firstMatch
            if !local.exists {
                let back = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["BackButton"]
                if back.exists { back.tap() }
            }
            let locations = XCTAttachment(string: app.debugDescription)
            locations.name = "System import browser locations"; locations.lifetime = .keepAlways; add(locations)
            XCTAssertTrue(local.waitForExistence(timeout: 10)); local.tap()
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Real system file import browser"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTAssertTrue(document.waitForExistence(timeout: 15)); document.tap()
        let staged = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.attachment.remove.")).firstMatch
        if !staged.waitForExistence(timeout: 3) {
            let open = app.buttons["DOCPicker.actionButton"]
            if open.exists { XCTAssertTrue(open.isEnabled); open.tap() }
        }
        XCTAssertTrue(staged.waitForExistence(timeout: 20)); XCTAssertEqual(draft.value as? String, text)
        XCTAssertTrue(app.staticTexts["IM Resource UI input.txt"].exists)
        attach(app, "Real file chooser imported the managed document")
        app.buttons["v2.message.send"].tap()
        let accepted = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.attachments.")).firstMatch
        XCTAssertTrue(accepted.waitForExistence(timeout: 90)); let attachmentID = accepted.identifier
        XCTAssertFalse(app.staticTexts["v2.message.send-feedback"].exists)
        attach(app, "Live author accepted file without stale composer feedback")
        app.terminate(); app.launchArguments = receiver.scopeArguments + ["-v2-ui-testing-restore-local-account"]; app.launch()
        let room = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.conversation.direct.")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 60)); room.tap()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: attachmentID).firstMatch.exists)
        let download = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "v2.message.media.", "下载文件")).firstMatch
        if download.exists { download.tap() }
        previewDocument(app)
        app.terminate(); app.launch()
        XCTAssertTrue(room.waitForExistence(timeout: 45)); room.tap()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count, 1)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: attachmentID).firstMatch.exists)
        // No second download action is allowed after process restoration.
        previewDocument(app)
        print("Live resource UI file closure: system file picker -> real author -> independent recipient preview -> relaunch")
    }

    @MainActor private func previewDocument(_ app: XCUIApplication) {
        let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "v2.message.media.", ".open")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 30)); open.tap()
        let payload = "Resource center live document payload."
        let content = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", payload, payload)).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 20))
        let secondLine = "Selected with the system file picker."
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", secondLine, secondLine)).firstMatch.waitForExistence(timeout: 5))
        attach(app, "Independent recipient Quick Look displays actual document contents")
        app.buttons["完成"].tap(); XCTAssertTrue(content.waitForNonExistence(timeout: 5))
    }

    @MainActor func testScopedKeychainCanPrepareAndCleanUpRegistrationUI() {
        continueAfterFailure = false
        let identity = Identity(role: "keychain"), app = XCUIApplication()
        app.launchArguments = identity.registrationArguments
        addTeardownBlock { @MainActor in
            app.terminate(); app.launchArguments = identity.scopeArguments + ["-v2-ui-testing-cleanup-local-account"]
            app.launch()
            XCTAssertTrue(app.staticTexts["v2.local-e2e.cleanup.completed"].waitForExistence(timeout: 15)); app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["v2.password.submit"].waitForExistence(timeout: 15))
        attach(app, "Signed simulator host can read its scoped Keychain before registration")
    }

    @MainActor func testSystemPhotoSendsToIndependentAccountAndSurvivesRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let receiver = Identity(role: "receiver"), author = Identity(role: "author")
        let text = "Live photo " + UUID().uuidString
        addTeardownBlock { @MainActor in
            for identity in [author, receiver] {
                app.terminate()
                app.launchArguments = identity.scopeArguments + ["-v2-ui-testing-cleanup-local-account"]
                app.launch()
                XCTAssertTrue(app.staticTexts["v2.local-e2e.cleanup.completed"].waitForExistence(timeout: 15))
            }
            app.terminate()
        }
        register(receiver, app: app)
        app.terminate()
        register(author, app: app, extra: ["-v2-ui-testing-direct-target", receiver.publicHandle])
        app.buttons["v2.conversation.new-direct"].tap()
        let start = app.buttons["v2.conversation.direct-submit"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); XCTAssertTrue(start.isEnabled); start.tap()
        let draft = app.textFields["v2.message.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 45)); draft.tap(); draft.typeText(text)
        XCTAssertEqual(draft.value as? String, text)
        app.buttons["v2.message.composer.options"].tap()
        app.buttons["v2.message.photo.add"].tap()
        let photo = app.scrollViews["photosView_content_scroll_view"].images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 20)); photo.tap()
        let done = app.navigationBars["照片"].buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); XCTAssertTrue(done.isEnabled); done.tap()
        let staged = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.attachment.remove.")).firstMatch
        XCTAssertTrue(staged.waitForExistence(timeout: 20))
        XCTAssertEqual(draft.value as? String, text)
        attach(app, "Live author selected system photo")
        let send = app.buttons["v2.message.send"]
        XCTAssertTrue(send.isEnabled); send.tap()
        // Only actual projected messages have this container. The durable
        // pending bubble has a separate identity, so its visibility cannot
        // falsely establish server acceptance before switching accounts.
        let accepted = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.attachments.")).firstMatch
        XCTAssertTrue(accepted.waitForExistence(timeout: 90))
        let attachmentID = accepted.identifier
        XCTAssertFalse(app.staticTexts["v2.message.send-feedback"].exists)
        XCTAssertTrue(app.staticTexts[text].exists)
        attach(app, "Live author accepted photo message")
        app.terminate()
        app.launchArguments = receiver.scopeArguments + ["-v2-ui-testing-restore-local-account"]
        app.launch()
        let room = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.conversation.direct.")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 60)); room.tap()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 45))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: attachmentID).firstMatch.waitForExistence(timeout: 20))
        let download = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "v2.message.media.", "下载图片")).firstMatch
        if download.exists { download.tap() }
        requirePhoto(app)
        attach(app, "Independent live recipient decoded the selected photo")
        app.terminate(); app.launch()
        XCTAssertTrue(room.waitForExistence(timeout: 45)); room.tap()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count, 1)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: attachmentID).firstMatch.exists)
        requirePhoto(app)
        attach(app, "Live recipient photo survives process relaunch")
        print("Live resource UI closure: system photo -> real author -> independent recipient -> relaunch")
    }

    @MainActor private func register(_ identity: Identity, app: XCUIApplication, extra: [String] = []) {
        app.launchArguments = identity.registrationArguments + extra
        app.launch()
        let submit = app.buttons["v2.password.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 15)); XCTAssertTrue(submit.isEnabled); submit.tap()
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 45))
    }

    @MainActor private func requirePhoto(_ app: XCUIApplication) {
        let decoded = NSPredicate { _, _ in Self.containsFixturePhoto(app.screenshot()) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: decoded, object: nil)], timeout: 30), .completed)
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    private static func containsFixturePhoto(_ screenshot: XCUIScreenshot) -> Bool {
        guard let image = UIImage(data: screenshot.pngRepresentation)?.cgImage else { return false }
        let width = 128, height = 256
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var matches = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                if (16...48).contains(bytes[i]), (104...140).contains(bytes[i + 1]), (210...246).contains(bytes[i + 2]) { matches += 1 }
            }
            return matches > 80
        }
    }
    private struct Identity {
        let scope = UUID().uuidString
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
        let role: String
        var accountHandle: String { "ui_" + suffix }
        var publicHandle: String { "ui" + suffix }
        var displayName: String { "Resource " + role + " " + suffix }
        var scopeArguments: [String] { ["-v2-ui-testing-live-local-account", "-v2-ui-testing-e2e-scope", scope,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] }
        var registrationArguments: [String] { scopeArguments + ["-v2-ui-testing-password-register",
            "-v2-ui-testing-account-handle", accountHandle, "-v2-ui-testing-public-handle", publicHandle,
            "-v2-ui-testing-local-password", "owned-resource-ui-password", "-v2-ui-testing-display-name", displayName] }
    }
}
