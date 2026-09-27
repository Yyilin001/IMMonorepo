import XCTest

final class IMAppMediaFileUsageUITests: XCTestCase {
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
