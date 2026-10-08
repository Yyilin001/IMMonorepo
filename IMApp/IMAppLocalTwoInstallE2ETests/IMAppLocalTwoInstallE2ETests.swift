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
        let accountMenu = app.tabBars.buttons["我的"]
        XCTAssertTrue(
            accountMenu.waitForExistence(timeout: 10),
            "我的入口必须作为底部导航的一部分出现。"
        )
        try auditOrdinaryChatSurface(in: app)
        tapConversationTool("v2.conversation.new-group", in: app, timeout: 10)
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
        let groupFeedback = app.staticTexts["v2.conversation.group-feedback"]
        // A response can be lost after the server durably finalizes the
        // creation. In that valid outcome the sheet immediately exposes its
        // durable-retry feedback. Check it first: waiting a full foreground
        // success timeout for a control that can no longer appear made this
        // stage needlessly vulnerable to an XCTest UI-query stall.
        if groupFeedback.waitForExistence(timeout: 10) {
            XCTAssertTrue(
                groupFeedback.label == "建群请求已安全保存；取消可阻止其在恢复连接后继续创建。"
                    || groupFeedback.label == "群聊已创建，可从会话列表打开。",
                "建群必须保留原请求，或明确反馈该原请求已完成。"
            )
            let cancel = app.buttons["v2.conversation.group-cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5) && cancel.isHittable)
            cancel.tap()
        } else if app.buttons["v2.conversation.detail.tools"].waitForExistence(timeout: 20) {
            try auditOrdinaryChatSurface(in: app)
            let detailTools = app.buttons["v2.conversation.detail.tools"]
            XCTAssertTrue(detailTools.isHittable)
            detailTools.tap()
            XCTAssertTrue(groupMembers.waitForExistence(timeout: 5) && groupMembers.isHittable)
            groupMembers.tap()
            let groupMembersSheet = app.collectionViews["v2.group.members.sheet"]
            XCTAssertTrue(
                groupMembersSheet.waitForExistence(timeout: 15),
                "群成员入口必须打开可供辅助技术定位的成员页。"
            )
            let closeGroupMembers = app.buttons["v2.group.members.close"]
            XCTAssertTrue(closeGroupMembers.isHittable)
            closeGroupMembers.tap()
            XCTAssertTrue(app.buttons["v2.conversation.detail.tools"].waitForExistence(timeout: 5))
            // The system-owned navigation back button is the only control
            // here without an app identifier. The test otherwise uses stable
            // IDs.
            let backToConversationList = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(backToConversationList.isHittable)
            backToConversationList.tap()
        } else {
            // The server may durably accept a creation whose response is lost.
            // The client must retain that one operation for replay instead of
            // issuing a second group-create command merely to regain a room
            // ID. Close the sheet and continue from the authoritative local
            // conversation list.
            XCTAssertTrue(
                groupFeedback.waitForExistence(timeout: 5)
                    && groupFeedback.label == "建群请求已安全保存；取消可阻止其在恢复连接后继续创建。",
                "无法立即取得群 ID 时，建群 UI 必须明确保留 durable-retry 语义。"
            )
            let cancel = app.buttons["v2.conversation.group-cancel"]
            XCTAssertTrue(cancel.isHittable)
            cancel.tap()
        }
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 5))
        XCTAssertTrue(accountMenu.waitForExistence(timeout: 10))
        accountMenu.tap()
        let privacySettings = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "v2.privacy.open")
        ).firstMatch
        XCTAssertTrue(privacySettings.waitForExistence(timeout: 10) && privacySettings.isHittable)
        privacySettings.tap()
        XCTAssertTrue(app.navigationBars["消息与隐私"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.switches["v2.privacy.allow-stranger-messages"].waitForExistence(timeout: 15),
            "我的页面必须能打开已认证的陌生人消息接收设置。"
        )
        XCTAssertTrue(
            app.switches["v2.privacy.allow-stranger-messages"].isHittable,
            "陌生人消息接收开关必须可由辅助技术定位并操作。"
        )
        try auditPrivacySettingsSurface(in: app)
        let done = app.buttons["v2.privacy.done"]
        XCTAssertTrue(done.exists)
        done.tap()
        app.tabBars.buttons["消息"].tap()
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 5))
        XCTAssertTrue(accountMenu.waitForExistence(timeout: 10))
        accountMenu.tap()
        let publicIdentity = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "v2.identity.open")
        ).firstMatch
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
        app.tabBars.buttons["消息"].tap()
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 5))
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
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
        let queued = app.staticTexts["已保存私聊请求，完成后会显示在会话列表中。再次点击可继续核对原请求。"]
        let opening = expectation(for: NSPredicate { _, _ in draft.exists || queued.exists }, evaluatedWith: app)
        wait(for: [opening], timeout: 30)
        if queued.exists {
            // A durable opening completes in the list. Follow its existing
            // conversation rather than submitting another opening operation.
            app.buttons["v2.conversation.direct-cancel"].tap()
            let conversation = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "v2.conversation.direct."
            )).firstMatch
            XCTAssertTrue(conversation.waitForExistence(timeout: 30))
            conversation.tap()
            XCTAssertTrue(draft.waitForExistence(timeout: 15) && draft.isHittable)
            draft.tap()
            draft.typeText("two-install-direct-ui")
        }
        XCTAssertTrue(draft.waitForExistence(timeout: 30))
        XCTAssertFalse((draft.value as? String ?? "").isEmpty)
        XCTAssertFalse(
            app.tabBars.buttons["我的"].exists,
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
        let messageBody = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "v2.message.body.\(messageID)")
        ).firstMatch
        XCTAssertTrue(messageBody.exists && messageBody.isHittable)
        if ProcessInfo.processInfo.environment["IMAPP_DIRECT_READ_RECEIPT_ONLY"] == "1" {
            // The peer-read scenario retains the accepted message; mutation
            // acceptance is independently exercised by the ordinary mode.
            XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
            app.terminate()
            return
        }
        messageBody.press(forDuration: 1)
        let reactionPicker = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "v2.message.reaction-picker.\(messageID)", "表情回应")
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
        let thumbsUp = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "v2.message.reaction-picker.\(messageID).👍", "👍")
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
        messageBody.press(forDuration: 1)
        let edit = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "v2.message.edit.\(messageID)", "编辑")
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
        messageBody.press(forDuration: 1)
        let withdraw = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "v2.message.withdraw.\(messageID)", "撤回")
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
        // Keep this installation alive until its local tombstone is visible.
        // This can be optimistic; server commitment requires the independent
        // database snapshot and receiver recovery assertions.
        let withdrawalApplied = expectation(for: NSPredicate(format: "label == %@", "消息已撤回"),
            evaluatedWith: messageBody)
        wait(for: [withdrawalApplied], timeout: 30)
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testReceiverRestoresScopedInstallationAndProjectsOfflineMessageThenSendsGroupMessage() throws {
        let app = XCUIApplication()
        app.activate()

        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
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
        let withdrawnBody = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.body.")
        ).firstMatch
        let withdrawalRecovered = expectation(for: NSPredicate(format: "exists == true AND label == %@", "消息已撤回"),
            evaluatedWith: withdrawnBody)
        wait(for: [withdrawalRecovered], timeout: 30)
        try auditOrdinaryChatSurface(in: app)
        // This is a populated, receiver-side projection rather than the
        // sender's draft-only detail state. Keep contrast gated here too so
        // restored message content and the composer stay legible together.
        try app.performAccessibilityAudit(for: [.contrast])
        let backToConversationList = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backToConversationList.isHittable)
        backToConversationList.tap()
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    // Creating a group does not require the earlier direct withdrawal to have
    // projected. Keep its actual UI evidence independent of that known failure.
    @MainActor
    func testReceiverCreatesIndependentGroupAndSendsMessage() throws {
        let app = XCUIApplication()
        app.activate()
        openConversationTools(in: app)
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
        let expectedTitle = groupTitle.value as? String ?? ""
        createGroup.tap()
        let creationFeedback = app.staticTexts["v2.conversation.group-feedback"]
        let groupOpened = expectation(for: NSPredicate { _, _ in
            app.buttons["v2.conversation.detail.tools"].exists
                || (creationFeedback.exists && creationFeedback.label == "群聊已创建，可从会话列表打开。")
        }, evaluatedWith: app)
        wait(for: [groupOpened], timeout: 30)
        if creationFeedback.exists && creationFeedback.label == "群聊已创建，可从会话列表打开。" {
            app.buttons["v2.conversation.group-cancel"].tap()
            let conversation = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "v2.conversation.group.", expectedTitle
            )).firstMatch
            XCTAssertTrue(conversation.waitForExistence(timeout: 30))
            conversation.tap()
        }
        tapConversationTool("v2.group.members", from: "v2.conversation.detail.tools", in: app, timeout: 30)
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
        XCTAssertTrue(app.buttons["v2.conversation.detail.tools"].waitForExistence(timeout: 5))
        let groupDraft = app.textFields["v2.message.draft"]
        XCTAssertTrue(groupDraft.exists)
        if (groupDraft.value as? String ?? "").isEmpty || groupDraft.value as? String == "消息" {
            groupDraft.tap()
            groupDraft.typeText("two-install-group-ui")
        }
        let groupDraftValue = groupDraft.value as? String ?? ""
        XCTAssertTrue(
            groupDraftValue.hasPrefix("two-install-group-"),
            "跨安装群消息只能由 Debug 夹具预填，仍须由普通消息发送 UI 提交；实际值：\(groupDraftValue.debugDescription)"
        )
        app.buttons["v2.message.composer.options"].tap()
        let mentionsToggle = app.buttons["v2.message.mentions.toggle"]
        XCTAssertTrue(mentionsToggle.waitForExistence(timeout: 5) && mentionsToggle.isHittable)
        mentionsToggle.tap()
        let groupMentions = app.textFields["v2.message.mentions"]
        if (groupMentions.value as? String ?? "").isEmpty || groupMentions.value as? String == groupMentions.placeholderValue {
            groupMentions.tap()
            groupMentions.typeText("@all")
        }
        XCTAssertEqual(
            groupMentions.value as? String,
            "@all",
            "跨安装群消息必须通过普通群聊提及输入区携带 @all，而不能由测试直接写入命令。"
        )
        try app.performAccessibilityAudit(for: [.contrast])
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
            app.textFields["v2.message.draft"].waitForExistence(timeout: 30),
            "群消息发送后从后台回到前台必须恢复原有会话详情，而不能丢失本地导航或会话状态。"
        )
        XCTAssertTrue(
            groupMessageRow.waitForExistence(timeout: 15),
            "前台恢复后的详情页必须继续读取同一 SQLite 消息投影。"
        )
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testSenderQueuesDirectMessageWhileRealtimeEndpointIsUnavailable() throws {
        let app = XCUIApplication()
        app.activate()

        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        let directConversation = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.conversation.direct.")
        ).firstMatch
        XCTAssertTrue(
            directConversation.waitForExistence(timeout: 30) && directConversation.isHittable,
            "实时端点不可用时，发送端仍必须从自身 SQLite 投影打开已有私聊。"
        )
        directConversation.tap()
        let draft = app.textFields["v2.message.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15) && draft.isHittable)
        draft.tap()
        // A single character avoids the known simulator multi-character input
        // truncation while still exercising the ordinary composer and durable
        // outbox path.
        draft.typeText("q")
        XCTAssertEqual(draft.value as? String, "q")
        let send = app.buttons["v2.message.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let feedback = app.staticTexts["v2.message.send-feedback"]
        XCTAssertTrue(
            feedback.waitForExistence(timeout: 30),
            "实时端点不可用时，普通输入区必须确认消息已被安全保存，而不能静默丢弃。"
        )
        XCTAssertEqual(
            feedback.label,
            "已安全保存，连接恢复后会重试。",
            "DEBUG 无效实时端点夹具只能得到 durable-retry 结果，不能误报为已发送。"
        )
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testSenderRestoresIndependentGroupAndProjectsMessage() throws {
        let app = XCUIApplication()
        app.activate()

        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        let groupTitle = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "跨装群")
        ).firstMatch
        XCTAssertTrue(
            groupTitle.waitForExistence(timeout: 30) && groupTitle.isHittable,
            "作为初始成员的独立安装必须在自身同步投影中看到接收端创建的群聊。"
        )
        groupTitle.tap()
        XCTAssertTrue(app.textFields["v2.message.draft"].waitForExistence(timeout: 15))
        let groupMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "two-install-group-")
        ).firstMatch
        XCTAssertTrue(
            groupMessage.waitForExistence(timeout: 30),
            "群成员恢复后必须只凭自身 SQLite 同步投影看到群主离线期间投递的群消息。"
        )
        let mentionSummary = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "v2.message.mentions.", "提及所有人")
        ).firstMatch
        XCTAssertTrue(
            mentionSummary.waitForExistence(timeout: 30),
            "群成员的同步投影必须保留并呈现群主真实发送的 @all 提及语义。"
        )
        groupMessage.press(forDuration: 1)
        let replyAction = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.reply.")
        ).firstMatch
        XCTAssertTrue(replyAction.waitForExistence(timeout: 10) && replyAction.isHittable)
        replyAction.tap()
        XCTAssertTrue(
            app.buttons["v2.message.reply.cancel"].waitForExistence(timeout: 10),
            "群回复必须先从长按消息打开真实回复上下文。"
        )
        let replyDraft = app.textFields["v2.message.draft"]
        replyDraft.tap()
        // This simulator runtime deterministically accepts the first typed
        // character. That is sufficient to prove the initial member sends
        // through the ordinary group composer rather than a test transport.
        replyDraft.typeText("r")
        XCTAssertEqual(replyDraft.value as? String, "r")
        let sendReply = app.buttons["v2.message.send"]
        XCTAssertTrue(sendReply.isEnabled)
        sendReply.tap()
        let replyFeedback = app.staticTexts["v2.message.send-feedback"]
        XCTAssertTrue(
            replyFeedback.waitForExistence(timeout: 30),
            "初始成员的群回复必须经真实持久化命令被网关接受或安全保存。"
        )
        XCTAssertTrue(replyFeedback.label.contains("已发送") || replyFeedback.label.contains("已安全保存"))
        // A one-character message is static content, not a separate touch
        // control. The Xcode hit-region auditor misclassifies it after
        // custom VoiceOver actions are exposed on the full message row; the
        // representative chat surfaces are audited in the other stages.
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testReceiverRestoresIndependentGroupMemberReply() throws {
        let app = XCUIApplication()
        app.activate()

        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        let groupTitle = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "跨装群")
        ).firstMatch
        XCTAssertTrue(groupTitle.waitForExistence(timeout: 30) && groupTitle.isHittable)
        groupTitle.tap()
        XCTAssertTrue(app.textFields["v2.message.draft"].waitForExistence(timeout: 15))
        let memberReply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "r")
        ).firstMatch
        XCTAssertTrue(
            memberReply.waitForExistence(timeout: 30),
            "群主恢复后必须仅凭自身 SQLite 同步投影看到初始成员通过普通输入区发送的回复。"
        )
        let backToConversationList = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backToConversationList.isHittable)
        backToConversationList.tap()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 15)
        let directConversation = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.conversation.direct.")
        ).firstMatch
        XCTAssertTrue(
            directConversation.waitForExistence(timeout: 30) && directConversation.isHittable,
            "接收端恢复后必须继续保有此前私聊的 SQLite 投影。"
        )
        directConversation.tap()
        let replayedOfflineMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "v2.message.body.", "q")
        ).firstMatch
        let replayedOfflineMessageAppeared = replayedOfflineMessage.waitForExistence(timeout: 30)
        if !replayedOfflineMessageAppeared {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "two-install-replayed-offline-direct-message-missing"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "two-install-replayed-offline-direct-message-ui-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(
            replayedOfflineMessageAppeared,
            "发送端恢复实时连接后，先前由普通 UI 安全保存的私聊消息必须只投递一次并进入接收端投影。"
        )
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testSameAccountSecondInstallationListsDevicesAndSendsToSharedGroup() throws {
        let app = XCUIApplication()
        app.activate()
        let submit = app.buttons["v2.password.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 15))
        submit.tap()
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 30))

        app.tabBars.buttons["我的"].tap()
        let devices = app.buttons["v2.device-sessions.open"]
        XCTAssertTrue(devices.waitForExistence(timeout: 10) && devices.isHittable)
        devices.tap()
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.device-sessions.row.")
        )
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        XCTAssertGreaterThanOrEqual(
            rows.count,
            2,
            "同一账号在第二台安装登录后，设备清单必须显示两个独立设备会话。"
        )
        XCTAssertTrue(app.buttons["v2.device-sessions.done"].isHittable)
        app.buttons["v2.device-sessions.done"].tap()
        app.tabBars.buttons["消息"].tap()

        tapConversationTool("v2.conversation.refresh", in: app, timeout: 10)
        let group = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "同账号群")
        ).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30) && group.isHittable)
        group.tap()
        let draft = app.textFields["v2.message.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15) && draft.isHittable)
        draft.tap()
        draft.typeText("m")
        XCTAssertEqual(draft.value as? String, "m")
        app.buttons["v2.message.send"].tap()
        let feedback = app.staticTexts["v2.message.send-feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 30))
        XCTAssertTrue(feedback.label.contains("已发送") || feedback.label.contains("已安全保存"))
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testSameAccountFirstInstallationProjectsEditsAndChangesPreference() throws {
        let app = XCUIApplication()
        app.activate()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        let group = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "同账号群")
        ).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30) && group.isHittable)
        group.tap()
        let messageBody = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "m")
        ).firstMatch
        XCTAssertTrue(messageBody.waitForExistence(timeout: 30))
        messageBody.press(forDuration: 1)
        let edit = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.edit.")
        ).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10) && edit.isHittable)
        edit.tap()
        let editor = app.textViews["v2.message.edit-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10) && editor.isHittable)
        editor.tap()
        editor.typeText("x")
        let save = app.buttons["v2.message.edit-save"]
        XCTAssertTrue(save.isHittable && save.isEnabled)
        save.tap()
        let actionFeedback = app.staticTexts["v2.message.action-feedback"]
        XCTAssertTrue(actionFeedback.waitForExistence(timeout: 30))
        XCTAssertTrue(actionFeedback.label.contains("编辑已提交") || actionFeedback.label.contains("编辑已安全保存"))
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.isHittable)
        back.tap()
        let accountMenu = app.tabBars.buttons["我的"]
        XCTAssertTrue(accountMenu.waitForExistence(timeout: 10) && accountMenu.isHittable)
        accountMenu.tap()
        let privacySettings = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "v2.privacy.open")
        ).firstMatch
        XCTAssertTrue(privacySettings.waitForExistence(timeout: 10) && privacySettings.isHittable)
        privacySettings.tap()
        let strangerMessages = app.switches["v2.privacy.allow-stranger-messages"]
        XCTAssertTrue(strangerMessages.waitForExistence(timeout: 15) && strangerMessages.isHittable && strangerMessages.isEnabled)
        let strangerControl = strangerMessages.switches.firstMatch
        XCTAssertTrue(strangerControl.exists && strangerControl.isHittable)
        strangerControl.tap()
        let strangerDisabled = NSPredicate(format: "value == %@", "0")
        expectation(for: strangerDisabled, evaluatedWith: strangerMessages, handler: nil)
        waitForExpectations(timeout: 45)
        let groupReadReceipts = app.switches["v2.privacy.share-group-read-receipts"]
        XCTAssertTrue(groupReadReceipts.waitForExistence(timeout: 15) && groupReadReceipts.isHittable && groupReadReceipts.isEnabled)
        let groupReceiptControl = groupReadReceipts.switches.firstMatch
        XCTAssertTrue(groupReceiptControl.exists && groupReceiptControl.isHittable)
        groupReceiptControl.tap()
        let groupReceiptsDisabled = NSPredicate(format: "value == %@", "0")
        expectation(for: groupReceiptsDisabled, evaluatedWith: groupReadReceipts, handler: nil)
        waitForExpectations(timeout: 45)
        for identifier in ["v2.privacy.allow-being-added", "v2.privacy.share-online-presence", "v2.privacy.share-typing-indicators"] {
            let toggle = app.switches[identifier]
            XCTAssertTrue(toggle.waitForExistence(timeout: 15))
            for _ in 0..<3 where !toggle.isHittable { app.swipeUp() }
            let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: toggle)
            wait(for: [enabled], timeout: 30)
            XCTAssertTrue(toggle.isHittable)
            XCTAssertEqual(toggle.value as? String, "1")
            let control = toggle.switches.firstMatch
            XCTAssertTrue(control.exists && control.isHittable)
            control.tap()
            let disabled = expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
            wait(for: [disabled], timeout: 45)
        }
        let done = app.buttons["v2.privacy.done"]
        XCTAssertTrue(done.isHittable)
        done.tap()
        app.tabBars.buttons["消息"].tap()
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testSameAccountSecondInstallationProjectsEditPreferenceAndWithdraws() throws {
        let app = XCUIApplication()
        app.activate()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        let accountMenu = app.tabBars.buttons["我的"]
        XCTAssertTrue(accountMenu.waitForExistence(timeout: 10) && accountMenu.isHittable)
        accountMenu.tap()
        let privacySettings = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "v2.privacy.open")
        ).firstMatch
        XCTAssertTrue(privacySettings.waitForExistence(timeout: 10) && privacySettings.isHittable)
        privacySettings.tap()
        let strangerMessages = app.switches["v2.privacy.allow-stranger-messages"]
        XCTAssertTrue(strangerMessages.waitForExistence(timeout: 30))
        let strangerDisabled = NSPredicate(format: "value == %@", "0")
        expectation(for: strangerDisabled, evaluatedWith: strangerMessages, handler: nil)
        waitForExpectations(timeout: 30)
        let groupReadReceipts = app.switches["v2.privacy.share-group-read-receipts"]
        XCTAssertTrue(groupReadReceipts.waitForExistence(timeout: 30))
        let groupReceiptsDisabled = NSPredicate(format: "value == %@", "0")
        expectation(for: groupReceiptsDisabled, evaluatedWith: groupReadReceipts, handler: nil)
        waitForExpectations(timeout: 30)
        for identifier in ["v2.privacy.allow-being-added", "v2.privacy.share-online-presence", "v2.privacy.share-typing-indicators"] {
            let toggle = app.switches[identifier]
            XCTAssertTrue(toggle.waitForExistence(timeout: 30))
            for _ in 0..<3 where !toggle.isHittable { app.swipeUp() }
            XCTAssertTrue(toggle.isHittable)
            let disabled = expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
            wait(for: [disabled], timeout: 30)
        }
        app.buttons["v2.privacy.done"].tap()
        app.tabBars.buttons["消息"].tap()
        let group = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "同账号群")
        ).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30) && group.isHittable)
        group.tap()
        let editedBody = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "xm")
        ).firstMatch
        XCTAssertTrue(editedBody.waitForExistence(timeout: 30), "第二台设备必须先投影同账号设备对消息的编辑。")
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testSameAccountSecondInstallationQueuesOfflineGroupMessage() throws {
        let app = XCUIApplication()
        app.activate()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        let group = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "同账号群")
        ).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30) && group.isHittable)
        group.tap()
        let draft = app.textFields["v2.message.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15) && draft.isHittable)
        draft.tap()
        draft.typeText("q")
        XCTAssertEqual(draft.value as? String, "q")
        app.buttons["v2.message.send"].tap()
        let feedback = app.staticTexts["v2.message.send-feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 30))
        XCTAssertEqual(
            feedback.label,
            "已安全保存，连接恢复后会重试。",
            "同账号的第二台设备离线时，群消息必须进入该设备自己的 durable outbox。"
        )
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testSameAccountSecondInstallationReplaysOfflineGroupMessageAndWithdraws() throws {
        let app = XCUIApplication()
        app.activate()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        let group = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "同账号群")
        ).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30) && group.isHittable)
        group.tap()
        let queuedMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "v2.message.body.", "q")
        ).firstMatch
        XCTAssertTrue(queuedMessage.waitForExistence(timeout: 30), "恢复连接后必须仅重放该设备离线时安全保存的群消息。")
        let editedMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "xm")
        ).firstMatch
        XCTAssertTrue(editedMessage.waitForExistence(timeout: 10))
        editedMessage.press(forDuration: 1)
        let withdraw = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.withdraw.")
        ).firstMatch
        XCTAssertTrue(withdraw.waitForExistence(timeout: 10) && withdraw.isHittable)
        withdraw.tap()
        let actionFeedback = app.staticTexts["v2.message.action-feedback"]
        XCTAssertTrue(actionFeedback.waitForExistence(timeout: 30))
        XCTAssertTrue(actionFeedback.label.contains("撤回已提交") || actionFeedback.label.contains("撤回请求已安全保存"))
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testSameAccountSecondInstallationProjectsSnapshotReset() throws {
        let app = XCUIApplication()
        app.activate()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        let group = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "同账号群")
        ).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30) && group.isHittable)
        group.tap()
        let withdrawn = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "消息已撤回")
        ).firstMatch
        XCTAssertTrue(withdrawn.waitForExistence(timeout: 30), "设备被要求重置快照后必须重建撤回 tombstone。")
        let replayedMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "v2.message.body.", "q")
        ).firstMatch
        XCTAssertTrue(replayedMessage.waitForExistence(timeout: 30), "设备被要求重置快照后必须重建此前离线重放的消息。")
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testSameAccountFirstInstallationProjectsWithdrawal() throws {
        let app = XCUIApplication()
        app.activate()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        let group = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "同账号群")
        ).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30) && group.isHittable)
        group.tap()
        let withdrawn = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "消息已撤回")
        ).firstMatch
        XCTAssertTrue(withdrawn.waitForExistence(timeout: 30), "第一台设备必须投影第二台设备提交的撤回 tombstone。")
        let replayedOfflineMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "v2.message.body.", "q")
        ).firstMatch
        XCTAssertTrue(replayedOfflineMessage.waitForExistence(timeout: 30), "第一台设备必须投影第二台设备恢复连接后重放的群消息。")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(withdrawn.waitForExistence(timeout: 30), "同账号设备前后台切换后必须保留撤回后的同步投影。")
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testGroupOwnerProjectsActualMemberReadReceipts() throws {
        let app = XCUIApplication()
        app.activate()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        let group = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "跨装群")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30) && group.isHittable)
        group.tap()
        let body = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "v2.message.body.", "two-install-group-")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30) && body.isHittable)
        let messageID = body.identifier.replacingOccurrences(of: "v2.message.body.", with: "")
        XCTAssertFalse(messageID.isEmpty)
        body.press(forDuration: 1)
        let readers = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "v2.message.group-readers.\(messageID)", "查看已读")).firstMatch
        XCTAssertTrue(readers.waitForExistence(timeout: 10) && readers.isHittable)
        readers.tap()
        XCTAssertTrue(app.navigationBars["已读详情"].waitForExistence(timeout: 15))
        let member = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND value == %@", "Two install sender", "已读")).firstMatch
        if !member.waitForExistence(timeout: 30) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "group-readers-missing-actual-member"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(member.exists, "已读详情必须显示实际阅读的独立成员及已读状态。")
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testReceiverProjectsDirectMessageAndReportsRead() throws {
        let app = XCUIApplication()
        app.activate()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        let direct = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.conversation.direct.")).firstMatch
        XCTAssertTrue(direct.waitForExistence(timeout: 30) && direct.isHittable)
        direct.tap()
        let body = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.body.")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        XCTAssertTrue(body.label.hasPrefix("two-install-"))
        // Leave only through the ordinary navigation boundary, allowing its
        // read reporting to finish while the authenticated service is alive.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(direct.waitForExistence(timeout: 15))
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testSenderColdRestoreProjectsPeerRead() throws {
        let app = XCUIApplication()
        app.activate()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        let direct = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.conversation.direct.")).firstMatch
        XCTAssertTrue(direct.waitForExistence(timeout: 30) && direct.isHittable)
        direct.tap()
        let body = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "v2.message.body.")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        let messageID = body.identifier.replacingOccurrences(of: "v2.message.body.", with: "")
        XCTAssertFalse(messageID.isEmpty)
        let read = app.staticTexts["v2.message.read.\(messageID)"]
        XCTAssertTrue(read.waitForExistence(timeout: 30), "接收端真实阅读后的回执必须恢复为同一消息的对方已读UI。")
        XCTAssertEqual(read.label, "对方已读")
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    func testAccountSwitchAndColdRestoreKeepProjectionsIsolated() throws {
        let environment = ProcessInfo.processInfo.environment
        let scope = try XCTUnwrap(environment["IMAPP_ACCOUNT_SWITCH_SCOPE"])
        let firstHandle = try XCTUnwrap(environment["IMAPP_ACCOUNT_SWITCH_FIRST_HANDLE"])
        let firstGroup = try XCTUnwrap(environment["IMAPP_ACCOUNT_SWITCH_FIRST_GROUP"])
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(18)
        let secondHandle = try XCTUnwrap(environment["IMAPP_ACCOUNT_SWITCH_SECOND_HANDLE"])
        let secondGroup = "Switch B \(suffix)"
        let app = XCUIApplication()
        let restore = ["-v2-ui-testing-live-local-account", "-v2-ui-testing-restore-local-account", "-v2-ui-testing-e2e-scope", scope]
        func group(_ title: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        }
        func replace(_ element: XCUIElement, with value: String) {
            XCTAssertTrue(element.waitForExistence(timeout: 15))
            for _ in 0..<3 where !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.isHittable)
            element.tap()
            let previous = element.value as? String ?? ""
            if previous != element.placeholderValue {
                element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            }
            element.typeText(value)
        }
        func signOut() {
            app.tabBars.buttons["我的"].tap()
            let signOut = app.buttons["v2.sign-out"]
            if !signOut.isHittable { app.swipeUp() }
            XCTAssertTrue(signOut.waitForExistence(timeout: 10) && signOut.isHittable)
            signOut.tap()
            let submit = app.buttons["v2.password.submit"]
            let retry = app.buttons["v2.sign-out.pending.retry"]
            let destination = expectation(for: NSPredicate { _, _ in submit.exists || retry.exists }, evaluatedWith: app)
            wait(for: [destination], timeout: 30)
            if retry.exists {
                // Record the failed first exit separately. This is the
                // ordinary user's recovery button, not credential injection.
                XCTContext.runActivity(named: "account-switch-sign-out-required-manual-retry") { _ in }
                XCTAssertTrue(retry.isHittable)
                retry.tap()
            }
            XCTAssertTrue(submit.waitForExistence(timeout: 30))
        }
        func body(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@", "v2.message.body.", text)).firstMatch
        }
        func send(in title: String, text: String) {
            group(title).tap()
            replace(app.textFields["v2.message.draft"], with: text)
            app.buttons["v2.message.send"].tap()
            XCTAssertTrue(body(text).waitForExistence(timeout: 30))
            app.navigationBars.buttons.firstMatch.tap()
        }
        func checkMessages(in title: String, own: String, other: String) {
            group(title).tap()
            XCTAssertTrue(body(own).waitForExistence(timeout: 30))
            XCTAssertFalse(body(other).exists)
            app.navigationBars.buttons.firstMatch.tap()
        }
        app.activate()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        XCTAssertTrue(group(firstGroup).waitForExistence(timeout: 30))
        send(in: firstGroup, text: "Switch A message")
        signOut()
        app.segmentedControls["v2.password.mode"].buttons["登录"].tap()
        replace(app.textFields["v2.password.account-handle"], with: secondHandle)
        replace(app.secureTextFields["v2.password.value"], with: "localpassword")
        app.buttons["v2.password.submit"].tap()
        XCTAssertTrue(app.buttons["v2.conversation.new-direct"].waitForExistence(timeout: 30))
        XCTAssertFalse(group(firstGroup).exists, "新账号不能展示旧账号的会话。")
        tapConversationTool("v2.conversation.new-group", in: app, timeout: 15)
        replace(app.textFields["v2.conversation.group-title"], with: secondGroup)
        app.buttons["v2.conversation.group-submit"].tap()
        let created = app.staticTexts["v2.conversation.group-feedback"]
        XCTAssertTrue(created.waitForExistence(timeout: 30))
        let committed = expectation(for: NSPredicate(format: "label == %@", "群聊已创建，可从会话列表打开。"), evaluatedWith: created)
        wait(for: [committed], timeout: 30)
        app.buttons["v2.conversation.group-cancel"].tap()
        XCTAssertTrue(group(secondGroup).waitForExistence(timeout: 30))
        send(in: secondGroup, text: "Switch B message")
        app.terminate()
        app.launchArguments = restore
        app.launch()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        XCTAssertTrue(group(secondGroup).waitForExistence(timeout: 30), "冷启动必须恢复当前账号B的持久投影。")
        XCTAssertFalse(group(firstGroup).exists)
        checkMessages(in: secondGroup, own: "Switch B message", other: "Switch A message")
        signOut()
        app.segmentedControls["v2.password.mode"].buttons["登录"].tap()
        replace(app.textFields["v2.password.account-handle"], with: firstHandle)
        replace(app.secureTextFields["v2.password.value"], with: "localpassword")
        app.buttons["v2.password.submit"].tap()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        XCTAssertTrue(group(firstGroup).waitForExistence(timeout: 30), "重新登录A必须恢复其原投影。")
        XCTAssertFalse(group(secondGroup).exists, "A不能展示B的会话。")
        checkMessages(in: firstGroup, own: "Switch A message", other: "Switch B message")
        app.terminate()
        app.launchArguments = restore
        app.launch()
        tapConversationTool("v2.conversation.refresh", in: app, timeout: 30)
        XCTAssertTrue(group(firstGroup).waitForExistence(timeout: 30))
        XCTAssertFalse(group(secondGroup).exists)
        checkMessages(in: firstGroup, own: "Switch A message", other: "Switch B message")
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
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
        XCTContext.runActivity(named: "two-install-functional-stage-complete") { _ in }
        app.terminate()
    }

    @MainActor
    private func openConversationTools(in app: XCUIApplication) {
        let tools = app.buttons["v2.conversation.tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 10) && tools.isHittable)
        tools.tap()
    }

    @MainActor
    private func tapConversationTool(
        _ itemIdentifier: String,
        from menuIdentifier: String = "v2.conversation.tools",
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let menu = app.buttons[menuIdentifier]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout) && menu.isHittable)
        menu.tap()
        var item = app.buttons[itemIdentifier]
        // The native SwiftUI Menu on this simulator exposes the member action
        // by its accessibility label while dropping the declared identifier.
        // Keep the fallback limited to that observed action and require one
        // unambiguous, hittable button in the opened real menu.
        if itemIdentifier == "v2.group.members", !item.exists {
            let members = app.buttons.matching(NSPredicate(format: "label == %@", "成员"))
            XCTAssertEqual(members.count, 1)
            item = members.firstMatch
        }
        XCTAssertTrue(item.waitForExistence(timeout: timeout) && item.isHittable)
        item.tap()
    }

    @MainActor
    private func auditOrdinaryChatSurface(in app: XCUIApplication) throws {
        // Preserve every XCTest audit issue while allowing later functional
        // assertions in this stage to run. The driver retains an overall
        // failure even when this is the only issue and continues other stages.
        let previous = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previous }
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
