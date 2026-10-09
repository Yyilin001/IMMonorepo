import Foundation
import XCTest

extension IMAppLocalTwoInstallE2ETests {
    private struct NativeUploadObservation: Decodable {
        let hits: Int
        let readBytes: Int
        let released: Bool
        let completed: Int
        let status: Int
        let checksumMatches: Bool
        let expired: Bool
        let durableActiveMappings: Int
    }

    @MainActor
    private func nativeUploadObservation(release: Bool = false) async throws -> NativeUploadObservation {
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["IMAPP_BACKGROUND_FIXTURE_TOKEN"])
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://localhost:8443/__fixture__/background-upload/" + (release ? "release" : "state"))))
        request.httpMethod = release ? "POST" : "GET"
        request.setValue(token, forHTTPHeaderField: "X-Background-Fixture")
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(NativeUploadObservation.self, from: data)
    }

    @MainActor
    private func openNativeUploadGroup(in app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 30))
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["IMAPP_BACKGROUND_GROUP_TITLE"])
        let group = app.staticTexts[title].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30) && group.isHittable)
        group.tap()
        XCTAssertTrue(app.textFields["v2.message.draft"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testRealAppUploadsAttachmentWhileSuspended() async throws {
        let app = XCUIApplication()
        app.activate()
        try openNativeUploadGroup(in: app)
        let folder = try XCTUnwrap(ProcessInfo.processInfo.environment["IMAPP_BACKGROUND_FILE_FOLDER"])
        let text = try XCTUnwrap(ProcessInfo.processInfo.environment["IMAPP_BACKGROUND_MESSAGE_TEXT"])
        app.buttons["v2.message.composer.options"].tap()
        let addAttachment = app.buttons["v2.message.attachment.add"]
        XCTAssertTrue(addAttachment.waitForExistence(timeout: 5) && addAttachment.isEnabled)
        addAttachment.tap()

        // Use the system document picker. The orchestration script prepares
        // only an ordinary file in this simulator's own Files local provider.
        let browse = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "浏览", "Browse")).firstMatch
        if browse.waitForExistence(timeout: 3) && browse.isHittable { browse.tap() }
        // Select a location row, not the same-named navigation title when
        // Files is already showing its local root.
        let local = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@", "我的iPhone", "我的 iPhone", "On My iPhone")).firstMatch
        if local.waitForExistence(timeout: 2) && local.isHittable { local.tap() }
        let directory = app.cells.matching(identifier: folder + ", Folder").firstMatch
        let picker = XCTAttachment(string: app.debugDescription)
        picker.name = "native-background-upload-file-picker"
        picker.lifetime = .keepAlways
        add(picker)
        XCTAssertTrue(directory.waitForExistence(timeout: 10) && directory.isHittable)
        // Files exposes the folder icon as a distinct hit target. Tapping its
        // long, truncated filename did not navigate in the observed grid.
        let folderIcon = directory.images.firstMatch
        XCTAssertTrue(folderIcon.exists && folderIcon.isHittable)
        folderIcon.tap()
        let file = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "background-upload")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10) && file.isHittable)
        let document = XCTAttachment(string: app.debugDescription)
        document.name = "native-background-upload-document-cell"
        document.lifetime = .keepAlways
        add(document)
        // The actual file Cell is hittable; its thumbnail Image was not.
        // Select the ordinary document Cell rather than its decorative image.
        file.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "v2.message.attachments").firstMatch.waitForExistence(timeout: 15))
        let draft = app.textFields["v2.message.draft"]
        draft.tap()
        draft.typeText(text)
        let send = app.buttons["v2.message.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()

        var observation = try await nativeUploadObservation()
        let startedBy = ContinuousClock.now.advanced(by: .seconds(60))
        while (observation.hits == 0 || observation.readBytes == 0) && ContinuousClock.now < startedBy {
            try await Task.sleep(for: .milliseconds(100))
            observation = try await nativeUploadObservation()
        }
        XCTAssertEqual(observation.hits, 1, "必须观察到真实后台授权PUT，不能把前台上传算成系统后台上传。")
        XCTAssertGreaterThan(observation.readBytes, 0)
        XCTAssertFalse(observation.released)
        XCUIDevice.shared.press(.home)
        let suspendedBy = ContinuousClock.now.advanced(by: .seconds(90))
        while app.state != .runningBackgroundSuspended && ContinuousClock.now < suspendedBy {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(app.state, .runningBackgroundSuspended, "必须实际挂起App后再释放系统上传，不能用进入后台代替挂起。")
        XCTContext.runActivity(named: "native-background-upload-app-suspended") { _ in }
        observation = try await nativeUploadObservation(release: true)
        XCTAssertEqual(observation.durableActiveMappings, 1, "挂起时必须有本次原上传的持久化系统任务映射。")
        let completedBy = ContinuousClock.now.advanced(by: .seconds(45))
        while observation.completed == 0 && ContinuousClock.now < completedBy {
            try await Task.sleep(for: .milliseconds(100))
            observation = try await nativeUploadObservation()
        }
        XCTAssertEqual(observation.completed, 1)
        XCTAssertTrue((200..<300).contains(observation.status))
        XCTAssertTrue(observation.checksumMatches)
        XCTAssertEqual(observation.readBytes, 512 * 1024)
        XCTAssertFalse(observation.expired)
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "v2.message.body.", text)).firstMatch.waitForExistence(timeout: 60))
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testRealAppColdRestoresBackgroundAttachment() throws {
        let app = XCUIApplication()
        app.activate()
        try openNativeUploadGroup(in: app)
        let text = try XCTUnwrap(ProcessInfo.processInfo.environment["IMAPP_BACKGROUND_MESSAGE_TEXT"])
        let rawID = try XCTUnwrap(ProcessInfo.processInfo.environment["IMAPP_BACKGROUND_MESSAGE_ID"])
        let id = try XCTUnwrap(UUID(uuidString: rawID)).uuidString
        let body = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label == %@", "v2.message.body.\(id)", text))
        XCTAssertTrue(body.firstMatch.waitForExistence(timeout: 30))
        XCTAssertEqual(body.count, 1)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "v2.message.attachments.\(id)").firstMatch.exists)
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }
}
