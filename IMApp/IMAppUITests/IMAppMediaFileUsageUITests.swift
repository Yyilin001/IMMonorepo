import XCTest

final class IMAppMediaFileUsageUITests: XCTestCase {
    @MainActor func testProductionShareSavesNamedAudioCopyToFiles() {
        continueAfterFailure = false
        let app = XCUIApplication(), scope = UUID().uuidString
        // The paired host verifier checks these exact synthetic bytes after
        // this App has terminated, then removes only this UUID-named export.
        let exportName = "资源导出-" + scope + ".wav"
        let arguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-media-scope", scope,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments = arguments
        addTeardownBlock { @MainActor in
            app.terminate(); app.launchArguments = arguments + ["-v2-ui-testing-media-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        let share = app.buttons["v2.file-use.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 15)); share.tap()
        let save = app.cells.matching(NSPredicate(format: "label == %@", "保存到“文件”")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.waitForExistence(timeout: 15))
        XCTAssertTrue([exportName, (exportName as NSString).deletingPathExtension].contains(filename.value as? String ?? ""))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Production named audio export before save"; screenshot.lifetime = .keepAlways; add(screenshot)
        let commit = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(commit.isEnabled); commit.tap()
        XCTAssertTrue(filename.waitForNonExistence(timeout: 15))
        print("System Files export completed: " + exportName)
    }

    @MainActor func testNativeDocumentExportCanOpenLocalDestinationBrowser() {
        continueAfterFailure = false
        let app = XCUIApplication(), scope = UUID().uuidString
        let arguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-media-scope", scope,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments = arguments
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments = arguments + ["-v2-ui-testing-media-cleanup"]
            app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10))
            app.terminate()
        }
        app.launch()
        let export = app.buttons["v2.file-use.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 15)); export.tap()
        let filename = app.textFields["DOCPicker.filenameTextField"]
        let ready = filename.waitForExistence(timeout: 30)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Direct native document export hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Direct native document export control"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertTrue(ready, "The native file browser must load independently of the share provider")
        app.buttons["v2.file-use.dismiss"].tap()
        XCTAssertTrue(filename.waitForNonExistence(timeout: 5))
    }

    @MainActor func testURLShareCanOpenSystemFileExport() {
        continueAfterFailure = false
        let app = XCUIApplication(), scope = UUID().uuidString
        let arguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-media-scope", scope,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments = arguments
        addTeardownBlock { @MainActor in
            app.terminate(); app.launchArguments = arguments + ["-v2-ui-testing-media-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        let share = app.buttons["v2.file-use.url-share"]
        XCTAssertTrue(share.waitForExistence(timeout: 15)); share.tap()
        let save = app.cells.matching(NSPredicate(format: "label == %@", "保存到“文件”")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
        let filename = app.textFields["DOCPicker.filenameTextField"]
        let ready = filename.waitForExistence(timeout: 30)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "URL share document export control"; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "URL share document export hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTAssertTrue(ready)
    }

    @MainActor func testPlayerRetainsRetiredFileUntilDismissalAndAccountClose() throws { try exercise("player") }
    @MainActor func testSystemShareRetainsRetiredFileUntilDismissalAndAccountClose() throws { try exercise("share") }

    @MainActor private func exercise(_ kind: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication(), scope = UUID().uuidString
        let arguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-media-scope", scope,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments = arguments
        addTeardownBlock { @MainActor () async throws -> Void in
            app.terminate()
            app.launchArguments = arguments + ["-v2-ui-testing-media-cleanup"]
            app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10))
            app.terminate()
        }
        app.launch()
        let open = app.buttons["v2.file-use." + kind]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        if kind == "player" {
            let play = app.buttons["播放音频"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: play)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            play.tap()
            XCUIDevice.shared.press(.home)
            app.activate()
            let resumed = app.buttons["播放音频"]
            let readyAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: resumed)
            XCTAssertEqual(XCTWaiter.wait(for: [readyAgain], timeout: 10), .completed)
        }
        let discard = app.buttons["v2.file-use.discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10)); discard.tap()
        XCTAssertTrue(app.staticTexts["使用中的文件已保留"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Retired file retained by " + kind
        screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["v2.file-use.dismiss"].tap()
        let close = app.buttons["v2.file-use.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10)); close.tap()
        XCTAssertTrue(app.staticTexts["关闭完成"].waitForExistence(timeout: 10))
    }
}
