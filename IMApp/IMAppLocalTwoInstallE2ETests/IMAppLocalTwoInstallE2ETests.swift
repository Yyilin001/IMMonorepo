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
        let newGroup = app.buttons["v2.conversation.new-group"]
        XCTAssertTrue(newGroup.isHittable)
        newGroup.tap()
        let groupTitle = app.textFields["v2.conversation.group-title"]
        XCTAssertTrue(
            groupTitle.waitForExistence(timeout: 10) && groupTitle.isHittable,
            "新建群聊必须由唯一的会话创建呈现状态打开，并提供可访问的群名称输入。"
        )
        XCTAssertFalse(
            (groupTitle.value as? String ?? "").isEmpty,
            "本机回归启动夹具必须只预填群名称，仍由真实已认证的建群命令创建会话。"
        )
        let createGroup = app.buttons["v2.conversation.group-submit"]
        XCTAssertTrue(createGroup.isEnabled)
        createGroup.tap()
        let groupMembers = app.buttons["v2.group.members"]
        XCTAssertTrue(
            groupMembers.waitForExistence(timeout: 30),
            "创建仅自己的群聊后必须进入群详情，并提供成员管理入口。"
        )
        try auditOrdinaryChatSurface(in: app)
        groupMembers.tap()
        let groupMembersSheet = app.collectionViews["v2.group.members.sheet"]
        XCTAssertTrue(
            groupMembersSheet.waitForExistence(timeout: 15),
            "群成员入口必须打开可供辅助技术定位的成员页。"
        )
        let closeGroupMembers = app.buttons["v2.group.members.close"]
        XCTAssertTrue(closeGroupMembers.isHittable)
        closeGroupMembers.tap()
        XCTAssertTrue(groupMembers.waitForExistence(timeout: 5))
        // The system-owned navigation back button is the only control here
        // without an app identifier. The test otherwise uses stable IDs.
        let backToConversationList = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backToConversationList.isHittable)
        backToConversationList.tap()
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 5))
        app.buttons["v2.account-menu"].tap()
        let privacySettings = app.buttons["v2.privacy.open"]
        XCTAssertTrue(privacySettings.waitForExistence(timeout: 5))
        privacySettings.tap()
        XCTAssertTrue(
            app.switches["v2.privacy.allow-stranger-messages"].waitForExistence(timeout: 15),
            "账户菜单必须能打开已认证的陌生人消息接收设置。"
        )
        XCTAssertTrue(
            app.switches["v2.privacy.allow-stranger-messages"].isHittable,
            "陌生人消息接收开关必须可由辅助技术定位并操作。"
        )
        try auditPrivacySettingsSurface(in: app)
        let done = app.buttons["v2.privacy.done"]
        XCTAssertTrue(done.exists)
        done.tap()
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 5))
        app.buttons["v2.account-menu"].tap()
        let publicIdentity = app.buttons["v2.identity.open"]
        XCTAssertTrue(publicIdentity.waitForExistence(timeout: 5))
        publicIdentity.tap()
        XCTAssertTrue(
            app.textFields["v2.identity.display-name.edit"].waitForExistence(timeout: 15),
            "账户菜单必须能打开已认证的公开身份资料页面。"
        )
        XCTAssertTrue(
            app.textFields["v2.identity.display-name.edit"].isHittable,
            "公开身份资料的显示名称必须可由辅助技术定位并编辑。"
        )
        let identityDone = app.buttons["v2.identity.done"]
        XCTAssertTrue(identityDone.exists)
        identityDone.tap()
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 5))
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

        let draft = app.textViews["v2.message.draft"]
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
        let messageRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.row.")
        ).firstMatch
        XCTAssertTrue(
            messageRow.waitForExistence(timeout: 15),
            "发送端同步投影必须实际渲染刚发送的消息，才能继续执行消息操作。"
        )
        let messageID = messageRow.identifier.replacingOccurrences(of: "v2.message.row.", with: "")
        XCTAssertFalse(messageID.isEmpty)
        let reactionPicker = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "v2.message.reaction-picker.\(messageID)")
        ).firstMatch
        let reactionPickerIsHittable = reactionPicker.waitForExistence(timeout: 5) && reactionPicker.isHittable
        if !reactionPickerIsHittable {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "two-install-reaction-picker-not-hittable"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "two-install-reaction-picker-ui-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("反应入口必须在发送消息后可见并可点击。")
        }
        reactionPicker.tap()
        let thumbsUp = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "v2.message.reaction-picker.\(messageID).👍")
        ).firstMatch
        XCTAssertTrue(
            thumbsUp.waitForExistence(timeout: 5),
            "反应菜单必须暴露带稳定 identifier 的反应选项。"
        )
        thumbsUp.tap()
        let actionFeedback = app.staticTexts["v2.message.action-feedback"]
        XCTAssertTrue(
            actionFeedback.waitForExistence(timeout: 30),
            "反应必须经真实持久化命令提交，并反馈正在同步的状态。"
        )
        XCTAssertTrue(actionFeedback.label.contains("反应已提交") || actionFeedback.label.contains("反应已安全保存"))
        messageRow.press(forDuration: 1)
        let edit = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "v2.message.edit.\(messageID)")
        ).firstMatch
        XCTAssertTrue(
            edit.waitForExistence(timeout: 5) && edit.isHittable,
            "发送端长按自己的消息后必须能打开可定位的编辑操作。"
        )
        edit.tap()
        let editText = app.textViews["v2.message.edit-text"]
        XCTAssertTrue(
            editText.waitForExistence(timeout: 10) && editText.isHittable,
            "编辑页必须提供可由辅助技术定位并输入的消息编辑器。"
        )
        let messageBody = app.staticTexts["v2.message.body.\(messageID)"]
        XCTAssertTrue(messageBody.exists)
        let originalMessageText = messageBody.label
        editText.tap()
        // The affected simulator runtime truncates a single typeText call to
        // its first character. One appended character is enough to exercise
        // the real edit command without bypassing the editable UI.
        editText.typeText("x")
        let saveEdit = app.buttons["v2.message.edit-save"]
        XCTAssertTrue(saveEdit.isHittable && saveEdit.isEnabled)
        saveEdit.tap()
        let editFeedback = expectation(
            for: NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "编辑已提交",
                "编辑已安全保存"
            ),
            evaluatedWith: actionFeedback
        )
        wait(for: [editFeedback], timeout: 30)
        let projectionChanged = expectation(
            for: NSPredicate(format: "label != %@", originalMessageText),
            evaluatedWith: messageBody
        )
        wait(for: [projectionChanged], timeout: 30)
        XCTAssertTrue(messageRow.waitForExistence(timeout: 5))
        messageRow.press(forDuration: 1)
        let withdraw = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "v2.message.withdraw.\(messageID)")
        ).firstMatch
        XCTAssertTrue(
            withdraw.waitForExistence(timeout: 5) && withdraw.isHittable,
            "发送端长按自己的消息后必须能打开可定位的撤回操作。"
        )
        withdraw.tap()
        XCTAssertTrue(
            actionFeedback.waitForExistence(timeout: 30),
            "撤回必须经真实持久化命令提交，并反馈正在同步的状态。"
        )
        XCTAssertTrue(actionFeedback.label.contains("撤回已提交") || actionFeedback.label.contains("撤回请求已安全保存"))
        app.terminate()
    }

    @MainActor
    func testReceiverRestoresScopedInstallationAndProjectsOfflineMessageThenSendsGroupMessage() throws {
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
        XCTAssertTrue(app.textViews["v2.message.draft"].waitForExistence(timeout: 15))
        let deliveredMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.row.")
        ).firstMatch
        XCTAssertTrue(
            deliveredMessage.waitForExistence(timeout: 15),
            "接收端会话详情必须包含发送端离线期间投递、经同步投影恢复的消息。"
        )
        let withdrawnBody = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.body.")
        ).firstMatch
        XCTAssertTrue(
            withdrawnBody.waitForExistence(timeout: 15) && withdrawnBody.label == "消息已撤回",
            "接收端必须通过自身同步投影看到消息撤回 tombstone，而不能继续显示原文。"
        )
        try auditOrdinaryChatSurface(in: app)
        // This is a populated, receiver-side projection rather than the
        // sender's draft-only detail state. Keep contrast gated here too so
        // restored message content and the composer stay legible together.
        try app.performAccessibilityAudit(for: [.contrast])
        let backToConversationList = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backToConversationList.isHittable)
        backToConversationList.tap()
        let newGroup = app.buttons["v2.conversation.new-group"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: 5))
        newGroup.tap()
        let groupTitle = app.textFields["v2.conversation.group-title"]
        let groupMembers = app.textViews["v2.conversation.group-members"]
        XCTAssertTrue(
            groupTitle.waitForExistence(timeout: 10) && groupTitle.isHittable,
            "恢复后的建群入口必须仍提供可访问的群名称输入。"
        )
        XCTAssertTrue(
            groupMembers.exists && !(groupMembers.value as? String ?? "").isEmpty,
            "本机夹具只能预填已注册发送端的公开 ID；实际建群仍须走已认证目录解析。"
        )
        let createGroup = app.buttons["v2.conversation.group-submit"]
        XCTAssertTrue(createGroup.isEnabled)
        createGroup.tap()
        let openGroupMembers = app.buttons["v2.group.members"]
        XCTAssertTrue(
            openGroupMembers.waitForExistence(timeout: 30),
            "接收端必须使用已注册的独立发送端账号创建真实群聊。"
        )
        openGroupMembers.tap()
        let memberSheet = app.collectionViews["v2.group.members.sheet"]
        XCTAssertTrue(
            memberSheet.waitForExistence(timeout: 15),
            "创建含独立发送端的群后必须能打开按需成员目录。"
        )
        let senderMember = app.staticTexts["Two install sender"]
        XCTAssertTrue(
            senderMember.waitForExistence(timeout: 30),
            "初始成员目录必须投影已解析的发送端公开资料，而不能只创建空群。"
        )
        let memberRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.group.member.")
        )
        XCTAssertGreaterThanOrEqual(
            memberRows.count,
            2,
            "成员目录必须至少包含群主和通过公开 ID 解析加入的独立发送端。"
        )
        let closeGroupMembers = app.buttons["v2.group.members.close"]
        XCTAssertTrue(closeGroupMembers.isHittable)
        closeGroupMembers.tap()
        XCTAssertTrue(openGroupMembers.waitForExistence(timeout: 5))
        let groupDraft = app.textViews["v2.message.draft"]
        XCTAssertTrue(groupDraft.exists)
        let groupDraftValue = groupDraft.value as? String ?? ""
        XCTAssertTrue(
            groupDraftValue.hasPrefix("two-install-group-"),
            "跨安装群消息只能由 Debug 夹具预填，仍须由普通消息发送 UI 提交；实际值：\(groupDraftValue.debugDescription)"
        )
        let send = app.buttons["v2.message.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let sendFeedback = app.staticTexts["v2.message.send-feedback"]
        XCTAssertTrue(
            sendFeedback.waitForExistence(timeout: 30),
            "群消息必须先经真实持久化命令被网关接受或安全保存。"
        )
        XCTAssertTrue(sendFeedback.label.contains("已发送") || sendFeedback.label.contains("已安全保存"))
        let groupMessageRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.row.")
        ).firstMatch
        XCTAssertTrue(
            groupMessageRow.waitForExistence(timeout: 15),
            "发送端群消息必须先被本机同步投影渲染，才能验证前后台恢复不会清空详情状态。"
        )
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(
            app.textViews["v2.message.draft"].waitForExistence(timeout: 30),
            "群消息发送后从后台回到前台必须恢复原有会话详情，而不能丢失本地导航或会话状态。"
        )
        XCTAssertTrue(
            groupMessageRow.waitForExistence(timeout: 15),
            "前台恢复后的详情页必须继续读取同一 SQLite 消息投影。"
        )
        app.terminate()
    }

    @MainActor
    func testSenderRestoresIndependentGroupAndProjectsMessage() throws {
        let app = XCUIApplication()
        app.activate()

        let refresh = app.buttons["v2.conversation.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 30))
        refresh.tap()
        let groupTitle = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "跨装群")
        ).firstMatch
        XCTAssertTrue(
            groupTitle.waitForExistence(timeout: 30) && groupTitle.isHittable,
            "作为初始成员的独立安装必须在自身同步投影中看到接收端创建的群聊。"
        )
        groupTitle.tap()
        XCTAssertTrue(app.textViews["v2.message.draft"].waitForExistence(timeout: 15))
        let groupMessage = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "two-install-group-")
        ).firstMatch
        XCTAssertTrue(
            groupMessage.waitForExistence(timeout: 30),
            "群成员恢复后必须只凭自身 SQLite 同步投影看到群主离线期间投递的群消息。"
        )
        try auditOrdinaryChatSurface(in: app)
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

    @MainActor
    private func auditPrivacySettingsSurface(in app: XCUIApplication) throws {
        // Form navigation chrome belongs to UIKit, and its contrast is not an
        // app-controlled signal. These stable categories still gate our
        // actual settings controls and explanatory text for VoiceOver
        // discoverability. Dynamic Type changing remains a device-settings
        // acceptance check because this simulator audit can stall in Form.
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
            .trait,
        ])
    }
}
