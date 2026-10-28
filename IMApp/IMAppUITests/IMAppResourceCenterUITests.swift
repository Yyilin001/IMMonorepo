import XCTest
import UIKit

final class IMAppResourceCenterUITests: XCTestCase {
    @MainActor func testStorageAndDownloadSettingsWithVoiceOver() throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("VoiceOver automation requires iOS 27 or later.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-AppleLanguages", "(zh-Hans)"]
        addTeardownBlock { @MainActor in
            app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15))
        app.buttons["v2.resources.open"].tap()
        let storage = app.buttons["v2.resources.storage.open"]
        reveal(storage, in: app); storage.tap()

        let voiceOver = XCUIDevice.shared.voiceOverService
        let wasEnabled = voiceOver.isEnabled
        addTeardownBlock { @MainActor in
            if wasEnabled { try voiceOver.enable() } else { try voiceOver.disable() }
            XCTAssertEqual(voiceOver.isEnabled, wasEnabled)
        }
        try voiceOver.enable()
        XCTAssertTrue(voiceOver.isEnabled)
        var speech: [String] = []
        defer {
            let attachment = XCTAttachment(string: speech.joined(separator: "\n"))
            attachment.name = "Actual VoiceOver traversal and settings operation"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        func focus(_ text: String) throws {
            for _ in 0..<45 {
                let utterance = try voiceOver.moveForward().utterance
                speech.append(utterance)
                if utterance.contains(text) { return }
            }
            XCTFail("VoiceOver could not reach \(text)")
            throw NSError(domain: "ResourceVoiceOverTraversal", code: 1)
        }
        try focus("聊天及其他缓存")
        XCTAssertTrue(speech.last?.contains("字节") == true || speech.last?.contains("KB") == true,
                      "Storage must announce the value together with its category")
        try focus("下载设置")
        app.buttons["v2.resources.download-settings.open"].doubleTap()
        XCTAssertTrue(app.navigationBars["下载设置"].waitForExistence(timeout: 5))
        try focus("允许蜂窝网络下载")
        let cellular = app.switches["v2.resources.network.cellular"]
        XCTAssertEqual(cellular.value as? String, "1")
        let before = XCTAttachment(string: speech.joined(separator: "\n") + "\n" + app.debugDescription)
        before.name = "VoiceOver focus before switch activation"; before.lifetime = .keepAlways; add(before)
        let thumb = cellular.switches.firstMatch
        XCTAssertTrue(thumb.exists)
        thumb.doubleTap()
        let disabled = NSPredicate { _, _ in cellular.isEnabled && (cellular.value as? String) == "0" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: disabled, object: nil)], timeout: 5), .completed)
        speech.append(try voiceOver.currentSpeech().utterance)
        try focus("视频")
        let video = app.switches["v2.resources.automatic.video"]
        XCTAssertEqual(video.value as? String, "0")
        video.switches.firstMatch.doubleTap()
        let enabled = NSPredicate { _, _ in video.isEnabled && (video.value as? String) == "1" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: nil)], timeout: 5), .completed)
        speech.append(try voiceOver.currentSpeech().utterance)
        attach(app, name: "VoiceOver changes the persisted cellular preference")
        try voiceOver.disable()
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["存储管理"].waitForExistence(timeout: 5))
        openDownloadSettings(app)
        XCTAssertEqual(app.switches["v2.resources.network.cellular"].value as? String, "0")
        XCTAssertEqual(app.switches["v2.resources.automatic.video"].value as? String, "1")
    }

    @MainActor func testDirectoryPagingAndFilterReturnToTheFirstMatchingPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-directory-pages", "-v2-ui-testing-resource-center-document", "-AppleLanguages", "(zh-Hans)"]
        addTeardownBlock {
            app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        let library = app.buttons["v2.resources.library.open"]
        reveal(library, in: app); library.tap()
        let next = app.buttons["v2.resources.library.next"]
        for _ in 0..<40 where !next.isHittable { app.swipeUp() }
        XCTAssertTrue(next.isHittable && next.isEnabled); next.tap()
        let oldest = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "v2.resources.item.", "分页图片-0")).firstMatch
        XCTAssertTrue(oldest.waitForExistence(timeout: 5))
        let page = app.staticTexts["v2.resources.library.page-number"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let second = NSPredicate { _, _ in page.label == "第 2 页" && !next.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: second, object: nil)], timeout: 5), .completed)
        attach(app, name: "Directory second page contains the remaining actual indexed rows")
        let category = app.buttons["v2.resources.category"]
        for _ in 0..<8 where !category.isHittable { app.swipeDown() }
        XCTAssertTrue(category.isHittable); category.tap(); app.buttons["文件"].tap()
        let file = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "v2.resources.item.", "项目资源管理功能验证与交付说明")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertFalse(next.exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.resources.item.")).count, 1)
        attach(app, name: "Filtering from page two shows the first matching document instead of skipping it")
    }

    @MainActor func testStorageContrastDiagnosticAtTop() throws { try diagnoseStorageContrast(atBottom: false) }
    @MainActor func testDownloadSettingsRespondToSystemTextSize() throws {
        let token = UUID().uuidString
        let marker = FileManager.default.temporaryDirectory.appending(path: "im-resource-system-type-request.json")
        let acknowledgment = FileManager.default.temporaryDirectory.appending(path: "im-resource-system-type-ack.txt")
        func signal(_ phase: String) throws {
            try JSONSerialization.data(withJSONObject: ["token": token, "phase": phase]).write(to: marker, options: .atomic)
        }
        defer {
            try? FileManager.default.removeItem(at: marker)
            if (try? String(contentsOf: acknowledgment, encoding: .utf8)) == token {
                try? FileManager.default.removeItem(at: acknowledgment)
            }
        }
        try signal("await-controller")
        let acknowledged = NSPredicate { _, _ in (try? String(contentsOf: acknowledgment, encoding: .utf8)) == token }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: acknowledged, object: nil)], timeout: 5) == .completed else {
            throw XCTSkip("Run with scripts/verify_v2_resource_dynamic_type.py to change and restore only the dedicated simulator's system text size.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", token, "-AppleLanguages", "(zh-Hans)"]
        addTeardownBlock {
            app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        let storage = app.buttons["v2.resources.storage.open"]
        reveal(storage, in: app); storage.tap(); openDownloadSettings(app)
        let networkLabel = app.staticTexts["允许蜂窝网络下载"].firstMatch
        let fileLabel = app.staticTexts["文件"].firstMatch
        XCTAssertTrue(networkLabel.waitForExistence(timeout: 5)); XCTAssertTrue(fileLabel.exists)
        let networkHeight = networkLabel.frame.height, fileHeight = fileLabel.frame.height
        try signal("grow")
        let grown = NSPredicate { _, _ in networkLabel.exists && networkLabel.frame.height >= networkHeight * 1.8 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: grown, object: nil)], timeout: 20), .completed)
        reveal(fileLabel, in: app)
        let largeFileHeight = fileLabel.frame.height
        XCTAssertGreaterThanOrEqual(largeFileHeight, fileHeight * 1.8)
        attach(app, name: "Download settings after a real system text-size change")
        try signal("restore")
        let restored = NSPredicate { _, _ in networkLabel.exists && abs(networkLabel.frame.height - networkHeight) <= 2 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 20), .completed)
        XCTAssertEqual(app.switches["v2.resources.network.cellular"].value as? String, "1")
        XCTAssertEqual(app.switches["v2.resources.automatic.file"].value as? String, "0")
        let measurements = XCTAttachment(string: "Network label: \(networkHeight); file label: \(fileHeight) → \(largeFileHeight) → \(fileLabel.frame.height)")
        measurements.name = "Real system Dynamic Type measurements"; measurements.lifetime = .keepAlways; add(measurements)
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["存储管理"].waitForExistence(timeout: 5))
    }

    @MainActor func testStorageContrastDiagnosticAtBottom() throws { try diagnoseStorageContrast(atBottom: true) }
    @MainActor func testStorageContrastDiagnosticWithAllDownloadSwitchesEnabled() throws {
        try diagnoseStorageContrast(atBottom: true, enableAllDownloads: true)
    }
    @MainActor private func diagnoseStorageContrast(atBottom: Bool, enableAllDownloads: Bool = false) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-unavailable-retention", "-AppleLanguages", "(zh-Hans)"]
        addTeardownBlock {
            app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        let storage = app.buttons["v2.resources.storage.open"]
        reveal(storage, in: app); storage.tap()
        if enableAllDownloads {
            openDownloadSettings(app)
            for identifier in ["v2.resources.network.constrained", "v2.resources.automatic.video", "v2.resources.automatic.audio", "v2.resources.automatic.file"] {
                let control = app.switches[identifier]
                reveal(control, in: app)
                XCTAssertEqual(control.value as? String, "0")
                let thumb = control.switches.firstMatch
                XCTAssertTrue(thumb.exists)
                thumb.tap()
                let enabled = NSPredicate { _, _ in control.isEnabled && (control.value as? String) == "1" }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: nil)], timeout: 5), .completed)
            }
            try auditStorage(app, name: "Download settings with every automatic type enabled")
            app.buttons["BackButton"].tap()
            XCTAssertTrue(app.navigationBars["存储管理"].waitForExistence(timeout: 5))
        }
        if atBottom {
            let action = app.buttons["v2.resources.retention.unavailable.preview"]
            reveal(action, in: app)
        }
        let viewport = app.scrollViews["v2.resources.storage"]
        XCTAssertTrue(viewport.exists)
        let viewportFrame = viewport.frame
        let navigationFrame = app.navigationBars["存储管理"].frame
        let bounds = XCTAttachment(string: "Scroll view: \(viewportFrame); navigation: \(navigationFrame)")
        bounds.name = "Storage scroll viewport bounds"; bounds.lifetime = .keepAlways; add(bounds)
        attach(app, name: atBottom ? "Contrast diagnostic bottom" : "Contrast diagnostic top")
        try app.performAccessibilityAudit(for: .contrast) { issue in
            let report = XCTAttachment(string: "\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? app.debugDescription)")
            report.name = "Contrast diagnostic issue"; report.lifetime = .keepAlways; self.add(report)
            return false
        }
    }

    @MainActor func testUnavailableRetentionManagementPreservesPrivacyAndReleasesIntent() throws {
        try verifyUnavailableRetention(large: false)
    }

    @MainActor func testUnavailableRetentionManagementSupportsLargeTextAndDarkMode() throws {
        try verifyUnavailableRetention(large: true)
    }

    @MainActor func testUnavailableRetentionManagementFunctionalFlowInLightMode() throws {
        try verifyUnavailableRetention(large: false, audit: false)
    }
    @MainActor func testUnavailableRetentionManagementFunctionalFlowAtLargestText() throws {
        try verifyUnavailableRetention(large: true, audit: false)
    }

    @MainActor private func verifyUnavailableRetention(large: Bool, audit: Bool = true) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-unavailable-retention", "-AppleLanguages", "(zh-Hans)"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-v2-ui-testing-resource-center-dark"] }
        addTeardownBlock {
            app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        let storage = app.buttons["v2.resources.storage.open"]
        reveal(storage, in: app); XCTAssertTrue(storage.isHittable); storage.tap()
        let manage = app.buttons["v2.resources.retention.unavailable.preview"]
        reveal(manage, in: app); XCTAssertTrue(manage.isHittable)
        if audit { try auditStorage(app, name: "Unavailable retention management exposes no protected metadata") }
        reveal(manage, in: app); XCTAssertTrue(manage.isHittable); manage.tap()
        let confirm = app.buttons["解除本次保留"]
        XCTAssertTrue(app.collectionViews["v2.resources.retention.unavailable.sheet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["设计说明与产品界面方案.png"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "本次最多处理 1 项")).firstMatch.exists)
        reveal(confirm, in: app)
        if audit { try auditStorage(app, name: "Unavailable retention scoped confirmation") }
        app.buttons["v2.resources.retention.unavailable.cancel"].tap()
        reveal(manage, in: app); manage.tap(); XCTAssertTrue(app.collectionViews["v2.resources.retention.unavailable.sheet"].waitForExistence(timeout: 5)); reveal(confirm, in: app); confirm.tap()
        let receipt = app.staticTexts["v2.resources.retention.unavailable.feedback"]
        reveal(receipt, in: app)
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertTrue(receipt.label.contains("已解除 1 项保留，跳过 0 项"))
        attach(app, name: "Unavailable retention release receipt")
        reveal(manage, in: app); manage.tap()
        XCTAssertTrue(app.staticTexts["没有需要解除保留的失效资源。"].waitForExistence(timeout: 5))
    }

    @MainActor func testAutomaticDownloadLimitSelectionPersistsAcrossSettingsNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        addTeardownBlock {
            app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        let storage = app.buttons["v2.resources.storage.open"]
        reveal(storage, in: app); storage.tap()
        openDownloadSettings(app)
        let picker = app.buttons["v2.resources.automatic.limit"]
        reveal(picker, in: app); picker.tap()
        let option = app.buttons["v2.resources.automatic.option.1048576"]
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
        XCTAssertTrue(app.navigationBars["下载设置"].waitForExistence(timeout: 5))
        let expected = ByteCountFormatter.string(fromByteCount: 1048576, countStyle: .file)
        let saved = NSPredicate { _, _ in picker.exists && picker.label == "单个文件上限" && picker.value as? String == expected }
        reveal(picker, in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 5), .completed)
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["存储管理"].waitForExistence(timeout: 5))
        openDownloadSettings(app); reveal(picker, in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 5), .completed)
        attach(app, name: "Automatic download limit saved and restored after returning")
    }

    @MainActor func testBatchTaskRetryKeepsOriginalTasksAndCancellationSeparate() {
        let app = batchTaskApp(large: false)
        openTaskBatch(app, large: false)
        let uploadID = "upload.00000000-0000-0000-0000-000000002001"
        let importID = "import.00000000-0000-0000-0000-000000002002"
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Batch task selection element roles"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let semantic = app.descendants(matching: .any).matching(identifier: "v2.resources.transfers.selection.item." + importID).firstMatch
        XCTAssertTrue(semantic.waitForExistence(timeout: 5))
        XCTAssertEqual(semantic.elementType, .button)
        let upload = app.buttons["v2.resources.transfers.selection.item." + uploadID]
        let importing = app.buttons["v2.resources.transfers.selection.item." + importID]
        reveal(upload, in: app); upload.tap(); XCTAssertTrue(upload.isSelected)
        reveal(importing, in: app); importing.tap(); XCTAssertTrue(importing.isSelected)
        let retry = app.buttons["v2.resources.transfers.selection.retry"]
        reveal(retry, in: app); XCTAssertTrue(retry.isEnabled); retry.tap()
        let feedback = app.staticTexts["v2.resources.transfers.feedback"]
        let received = feedback.waitForExistence(timeout: 10)
        attach(app, name: "Actual batch result before validating mixed-operation counts")
        let resultHierarchy = XCTAttachment(string: app.debugDescription)
        resultHierarchy.name = "Actual batch result hierarchy"; resultHierarchy.lifetime = .keepAlways; add(resultHierarchy)
        XCTAssertTrue(received)
        XCTAssertEqual(feedback.label, "已请求 1 项，跳过 1 项，失败 0 项。")
        attach(app, name: "Ordinary batch retry skips cancellation confirmation work")
        reveal(importing, in: app); importing.tap()
        let confirm = app.buttons["v2.resources.transfers.selection.confirm-cancellation"]
        reveal(confirm, in: app); XCTAssertTrue(confirm.isEnabled); confirm.tap()
        let continued = NSPredicate { _, _ in feedback.exists && feedback.label == "已请求 1 项，跳过 0 项，失败 0 项。" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: continued, object: nil)], timeout: 10), .completed)
        app.buttons["v2.resources.transfers.selection.mode"].tap()
        app.segmentedControls["v2.resources.transfers.filter"].buttons["进行中"].tap()
        let originalUpload = app.staticTexts["v2.resources.transfers.item." + uploadID]
        let originalImport = app.staticTexts["v2.resources.transfers.item." + importID]
        reveal(originalUpload, in: app); XCTAssertTrue(originalUpload.exists)
        reveal(originalImport, in: app); XCTAssertTrue(originalImport.exists)
        XCTAssertTrue(app.buttons["正在取消"].firstMatch.exists)
        attach(app, name: "The same upload and cancelling import remain original active tasks")
    }
    @MainActor func testBatchTaskControlsPassAccessibilityAudit() throws { try verifyTaskBatchAudit(large: false) }
    @MainActor func testBatchTaskControlsSupportAccessibilityTextInDarkMode() throws { try verifyTaskBatchAudit(large: true) }
    @MainActor private func verifyTaskBatchAudit(large: Bool) throws {
        let app = batchTaskApp(large: large)
        openTaskBatch(app, large: large)
        let all = app.buttons["v2.resources.transfers.selection.all"]
        reveal(all, in: app); all.tap()
        try auditStorage(app, name: "Batch task controls distinguish retries and cancellation confirmation")
        let row = app.buttons["v2.resources.transfers.selection.item.import.00000000-0000-0000-0000-000000002002"]
        reveal(row, in: app); XCTAssertTrue(row.isSelected)
        try auditStorage(app, name: "Selected task names and current states")
        let explanation = app.buttons["v2.resources.transfers.selection.explanation"]
        reveal(explanation, in: app); explanation.tap()
        let alert = app.alerts["批量处理说明"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["只处理当前支持所选动作的任务。暂停的任务不会自动恢复；取消结果未知时只继续确认取消，不会重新发送。切换页码或任务分组会结束选择。"].exists)
        attach(app, name: "Batch task explanation preserves paused work and cancellation intent")
        alert.buttons["好"].tap()
    }
    @MainActor private func batchTaskApp(large: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-cancel-attention", "-AppleLanguages", "(zh-Hans)"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-v2-ui-testing-resource-center-dark"] }
        addTeardownBlock { @MainActor in
            app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        return app
    }
    @MainActor private func openTaskBatch(_ app: XCUIApplication, large: Bool) {
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        let transfers = app.buttons["v2.resources.transfers.open"]
        reveal(transfers, in: app); transfers.tap()
        if large {
            let picker = app.descendants(matching: .any).matching(identifier: "v2.resources.transfers.filter").firstMatch
            reveal(picker, in: app); picker.tap()
            let attention = app.descendants(matching: .any).matching(identifier: "v2.resources.transfers.group.attention").firstMatch
            XCTAssertTrue(attention.waitForExistence(timeout: 5)); attention.tap()
            if !app.navigationBars["传输任务"].exists { app.buttons["BackButton"].tap() }
        } else { app.segmentedControls["v2.resources.transfers.filter"].buttons["需处理"].tap() }
        let mode = app.buttons["v2.resources.transfers.selection.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10)); mode.tap()
    }

    @MainActor func testImageGridSelectionEndsWhenFilterChanges() throws { try verifyGridSelection(large: false) }
    @MainActor func testResourceSearchFiltersLocalRowsAndClearingRestoresTheFirstPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-directory-pages", "-v2-ui-testing-resource-center-document", "-AppleLanguages", "(zh-Hans)"]
        addTeardownBlock { @MainActor in
            app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        app.buttons["v2.resources.library.open"].tap()
        let search = app.textFields["v2.resources.library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("项目资源管理")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.resources.item."))
        let filtered = NSPredicate { _, _ in
            rows.count == 1 && rows.firstMatch.label.contains("项目资源管理功能验证与交付说明")
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: filtered, object: nil)], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["v2.resources.library.next"].exists)
        app.buttons["v2.resources.library.search.clear"].tap()
        let restored = NSPredicate { _, _ in
            (search.value as? String) == "搜索资源" && rows.count > 1
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["v2.resources.library.search.clear"].exists)
        let next = app.buttons["v2.resources.library.next"]
        for _ in 0..<40 where !next.isHittable { app.swipeUp() }
        XCTAssertTrue(next.isHittable && next.isEnabled)
        XCTAssertEqual(app.staticTexts["v2.resources.library.page-number"].label, "第 1 页")
        attach(app, name: "Clearing local resource search restores the first page and paging capability")
    }
    @MainActor func testImageGridSelectionSupportsAccessibilityTextInDarkMode() throws { try verifyGridSelection(large: true) }
    @MainActor private func verifyGridSelection(large: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-v2-ui-testing-resource-center-dark"] }
        addTeardownBlock { @MainActor in
            app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        reveal(app.buttons["v2.resources.library.open"], in: app); app.buttons["v2.resources.library.open"].tap()
        let category = app.buttons["v2.resources.category"]
        XCTAssertTrue(category.waitForExistence(timeout: 10)); category.tap(); app.buttons["图片"].tap()
        let mode = app.buttons["v2.resources.selection.mode"]
        mode.tap()
        let all = app.buttons["v2.resources.selection.all"]
        reveal(all, in: app); all.tap()
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.resources.selection.item."))
        for _ in 0..<12 where selected.count < 2 { app.swipeUp() }
        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(selected.element(boundBy: 0).isSelected && selected.element(boundBy: 1).isSelected)
        let cached = selected.matching(NSPredicate(format: "label CONTAINS %@", "设计说明与产品界面方案")).firstMatch
        reveal(cached, in: app)
        for _ in 0..<12 where !Self.containsFixtureImage(app.screenshot()) {
            if cached.frame.minY < app.frame.midY { app.swipeDown() }
            else { app.swipeUp() }
        }
        let rendered = NSPredicate { _, _ in Self.containsFixtureImage(app.screenshot()) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rendered, object: nil)], timeout: 10), .completed)
        try auditStorage(app, name: "Selected image grid retains pixels and explicit selection states")
        reveal(category, in: app); category.tap(); app.buttons["文件"].tap()
        let cleared = NSPredicate { _, _ in mode.label == "选择" && !all.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: cleared, object: nil)], timeout: 10), .completed)
        attach(app, name: "Filtering exits selection instead of keeping hidden targets")
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable {
            if element.exists && element.frame.midY < app.frame.midY { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func openDownloadSettings(_ app: XCUIApplication) {
        let settings = app.buttons["v2.resources.download-settings.open"]
        reveal(settings, in: app); settings.tap()
        XCTAssertTrue(app.navigationBars["下载设置"].waitForExistence(timeout: 5))
    }

    @MainActor func testBatchSelectionAndCleanupPassAccessibilityAudit() throws { try verifyBatchAudit(large: false) }
    @MainActor func testBatchSelectionAndCleanupSupportAccessibilityTextInDarkMode() throws { try verifyBatchAudit(large: true) }
    @MainActor private func verifyBatchAudit(large: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-v2-ui-testing-resource-center-dark"] }
        addTeardownBlock { @MainActor in
            app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        let library = app.buttons["v2.resources.library.open"]
        for _ in 0..<12 where !library.isHittable { app.swipeUp() }
        XCTAssertTrue(library.isHittable); library.tap()
        let mode = app.buttons["v2.resources.selection.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10)); mode.tap()
        let all = app.buttons["v2.resources.selection.all"]
        for _ in 0..<12 where !all.isHittable { app.swipeUp() }
        XCTAssertTrue(all.isHittable); all.tap()
        try auditStorage(app, name: "Batch selection and original retention commands")
        let cleanup = app.buttons["v2.resources.selection.cleanup"]
        for _ in 0..<12 where !cleanup.isHittable { app.swipeDown() }
        if !cleanup.isHittable {
            for _ in 0..<12 where !cleanup.isHittable { app.swipeUp() }
        }
        XCTAssertTrue(cleanup.isHittable); cleanup.tap()
        let confirm = app.buttons["v2.resources.selection.cleanup.confirm"]
        XCTAssertTrue(app.navigationBars["所选缓存清理"].waitForExistence(timeout: 10))
        try auditStorage(app, name: "Selected physical cleanup metadata")
        for _ in 0..<12 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        try auditStorage(app, name: "Selected cleanup scope and confirmation")
        app.buttons["v2.resources.selection.cleanup.done"].tap()
    }

    @MainActor func testSelectedResourcesRetainUnretainAndCleanOnlyTheirCache() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        addTeardownBlock { @MainActor in
            app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        app.buttons["v2.resources.library.open"].tap()
        let mode = app.buttons["v2.resources.selection.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10)); mode.tap()
        let all = app.buttons["v2.resources.selection.all"]
        XCTAssertTrue(all.waitForExistence(timeout: 5)); all.tap()
        let retain = app.buttons["v2.resources.selection.retain"]
        XCTAssertTrue(retain.isEnabled); retain.tap()
        let feedback = app.staticTexts["v2.resources.selection.feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 10)); XCTAssertEqual(feedback.label, "已完成 2 项，跳过 0 项，失败 0 项。")
        all.tap(); app.buttons["v2.resources.selection.cleanup"].tap()
        let confirm = app.buttons["v2.resources.selection.cleanup.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); XCTAssertFalse(confirm.isEnabled)
        attach(app, name: "Batch cleanup protects retained files and never includes staging")
        app.buttons["v2.resources.selection.cleanup.done"].tap()
        app.buttons["v2.resources.selection.unretain"].tap()
        XCTAssertTrue(feedback.waitForExistence(timeout: 10)); XCTAssertEqual(feedback.label, "已完成 2 项，跳过 0 项，失败 0 项。")
        all.tap(); app.buttons["v2.resources.selection.cleanup"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); XCTAssertTrue(confirm.isEnabled)
        attach(app, name: "Selected cache cleanup preview uses physical files")
        confirm.tap()
        let cleaned = NSPredicate { _, _ in feedback.exists && feedback.label.hasPrefix("已清理 1 个本机文件") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: cleaned, object: nil)], timeout: 10), .completed)
        attach(app, name: "Batch cleanup reports actual physical release")
        mode.tap()
        let resource = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "v2.resources.item.", "设计说明与产品界面方案")).firstMatch
        for _ in 0..<12 where !resource.isHittable { app.swipeUp() }
        XCTAssertTrue(resource.isHittable); resource.tap()
        XCTAssertTrue(app.buttons["v2.resources.download"].waitForExistence(timeout: 10))
    }

    @MainActor func testDocumentSourceSupportsAccessibilityTextInDarkMode() throws { try verifyDocumentAudit(page: .source, large: true) }
    @MainActor func testDocumentLibraryAndDetailsPassAccessibilityAudit() throws { try verifyDocumentAudit(large: false) }
    @MainActor func testDocumentLibraryAndDetailsSupportAccessibilityTextInDarkMode() throws { try verifyDocumentAudit(large: true) }
    private enum DocumentAuditPage: CaseIterable { case home, library, metadata, actions, source }
    @MainActor private func verifyDocumentAudit(large: Bool) throws {
        for page in DocumentAuditPage.allCases { try verifyDocumentAudit(page: page, large: large) }
    }
    @MainActor private func verifyDocumentAudit(page: DocumentAuditPage, large: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-document", "-AppleLanguages", "(zh-Hans)"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-v2-ui-testing-resource-center-dark"] }
        addTeardownBlock { @MainActor in
            app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
            XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
        }
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        if page == .home { try auditStorage(app, name: "Resource center home"); return }
        let library = app.buttons["v2.resources.library.open"]
        for _ in 0..<12 where !library.isHittable { app.swipeUp() }
        XCTAssertTrue(library.isHittable); library.tap()
        let category = app.buttons["v2.resources.category"]
        XCTAssertTrue(category.waitForExistence(timeout: 5)); category.tap(); app.buttons["文件"].tap()
        let file = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "v2.resources.item.", "项目资源管理功能验证与交付说明")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        for _ in 0..<12 where !file.isHittable { app.swipeUp() }
        XCTAssertTrue(file.isHittable)
        if page == .library { try auditStorage(app, name: "Document library and long filename"); return }
        file.tap()
        XCTAssertTrue(app.navigationBars["资源详情"].waitForExistence(timeout: 5))
        if page == .metadata { try auditStorage(app, name: "Document metadata"); return }
        let retain = app.buttons["v2.resources.retain"]
        for _ in 0..<12 where !retain.isHittable { app.swipeUp() }
        XCTAssertTrue(retain.isHittable)
        if page == .actions {
            try auditStorage(app, name: "Document actions and source")
            let explanation = app.buttons["v2.resources.usage-explanation"]
            for _ in 0..<12 where !explanation.isHittable { app.swipeUp() }
            XCTAssertTrue(explanation.isHittable); explanation.tap()
            let alert = app.alerts["使用与保留说明"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertTrue(alert.staticTexts["查看和分享前会验证当前访问权限。保留本机可防止自动清理，但不会获得永久访问权限。"].exists)
            try auditStorage(app, name: "Resource access and retention explanation")
            alert.buttons["好"].tap()
            return
        }
        // Each system audit gets a fresh process and scope, so its internal
        // font and scroll changes cannot become another page's initial state.
        for id in ["v2.resources.preview", "v2.resources.share"] {
            let control = app.buttons[id]
            for _ in 0..<12 where !control.isHittable { app.swipeUp() }
            XCTAssertTrue(control.isHittable)
        }
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.resources.source.")).firstMatch
        for _ in 0..<12 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.isHittable)
        app.swipeUp()
        XCTAssertTrue(source.isHittable)
        try auditStorage(app, name: "Document source navigation")
    }

    @MainActor func testTransferNetworkWaitPassesAccessibilityAudit() throws { try verifyTransferAudit(large: false) }
    @MainActor func testTransferNetworkWaitSupportsAccessibilityTextInDarkMode() throws { try verifyTransferAudit(large: true) }
    @MainActor private func verifyTransferAudit(large: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-manual-queue", "-v2-ui-testing-resource-center-network-wait", "-AppleLanguages", "(zh-Hans)"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-v2-ui-testing-resource-center-dark"] }
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        let transfers = app.buttons["v2.resources.transfers.open"]
        for _ in 0..<12 where !transfers.isHittable { app.swipeUp() }
        XCTAssertTrue(transfers.isHittable); transfers.tap()
        let waiting = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "等待网络")).firstMatch
        for _ in 0..<12 where !waiting.isHittable { app.swipeUp() }
        XCTAssertTrue(waiting.waitForExistence(timeout: 10))
        try auditStorage(app, name: "Transfer network wait and controls")
        for _ in 0..<12 where !waiting.isHittable { app.swipeUp() }
        XCTAssertTrue(waiting.isHittable); waiting.tap()
        XCTAssertTrue(app.navigationBars["传输状态"].waitForExistence(timeout: 5))
        try auditStorage(app, name: "Transfer wait explanation")
        app.buttons["完成"].tap()
        if large {
            let filter = app.descendants(matching: .any).matching(identifier: "v2.resources.transfers.filter").firstMatch
            for _ in 0..<12 where !filter.isHittable { app.swipeDown() }
            XCTAssertTrue(filter.isHittable); filter.tap()
            let attention = app.descendants(matching: .any).matching(identifier: "v2.resources.transfers.group.attention").firstMatch
            XCTAssertTrue(attention.waitForExistence(timeout: 5)); attention.tap()
            if !app.navigationBars["传输任务"].exists { app.buttons["BackButton"].tap() }
            let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.resources.transfers.retry.")).firstMatch
            XCTAssertTrue(retry.waitForExistence(timeout: 5))
            attach(app, name: "Accessibility status picker opens real attention tasks")
        }
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testCachePolicyNavigationPickerPersistsSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        app.buttons["v2.resources.storage.open"].tap()
        let picker = app.buttons["v2.resources.cache-limit"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertEqual(picker.label, "缓存额度")
        XCTAssertEqual(picker.value as? String, ByteCountFormatter.string(fromByteCount: 512 * 1024 * 1024, countStyle: .file))
        picker.tap()
        let option = app.descendants(matching: .any).matching(identifier: "v2.resources.cache-option.268435456").firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
        if !app.navigationBars["存储管理"].exists { app.buttons["BackButton"].tap() }
        let expected = ByteCountFormatter.string(fromByteCount: 256 * 1024 * 1024, countStyle: .file)
        let selected = NSPredicate { _, _ in picker.label.contains(expected) || (picker.value as? String)?.contains(expected) == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: nil)], timeout: 5), .completed)
        app.buttons["BackButton"].tap(); app.buttons["v2.resources.storage.open"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: nil)], timeout: 5), .completed)
        attach(app, name: "Native cache policy picker persists the selected limit")
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testStorageOverviewAndPoliciesPassAccessibilityAudit() throws { try verifyStorageAudit(large: false) }
    @MainActor func testStorageOverviewSupportsAccessibilityTextInDarkMode() throws { try verifyStorageAudit(large: true) }
    @MainActor private func verifyStorageAudit(large: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-v2-ui-testing-resource-center-dark"] }
        app.launch()
        XCTAssertTrue(app.buttons["v2.resources.open"].waitForExistence(timeout: 15)); app.buttons["v2.resources.open"].tap()
        let storage = app.buttons["v2.resources.storage.open"]
        for _ in 0..<12 where !storage.isHittable { app.swipeUp() }
        XCTAssertTrue(storage.isHittable); storage.tap()
        let cached = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "聊天及其他缓存")).firstMatch
        XCTAssertTrue(cached.waitForExistence(timeout: 10))
        try auditStorage(app, name: "Storage overview")
        let cleanup = app.buttons["v2.resources.cleanup.preview"]
        reveal(cleanup, in: app)
        XCTAssertTrue(cleanup.isHittable)
        try auditStorage(app, name: "Storage actions and cache explanation at the bottom")
        app.buttons["v2.resources.storage.explanation"].tap()
        let explanation = app.alerts["存储统计说明"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertTrue(explanation.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "保留本机和待发送原件按各自用途计入，不重复列为缓存。")).firstMatch.exists)
        explanation.buttons["好"].tap()
        openDownloadSettings(app)
        let automatic = app.switches["v2.resources.automatic.image"]
        for _ in 0..<20 where !automatic.isHittable { app.swipeUp() }
        XCTAssertTrue(automatic.isHittable)
        try auditStorage(app, name: "Automatic download policies")
        let limit = app.buttons["v2.resources.automatic.limit"]
        reveal(limit, in: app)
        XCTAssertTrue(limit.isHittable)
        try auditStorage(app, name: "Automatic download file types and size limit at the bottom")
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }
    @MainActor private func auditStorage(_ app: XCUIApplication, name: String) throws {
        attach(app, name: name)
        try app.performAccessibilityAudit(for: .all) { issue in
            let report = XCTAttachment(string: "\(issue.compactDescription)\n\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? app.debugDescription)")
            report.name = name + " accessibility issue"; report.lifetime = .keepAlways; self.add(report)
            return false
        }
    }

    @MainActor func testAutomaticNetworkWaitExplainsItselfAndPauseRemovesTheWaitLabel() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-manual-queue", "-v2-ui-testing-resource-center-network-wait", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        app.buttons["v2.resources.transfers.open"].tap()
        let waiting = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "等待网络")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 5)); waiting.tap()
        XCTAssertTrue(app.staticTexts["尚未获得可用网络，自动下载意图已保留。网络恢复后会按原任务继续。"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        attach(app, name: "Automatic download explains the actual unavailable network")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.resources.transfers.pause.download.")).firstMatch.tap()
        app.segmentedControls["v2.resources.transfers.filter"].buttons["需处理"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "已暂停")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(waiting.exists)
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testRealQuotaFailureOffersStorageManagementWithoutRetryingAutomatically() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-manual-queue", "-v2-ui-testing-resource-center-space-failure", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        app.buttons["v2.resources.transfers.open"].tap()
        app.segmentedControls["v2.resources.transfers.filter"].buttons["需处理"].tap()
        let storage = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.resources.transfers.manage-storage.")).firstMatch
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        attach(app, name: "Actual local quota denial keeps the original task and offers storage management")
        storage.tap()
        XCTAssertTrue(app.navigationBars["存储管理"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testProfileChoosesExistingImageAndLinksImportToItsChange() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-manual-queue", "-v2-ui-testing-resource-center-profile-picker", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let profile = app.buttons["v2.identity.open"]
        XCTAssertTrue(profile.waitForExistence(timeout: 15)); profile.tap()
        app.buttons["v2.profile.avatar.choose"].tap()
        let choose = app.buttons["v2.profile.avatar.choose-resource"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.tap()
        let search = app.textFields["v2.avatar.resources.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("设计说明")
        let image = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.avatar.resources.item.")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        attach(app, name: "Existing JPEG and PNG picker uses the local resource catalog")
        image.tap()
        XCTAssertTrue(app.staticTexts["正在更新头像…"].waitForExistence(timeout: 5))
        app.buttons["v2.resources.fixture.profile.done"].tap()
        app.buttons["v2.resources.open"].tap(); app.buttons["v2.resources.transfers.open"].tap()
        let owner = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.resources.transfers.owners.")).firstMatch
        XCTAssertTrue(owner.waitForExistence(timeout: 5)); owner.tap()
        XCTAssertTrue(app.navigationBars["相关更改"].waitForExistence(timeout: 5))
        attach(app, name: "Selected image import belongs to the persisted profile change")
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testUnresolvedDownloadShowsPersistentReasonAndControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-manual-queue", "-v2-ui-testing-resource-center-unresolved-demand", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        app.buttons["v2.resources.transfers.open"].tap()
        let unresolved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "等待资源信息")).firstMatch
        XCTAssertTrue(unresolved.waitForExistence(timeout: 5)); unresolved.tap()
        XCTAssertTrue(app.staticTexts["下载需求已保存在本机，正在等待获取资源版本、大小和访问许可。离开页面不会取消任务。"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        attach(app, name: "Unresolved download retains its source demand and available controls")
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testLeavingPreviewDuringAuthorizationKeepsAcceptedDownloadInQueue() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-manual-queue", "-v2-ui-testing-resource-center-wait-for-authorization", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        app.buttons["v2.resources.library.open"].tap()
        let resource = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "v2.resources.item.", "设计说明与产品界面方案")).firstMatch
        XCTAssertTrue(resource.waitForExistence(timeout: 5)); resource.tap()
        app.buttons["v2.resources.preview"].tap()
        XCTAssertTrue(app.staticTexts["正在准备资源"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let transfers = app.buttons["v2.resources.transfers.open"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 5)); transfers.tap()
        XCTAssertTrue(app.staticTexts["设计说明与产品界面方案.png"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "已排队")).firstMatch.waitForExistence(timeout: 5))
        attach(app, name: "Preview page dismissed while original download remains queued")
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testExplicitDownloadPersistsQueueAndPauseResumeKeepsOriginalTask() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-manual-queue", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        app.buttons["v2.resources.library.open"].tap()
        let resource = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "v2.resources.item.", "设计说明与产品界面方案")).firstMatch
        XCTAssertTrue(resource.waitForExistence(timeout: 5)); resource.tap()
        let download = app.buttons["v2.resources.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5)); download.tap()
        XCTAssertTrue(app.staticTexts["已保存下载请求，可在传输任务中查看状态或继续处理。"].waitForExistence(timeout: 5))
        app.buttons["v2.resources.download.tasks"].tap()
        let queued = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "已排队")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 5))
        let prefix = "v2.resources.transfers.pause.download."
        let pause = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        let job = String(pause.identifier.dropFirst(prefix.count))
        attach(app, name: "Explicit download saved in canonical queue")
        pause.tap()
        let filter = app.segmentedControls["v2.resources.transfers.filter"]
        filter.buttons["需处理"].tap()
        let resume = app.buttons["v2.resources.transfers.resume.download." + job]
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); resume.tap()
        filter.buttons["进行中"].tap()
        XCTAssertTrue(app.buttons[prefix + job].waitForExistence(timeout: 5))
        XCTAssertTrue(queued.waitForExistence(timeout: 5))
        attach(app, name: "Same download returned to queue after explicit continuation")
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testProfileOwnerOpensExactDraftAndWithdrawsOnlyThatChange() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-profile-owner", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let transfers = app.buttons["v2.resources.transfers.open"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 5)); transfers.tap()
        app.segmentedControls["v2.resources.transfers.filter"].buttons["需处理"].tap()
        let owners = app.buttons["v2.resources.transfers.owners.upload.00000000-0000-0000-0000-000000002001"]
        XCTAssertTrue(owners.waitForExistence(timeout: 5)); owners.tap()
        let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.resources.owner.profile.")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5)); original.tap()
        attach(app, name: "Selected profile owner initial presentation")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "头像对应的原始昵称")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "另一条更新的资料更改")).firstMatch.exists)
        let dispose = app.buttons["v2.resources.owner.profile.dispose"]
        XCTAssertTrue(dispose.waitForExistence(timeout: 5)); dispose.tap()
        let confirm = app.buttons.matching(identifier: "v2.resources.owner.profile.confirm-dispose").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        attach(app, name: "Resource owner targets original profile draft")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["已放弃此次资料更改。"].waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !dispose.exists }, object: nil)], timeout: 5), .completed)
        attach(app, name: "Original profile draft withdrawn through domain transaction")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["相关更改已处理"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testUnboundCancellationCanBeKeptAndThenConfirmsOriginalTask() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let transfers = app.buttons["v2.resources.transfers.open"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 5)); transfers.tap()
        let filter = app.segmentedControls["v2.resources.transfers.filter"]
        filter.buttons["需处理"].tap()
        let taskID = "upload.00000000-0000-0000-0000-000000002001"
        let cancel = app.buttons["v2.resources.transfers.cancel-unbound." + taskID]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        let confirm = app.buttons.matching(identifier: "v2.resources.transfers.cancel-unbound.confirm").firstMatch
        let keep = app.buttons.matching(identifier: "v2.resources.transfers.cancel-unbound.keep").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); XCTAssertTrue(keep.exists)
        attach(app, name: "Unbound task cancellation requires explicit confirmation")
        keep.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !confirm.exists }, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.staticTexts["已请求取消任务，正在确认原操作结果。"].waitForExistence(timeout: 5))
        filter.buttons["进行中"].tap()
        XCTAssertTrue(app.staticTexts["v2.resources.transfers.item." + taskID].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(identifier: "正在取消").firstMatch.exists)
        attach(app, name: "Original unbound upload awaits authoritative cancellation")
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testImportPauseExplainsLocalScopeAndContinuesOriginalTask() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-pausable-import", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let transfers = app.buttons["v2.resources.transfers.open"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 5)); transfers.tap()
        let taskID = "import.00000000-0000-0000-0000-000000002002"
        let pause = app.buttons["v2.resources.transfers.pause." + taskID]
        XCTAssertTrue(pause.waitForExistence(timeout: 5)); XCTAssertEqual(pause.label, "暂停本机跟进"); pause.tap()
        XCTAssertTrue(app.staticTexts["已请求暂停本机跟进，服务器仍可能继续处理。"].waitForExistence(timeout: 5))
        let filter = app.segmentedControls["v2.resources.transfers.filter"]
        filter.buttons["需处理"].tap()
        let resume = app.buttons["v2.resources.transfers.resume." + taskID]
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); XCTAssertEqual(resume.label, "继续跟进")
        let status = app.buttons.matching(identifier: "本机跟进已暂停").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5)); status.tap()
        XCTAssertTrue(app.staticTexts["本机已停止后续查询，服务器仍可能继续复制和处理资源。继续时将确认同一导入操作，不会新建复制任务。"].waitForExistence(timeout: 5))
        attach(app, name: "Local import pause scope is explicit")
        app.buttons["完成"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); resume.tap()
        let continuationFeedback = app.staticTexts["已请求继续跟进，将确认原导入操作。"]
        XCTAssertTrue(continuationFeedback.waitForExistence(timeout: 5)); XCTAssertTrue(continuationFeedback.isHittable)
        attach(app, name: "Import continuation feedback is visible above the transfer list")
        filter.buttons["进行中"].tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["v2.resources.transfers.item." + taskID].exists)
        attach(app, name: "Same import task resumes local follow-up")
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testUploadPauseAndContinuePreserveTaskAndUseUploadLabels() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-pausable-upload", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let transfers = app.buttons["v2.resources.transfers.open"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 5)); transfers.tap()
        let taskID = "upload.00000000-0000-0000-0000-000000002001"
        let pause = app.buttons["v2.resources.transfers.pause." + taskID]
        XCTAssertTrue(pause.waitForExistence(timeout: 5)); XCTAssertEqual(pause.label, "暂停上传"); pause.tap()
        XCTAssertTrue(app.staticTexts["上传已请求暂停，原文件会保留。"].waitForExistence(timeout: 5))
        let filter = app.segmentedControls["v2.resources.transfers.filter"]
        filter.buttons["需处理"].tap()
        let resume = app.buttons["v2.resources.transfers.resume." + taskID]
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); XCTAssertEqual(resume.label, "继续上传")
        attach(app, name: "Paused upload retains original source and task")
        resume.tap()
        XCTAssertTrue(app.staticTexts["已请求继续上传，将先确认原操作。"].waitForExistence(timeout: 5))
        filter.buttons["进行中"].tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["v2.resources.transfers.item." + taskID].exists)
        attach(app, name: "Original upload reenters account queue")
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testCancellationAttentionOffersOriginalConfirmationAndReturnsToActive() {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
            "-v2-ui-testing-resource-center-cancel-attention", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let transfers = app.buttons["v2.resources.transfers.open"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 5)); transfers.tap()
        let filter = app.segmentedControls["v2.resources.transfers.filter"]
        filter.buttons["需处理"].tap()
        let taskID = "import.00000000-0000-0000-0000-000000002002"
        let retry = app.buttons["v2.resources.transfers.retry-cancellation." + taskID]
        XCTAssertTrue(retry.waitForExistence(timeout: 5)); XCTAssertEqual(retry.label, "继续确认取消")
        XCTAssertTrue(app.buttons["取消待确认"].firstMatch.exists)
        XCTAssertFalse(app.buttons["v2.resources.transfers.retry." + taskID].exists)
        attach(app, name: "Cancellation attention retains original intent")
        retry.tap()
        XCTAssertTrue(app.staticTexts["已请求继续确认取消，将遵守服务器的重试等待时间。"].waitForExistence(timeout: 5))
        filter.buttons["进行中"].tap()
        XCTAssertTrue(app.staticTexts["v2.resources.transfers.item." + taskID].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["正在取消"].firstMatch.waitForExistence(timeout: 5))
        attach(app, name: "Original cancellation resumes without reactivating message")
        app.terminate()
        app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]
        app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }

    @MainActor func testPreparationCancellationShowsMessageScopeBeforeWithdrawingIt() {
        let app = XCUIApplication(), scope = UUID().uuidString
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", scope,
            "-v2-ui-testing-resource-center-pending-message", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let transfers = app.buttons["v2.resources.transfers.open"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 5)); transfers.tap()
        let cancel = app.buttons["v2.resources.transfers.cancel.import.00000000-0000-0000-0000-000000002002"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); XCTAssertEqual(cancel.label, "取消发送"); cancel.tap()
        let confirm = app.buttons.matching(identifier: "v2.resources.transfers.cancel-messages.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); XCTAssertEqual(confirm.label, "取消 1 条消息")
        attach(app, name: "Preparation cancellation confirms parent message scope")
        let keep = app.buttons.matching(identifier: "v2.resources.transfers.cancel-messages.keep").firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5)); keep.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !confirm.exists }, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.staticTexts["已取消待发送消息，正在停止附件准备。"].waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !cancel.exists }, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons.matching(identifier: "正在取消").firstMatch.waitForExistence(timeout: 5))
        attach(app, name: "Parent withdrawn while import original result is reconciled")
        app.terminate()
        app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]
        app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor func testImageGridUsesRealCachedPixelsAndOpensResourceDetails() throws { try verifyMediaGrid(accessibility: false) }
    @MainActor func testAudioDetailsShowMeasuredDuration() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", UUID().uuidString,
                               "-v2-ui-testing-resource-center-timed-media", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        app.buttons["v2.resources.library.open"].tap()
        let category = app.buttons["v2.resources.category"]
        XCTAssertTrue(category.waitForExistence(timeout: 5)); category.tap(); app.buttons["音频"].tap()
        let resource = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "v2.resources.item.", "实测音频")).firstMatch
        XCTAssertTrue(resource.waitForExistence(timeout: 5)); resource.tap()
        let duration = app.descendants(matching: .any).matching(identifier: "v2.resources.duration").firstMatch
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertEqual(duration.value as? String, "2 秒")
        try auditStorage(app, name: "Audio metadata details")
        attach(app, name: "Audio measured duration")
        app.terminate(); app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]; app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10)); app.terminate()
    }
    @MainActor func testImageGridSupportsAccessibilityTextInDarkMode() throws { try verifyMediaGrid(accessibility: true) }

    @MainActor private func verifyMediaGrid(accessibility: Bool) throws {
        let app = XCUIApplication(), scope = UUID().uuidString
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", scope, "-AppleLanguages", "(zh-Hans)"]
        if accessibility { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-v2-ui-testing-resource-center-dark"] }
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let library = app.buttons["v2.resources.library.open"]
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        let category = app.buttons["v2.resources.category"]
        XCTAssertTrue(category.waitForExistence(timeout: 5)); category.tap()
        app.buttons["图片"].tap()
        let resource = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "v2.resources.item.", "设计说明与产品界面方案")).firstMatch
        XCTAssertTrue(resource.waitForExistence(timeout: 10))
        if accessibility && !resource.isHittable { app.swipeUp() }
        let rendered = NSPredicate { _, _ in Self.containsFixtureImage(app.screenshot()) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rendered, object: nil)], timeout: 15), .completed)
        attach(app, name: "Resource grid before full accessibility audit")
        try app.performAccessibilityAudit(for: .all) { issue in
            let report = XCTAttachment(string: "\(issue.compactDescription)\n\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? app.debugDescription)")
            report.name = "Resource grid accessibility issue"; report.lifetime = .keepAlways; self.add(report)
            return false
        }
        attach(app, name: accessibility ? "Resource image grid accessibility dark" : "Resource image grid cached pixels")
        resource.tap()
        XCTAssertTrue(app.navigationBars["资源详情"].waitForExistence(timeout: 5))
        let dimensions = app.descendants(matching: .any).matching(identifier: "v2.resources.image-dimensions").firstMatch
        for _ in 0..<4 where !dimensions.exists { app.swipeUp() }
        XCTAssertTrue(dimensions.waitForExistence(timeout: 5))
        XCTAssertEqual(dimensions.value as? String, "320 × 200 像素")
        try app.performAccessibilityAudit(for: .all) { issue in
            let report = XCTAttachment(string: "\(issue.compactDescription)\n\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? app.debugDescription)")
            report.name = "Resource detail accessibility issue"; report.lifetime = .keepAlways; self.add(report)
            return false
        }
        attach(app, name: "Resource detail shows original dimensions")
        for _ in 0..<4 where !app.buttons["v2.resources.preview"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["v2.resources.preview"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]
        app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10))
        app.terminate()
    }

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testDownloadNetworkPreferencesSurviveLeavingStoragePage() {
        let app = XCUIApplication(), scope = UUID().uuidString
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", scope, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let storage = app.buttons["v2.resources.storage.open"]
        XCTAssertTrue(storage.waitForExistence(timeout: 5)); storage.tap()
        openDownloadSettings(app)
        let cellular = app.switches["v2.resources.network.cellular"]
        let constrained = app.switches["v2.resources.network.constrained"]
        if !cellular.isHittable { app.swipeUp() }
        XCTAssertTrue(cellular.waitForExistence(timeout: 5))
        XCTAssertEqual(cellular.value as? String, "1")
        attach(app, name: "Download network preferences before editing")
        cellular.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let savedCellular = NSPredicate { _, _ in cellular.value as? String == "0" && cellular.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: savedCellular, object: nil)], timeout: 5), .completed)
        if !constrained.isHittable { app.swipeUp() }
        constrained.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let savedConstrained = NSPredicate { _, _ in constrained.value as? String == "1" && constrained.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: savedConstrained, object: nil)], timeout: 5), .completed)
        let video = app.switches["v2.resources.automatic.video"]
        for _ in 0..<3 where !video.isHittable { app.swipeUp() }
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        XCTAssertEqual(video.value as? String, "0")
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let savedVideo = NSPredicate { _, _ in video.value as? String == "1" && video.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: savedVideo, object: nil)], timeout: 5), .completed)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["存储管理"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(storage.waitForExistence(timeout: 5)); storage.tap()
        openDownloadSettings(app)
        if !cellular.isHittable { app.swipeUp() }
        XCTAssertTrue(cellular.waitForExistence(timeout: 5))
        XCTAssertEqual(cellular.value as? String, "0")
        XCTAssertEqual(constrained.value as? String, "1")
        for _ in 0..<3 where !video.isHittable { app.swipeUp() }
        XCTAssertEqual(video.value as? String, "1")
        app.swipeUp()
        attach(app, name: "Persisted download network preferences")
        app.terminate()
        app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]
        app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor func testActiveDownloadPauseAndResume() { verifyActiveControl(cancel: false) }
    @MainActor func testActiveDownloadCancellation() { verifyActiveControl(cancel: true) }

    @MainActor private func verifyActiveControl(cancel: Bool) {
        let app = XCUIApplication(), scope = UUID().uuidString
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", scope,
            "-v2-ui-testing-resource-center-active-download", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let transfers = app.buttons["v2.resources.transfers.open"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 5)); transfers.tap()
        let filter = app.segmentedControls["v2.resources.transfers.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.buttons["需处理"].tap()
        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.resources.transfers.retry.download.")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        let taskID = String(retry.identifier.dropFirst("v2.resources.transfers.retry.".count))
        retry.tap(); filter.buttons["进行中"].tap()
        let control = app.buttons["v2.resources.transfers." + (cancel ? "cancel." : "pause.") + taskID]
        XCTAssertTrue(control.waitForExistence(timeout: 5)); control.tap()
        if cancel {
            filter.buttons["已结束"].tap()
            XCTAssertTrue(app.staticTexts["v2.resources.transfers.item." + taskID].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["已取消"].exists)
            attach(app, name: "Active download cancelled after physical drain")
        } else {
            filter.buttons["需处理"].tap()
            let resume = app.buttons["v2.resources.transfers.resume." + taskID]
            XCTAssertTrue(resume.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["已暂停"].exists)
            attach(app, name: "Active download paused with checkpoint retained")
            resume.tap(); filter.buttons["已结束"].tap()
            XCTAssertTrue(app.staticTexts["v2.resources.transfers.item." + taskID].waitForExistence(timeout: 10))
            attach(app, name: "Paused download resumed under original identity")
        }
        app.terminate()
        app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]
        app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testRetryDownloadFinishesOriginalTaskAfterLeavingTransferPage() {
        let app = XCUIApplication(), scope = UUID().uuidString
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", scope, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let transfers = app.buttons["v2.resources.transfers.open"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 5)); transfers.tap()
        let filter = app.segmentedControls["v2.resources.transfers.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.buttons["需处理"].tap()
        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.resources.transfers.retry.download.")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        let taskID = String(retry.identifier.dropFirst("v2.resources.transfers.retry.".count))
        retry.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(transfers.waitForExistence(timeout: 5)); transfers.tap()
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.buttons["已结束"].tap()
        let originalTask = app.staticTexts["v2.resources.transfers.item." + taskID]
        XCTAssertTrue(originalTask.waitForExistence(timeout: 10))
        XCTAssertEqual(originalTask.label, "下载中断图片.png")
        attach(app, name: "Retried download completed under original task identity")
        app.terminate()
        app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]
        app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testAccountEntryDetailRetentionPreviewAndCleanup() {
        // Initialize the dedicated simulator's local document browser before
        // invoking its Save to Files activity for the first time.
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        files.launch()
        let welcome = files.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "欢迎", "文件")).firstMatch
        if welcome.waitForExistence(timeout: 3) {
            let next = files.buttons["继续"]
            XCTAssertTrue(next.waitForExistence(timeout: 5)); next.tap()
        }
        let browseFiles = files.buttons["浏览"].firstMatch
        let browser = XCTAttachment(string: files.debugDescription)
        browser.name = "System Files browser initialization"; browser.lifetime = .keepAlways; add(browser)
        XCTAssertTrue(browseFiles.waitForExistence(timeout: 30)); browseFiles.tap()
        attach(files, name: "Dedicated simulator local file browser")
        files.terminate()
        let app = XCUIApplication(), scope = UUID().uuidString
        print("Resource share UI scope: \(scope)")
        app.launchArguments = ["-v2-ui-testing-signed-out", "-v2-ui-testing-resource-center-scope", scope, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let entry = app.buttons["v2.resources.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let transfers = app.buttons["v2.resources.transfers.open"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 5)); transfers.tap()
        let filter = app.segmentedControls["v2.resources.transfers.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.buttons["需处理"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.resources.transfers.cancel.download.")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        attach(app, name: "Interrupted foreground download awaiting action")
        cancel.tap()
        XCTAssertTrue(app.staticTexts["已请求取消，传输停止后会清理断点暂存。"].waitForExistence(timeout: 5))
        filter.buttons["已结束"].tap()
        XCTAssertTrue(app.staticTexts["下载中断图片.png"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["设计说明与产品界面方案.png"].waitForExistence(timeout: 5))
        attach(app, name: "Completed and cancelled download history")
        filter.buttons["需处理"].tap()
        let retry = app.buttons["v2.resources.transfers.retry.upload.00000000-0000-0000-0000-000000002001"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        attach(app, name: "Canonical transfer needing attention")
        retry.tap()
        XCTAssertTrue(app.staticTexts["已恢复原任务，将继续确认处理结果。"].waitForExistence(timeout: 5))
        filter.buttons["进行中"].tap()
        XCTAssertTrue(app.staticTexts["待处理头像.png"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let browse = app.buttons["v2.resources.library.open"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5)); browse.tap()
        let resource = app.buttons.containing(.staticText, identifier: "设计说明与产品界面方案.png").firstMatch
        XCTAssertTrue(resource.waitForExistence(timeout: 5)); resource.tap()
        let retain = app.buttons["v2.resources.retain"]
        XCTAssertTrue(retain.waitForExistence(timeout: 5)); retain.tap()
        let retained = NSPredicate { _, _ in retain.label == "解除保留本机" && retain.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: retained, object: nil)], timeout: 5), .completed)
        attach(app, name: "Resource detail with retained original")
        app.buttons["v2.resources.share"].tap()
        let closeShare = app.buttons["header.closeButton"]
        XCTAssertTrue(closeShare.waitForExistence(timeout: 10))
        let caption = app.otherElements["LP.CaptionBar.TopCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(caption.label, "设计说明与产品界面方案")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "System local file share hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        attach(app, name: "System share receives a local resource file")
        let saveToFiles = app.cells.matching(NSPredicate(format: "label == %@", "保存到“文件”")).firstMatch
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 5)); saveToFiles.tap()
        let name = app.textFields.matching(NSPredicate(format: "value IN %@", ["设计说明与产品界面方案.png", "设计说明与产品界面方案"])).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 60))
        attach(app, name: "Files export preserves the original filename before cancellation")
        let cancelExport = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        if !cancelExport.exists {
            let back = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        }
        let exportHierarchy = XCTAttachment(string: app.debugDescription)
        exportHierarchy.name = "Files export destination root cancellation"; exportHierarchy.lifetime = .keepAlways; add(exportHierarchy)
        XCTAssertTrue(cancelExport.waitForExistence(timeout: 5)); cancelExport.tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        if closeShare.waitForExistence(timeout: 2) { closeShare.tap() }
        XCTAssertTrue(closeShare.waitForNonExistence(timeout: 5))
        XCTAssertTrue(retain.isEnabled)
        app.buttons["v2.resources.preview"].tap()
        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        // A visible sheet alone does not prove Quick Look decoded the file.
        // The isolated fixture is a blue PNG; detect its rendered payload
        // across the screenshot, independently of navigation coordinates.
        let rendered = NSPredicate { _, _ in Self.containsFixtureImage(app.screenshot()) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rendered, object: nil)], timeout: 15), .completed)
        attach(app, name: "Quick Look resource preview")
        done.tap()
        XCTAssertTrue(retain.waitForExistence(timeout: 5)); retain.tap()
        let released = NSPredicate { _, _ in retain.label == "保留本机" && retain.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: released, object: nil)], timeout: 5), .completed)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let storage = app.buttons["v2.resources.storage.open"]
        XCTAssertTrue(storage.waitForExistence(timeout: 5)); storage.tap()
        let cleanup = app.buttons["v2.resources.cleanup.preview"]
        for _ in 0..<3 where !cleanup.isHittable { app.swipeUp() }
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5)); cleanup.tap()
        let confirm = app.buttons["v2.resources.cleanup.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); XCTAssertTrue(confirm.isEnabled)
        attach(app, name: "Cleanup physical resource preview")
        confirm.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已释放")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(browse.waitForExistence(timeout: 5)); browse.tap()
        XCTAssertTrue(resource.waitForExistence(timeout: 5)); resource.tap()
        // The exact file shared and previewed must now need a download. Other
        // cache rows being cleaned cannot hide a leaked platform file lease.
        XCTAssertTrue(app.buttons["v2.resources.download"].waitForExistence(timeout: 10))
        attach(app, name: "Shared and previewed file is cleanable after dismissal")
        app.terminate()
        app.launchArguments += ["-v2-ui-testing-resource-center-cleanup"]
        app.launch()
        XCTAssertTrue(app.staticTexts["测试数据已清理"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private static func containsFixtureImage(_ screenshot: XCUIScreenshot) -> Bool {
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
            return blue > width * height / 50
        }
    }
}
