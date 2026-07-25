import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2ConversationStoreTests {
    @Test func listRefreshUsesOnlyTheConversationDataSource() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source = V2ConversationDataSourceFake(
            summaries: [
                .init(id: "room-a", title: "会话 room-a", preview: "你好", lastActivity: date, isOutgoing: false)
            ],
            messages: []
        )
        let store = V2ConversationListStore(dataSource: source, userID: "current-user")

        await store.refresh()

        #expect(store.state == .loaded)
        #expect(store.items.map(\.id) == ["room-a"])
        #expect(store.items.first?.preview == "你好")
    }

    @Test func messageRefreshPreservesOnlyOpaqueAttachmentReferences() async throws {
        let reference = V2MediaReference(mediaID: try .init("00000000-0000-0000-0000-000000000501"))
        let message = V2ConversationMessageItem(
            id: "message-with-attachment",
            revision: 1,
            text: "附件说明",
            media: [reference],
            createdAt: .now,
            isOutgoing: false,
            isWithdrawn: false
        )
        let source = V2ConversationDataSourceFake(summaries: [], messages: [message])
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-a"
        )

        await store.refresh()

        #expect(store.messages == [message])
        #expect(store.messages.first?.media == [reference])
    }

    @Test func mediaDownloadRevalidatesThroughInjectedBoundaryBeforeExposingLocalShareFile() async throws {
        let reference = V2MediaReference(mediaID: try .init("00000000-0000-0000-0000-000000000511"))
        let message = V2ConversationMessageItem(
            id: "message-with-download",
            revision: 1,
            text: "附件说明",
            media: [reference],
            createdAt: .now,
            isOutgoing: false,
            isWithdrawn: false
        )
        let source = V2ConversationDataSourceFake(summaries: [], messages: [message])
        let downloaded = V2DownloadedConversationMedia(
            mediaID: reference.mediaID,
            fileURL: URL(fileURLWithPath: "/tmp/opaque-local-media")
        )
        let downloader = V2ConversationMediaDownloaderFake(result: .success(downloaded))
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-a",
            mediaDownloader: downloader
        )
        await store.refresh()

        await store.downloadMedia(reference, from: message)

        #expect(await downloader.requests() == [reference])
        #expect(store.mediaDownloadState(for: reference) == .downloaded(downloaded))
        #expect(store.messageActionFeedback == nil)
    }

    @Test func mediaDownloadFailureDoesNotExposeAFileToTheMessageView() async throws {
        let reference = V2MediaReference(mediaID: try .init("00000000-0000-0000-0000-000000000512"))
        let message = V2ConversationMessageItem(
            id: "message-download-failure",
            revision: 1,
            text: "附件说明",
            media: [reference],
            createdAt: .now,
            isOutgoing: false,
            isWithdrawn: false
        )
        let source = V2ConversationDataSourceFake(summaries: [], messages: [message])
        let downloader = V2ConversationMediaDownloaderFake(result: .failure)
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-a",
            mediaDownloader: downloader
        )
        await store.refresh()

        await store.downloadMedia(reference, from: message)

        #expect(store.mediaDownloadState(for: reference) == .failed)
        #expect(store.messageActionFeedback == "附件下载失败，请稍后重试。")
    }

    @Test func messageSendClearsDraftAndReportsDurableRetry() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2ConversationSenderFake(result: .queuedForRetry)
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-a"
        )
        store.draft = "  离线消息  "

        await store.sendDraft()

        #expect(store.draft.isEmpty)
        #expect(store.sendFeedback == "已安全保存，连接恢复后会重试。")
        #expect(await sender.sentMessages() == [.init(text: "离线消息", roomID: "room-a")])
    }

    @Test func attachmentOnlyMessageWaitsForUploaderThenEnqueuesOpaqueReference() async throws {
        let staged = V2StagedConversationAttachment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
            fileURL: URL(fileURLWithPath: "/tmp/v2-attachment"),
            displayName: "diagram.png",
            contentType: "image/png",
            byteCount: 42
        )
        let reference = V2MediaReference(mediaID: try .init("00000000-0000-0000-0000-000000000602"))
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2ConversationSenderFake(result: .queuedForRetry)
        let stager = V2ConversationAttachmentStagerFake(result: .success(staged))
        let uploader = V2ConversationAttachmentUploaderFake(result: .success(reference))
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-a",
            attachmentStager: stager,
            attachmentUploader: uploader
        )

        await store.stageAttachment(from: URL(fileURLWithPath: "/tmp/imported-diagram.png"))
        await store.sendDraft()

        #expect(await uploader.uploadedAttachments() == [staged])
        #expect(await sender.sentMessages() == [.init(text: "", media: [reference], roomID: "room-a")])
        #expect(await stager.discardedAttachments() == [staged])
        #expect(store.attachments.isEmpty)
        #expect(store.sendFeedback == "已安全保存，连接恢复后会重试。")
    }

    @Test func failedAttachmentUploadRetainsTheDraftAndNeverEnqueuesMessage() async {
        let staged = V2StagedConversationAttachment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000611")!,
            fileURL: URL(fileURLWithPath: "/tmp/v2-attachment"),
            displayName: "document.pdf",
            contentType: "application/pdf",
            byteCount: 42
        )
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2ConversationSenderFake(result: .accepted)
        let stager = V2ConversationAttachmentStagerFake(result: .success(staged))
        let uploader = V2ConversationAttachmentUploaderFake(result: .failure(V2AttachmentUploadFailure.failed))
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-a",
            attachmentStager: stager,
            attachmentUploader: uploader
        )
        store.draft = "附件说明"

        await store.stageAttachment(from: URL(fileURLWithPath: "/tmp/imported-document.pdf"))
        await store.sendDraft()

        #expect(await sender.sentMessages().isEmpty)
        #expect(store.draft == "附件说明")
        #expect(store.attachments.count == 1)
        #expect(store.attachments.first?.state == .failed)
        #expect(store.sendFeedback == "附件上传或安全扫描未完成，请稍后重试。")
        #expect(await stager.discardedAttachments().isEmpty)
    }

    @Test func attachmentStagerCopiesImporterFileIntoItsOwnDirectoryAndDiscardsOnlyTheCopy() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("v2-attachment-stager-" + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let source = root.appendingPathComponent("imported-note.txt", isDirectory: false)
        let stagingDirectory = root.appendingPathComponent("staging", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("private attachment bytes".utf8).write(to: source)
        let stager = try V2FileConversationAttachmentStager(
            directory: stagingDirectory,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000701")! }
        )

        let staged = try await stager.stageImportedFile(at: source)

        #expect(staged.fileURL.deletingLastPathComponent() == stagingDirectory.standardizedFileURL)
        #expect(staged.fileURL != source)
        #expect(fileManager.contentsEqual(atPath: source.path, andPath: staged.fileURL.path))
        #expect(staged.displayName == "imported-note.txt")
        #expect(staged.byteCount == Int64("private attachment bytes".utf8.count))

        await stager.discard(staged)

        #expect(!fileManager.fileExists(atPath: staged.fileURL.path))
        #expect(fileManager.fileExists(atPath: source.path))
    }

    @Test func attachmentStagerPurgesOnlyDirectOrphanedCopiesOnNextActivation() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("v2-attachment-orphans-" + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let stagingDirectory = root.appendingPathComponent("staging", isDirectory: true)
        let outsideFile = root.appendingPathComponent("keep.txt", isDirectory: false)
        let orphan = stagingDirectory.appendingPathComponent("orphan", isDirectory: false)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outsideFile)
        try Data("orphan".utf8).write(to: orphan)
        let stager = try V2FileConversationAttachmentStager(directory: stagingDirectory)

        await stager.discardOrphanedStagedFiles()

        #expect(!fileManager.fileExists(atPath: orphan.path))
        #expect(fileManager.fileExists(atPath: outsideFile.path))
    }

    @Test func foregroundMediaDownloaderUsesFreshAuthorizedTransferAndOpaqueCacheFilename() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("v2-media-cache-" + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        // Media IDs are deliberately URL-path-safe. The cache name must still
        // be opaque rather than exposing even a valid identifier.
        let reference = V2MediaReference(mediaID: try .init("media-identifier-must-not-be-a-path"))
        let target = try V2ClientMediaTransferTarget(
            url: #require(URL(string: "https://media.invalid/object")),
            expiresAt: .distantFuture,
            expectedByteCount: 4
        )
        let resolver = V2MediaDownloadTargetResolverFake(target: target)
        let transfer = V2MediaByteTransferFake(downloadedData: Data([1, 2, 3, 4]))
        let client = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: transfer)
        let downloader = try V2ForegroundConversationMediaDownloader(
            downloader: client,
            directory: root,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000711")! }
        )

        let downloaded = try await downloader.download(reference)

        #expect(await resolver.requests() == [reference.mediaID])
        #expect(await transfer.downloadDestinations() == [downloaded.fileURL.deletingLastPathComponent().appendingPathComponent(".00000000-0000-0000-0000-000000000711.partial")])
        #expect(try Data(contentsOf: downloaded.fileURL) == Data([1, 2, 3, 4]))
        #expect(!downloaded.fileURL.lastPathComponent.contains(reference.mediaID.rawValue))
        #expect(downloaded.fileURL.pathExtension == "media")
    }

    @Test func foregroundMediaDownloaderPurgesOnlyIncompleteCacheTransfers() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("v2-media-cache-cleanup-" + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let target = try V2ClientMediaTransferTarget(
            url: #require(URL(string: "https://media.invalid/object")),
            expiresAt: .distantFuture
        )
        let downloader = try V2ForegroundConversationMediaDownloader(
            downloader: .init(
                targetResolver: V2MediaDownloadTargetResolverFake(target: target),
                byteTransfer: V2MediaByteTransferFake(downloadedData: Data())
            ),
            directory: root
        )
        let orphan = root.appendingPathComponent(".interrupted.partial", isDirectory: false)
        let retained = root.appendingPathComponent("existing.media", isDirectory: false)
        try Data("partial".utf8).write(to: orphan)
        try Data("retained".utf8).write(to: retained)

        await downloader.discardOrphanedTemporaryFiles()

        #expect(!fileManager.fileExists(atPath: orphan.path))
        #expect(fileManager.fileExists(atPath: retained.path))
    }

    @Test func messageWithdrawalUsesProjectionRevisionAndRefreshesAfterAcknowledgement() async {
        let message = V2ConversationMessageItem(
            id: "message-a",
            revision: 4,
            text: "需要撤回",
            createdAt: .now,
            isOutgoing: true,
            isWithdrawn: false
        )
        let source = V2ConversationDataSourceFake(summaries: [], messages: [message])
        let withdrawer = V2MessageWithdrawerFake(result: .accepted)
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            messageWithdrawer: withdrawer,
            userID: "current-user",
            roomID: "room-a"
        )

        await store.withdrawMessage(message)

        #expect(await withdrawer.requests() == [.init(messageID: "message-a", roomID: "room-a", expectedMessageRevision: 4)])
        #expect(await source.messageRequestCount() == 1)
        #expect(store.messageActionFeedback == "撤回已提交，正在同步。")
    }

    @Test func messageWithdrawalIsNotAvailableForIncomingOrWithdrawnMessages() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let withdrawer = V2MessageWithdrawerFake(result: .accepted)
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            messageWithdrawer: withdrawer,
            userID: "current-user",
            roomID: "room-a"
        )
        let incoming = V2ConversationMessageItem(id: "message-in", revision: 1, text: "收到", createdAt: .now, isOutgoing: false, isWithdrawn: false)
        let withdrawn = V2ConversationMessageItem(id: "message-old", revision: 2, text: "消息已撤回", createdAt: .now, isOutgoing: true, isWithdrawn: true)

        await store.withdrawMessage(incoming)
        await store.withdrawMessage(withdrawn)

        #expect(!store.canWithdrawMessage(incoming))
        #expect(!store.canWithdrawMessage(withdrawn))
        #expect(await withdrawer.requests().isEmpty)
    }

    @Test func messageReactionTogglesOnlyTheCurrentUsersSetMembership() async {
        let message = V2ConversationMessageItem(
            id: "message-a",
            revision: 1,
            text: "可反应",
            createdAt: .now,
            isOutgoing: false,
            isWithdrawn: false,
            reactions: [
                .init(reaction: "👍", count: 2, includesCurrentUser: true),
                .init(reaction: "🎉", count: 1, includesCurrentUser: false)
            ]
        )
        let source = V2ConversationDataSourceFake(summaries: [], messages: [message])
        let changer = V2MessageReactionChangerFake(result: .accepted)
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            messageReactionChanger: changer,
            userID: "current-user",
            roomID: "room-a"
        )

        await store.changeReaction("👍", on: message)
        await store.changeReaction("❤️", on: message)

        #expect(await changer.requests() == [
            .init(messageID: "message-a", roomID: "room-a", reaction: "👍", action: .remove),
            .init(messageID: "message-a", roomID: "room-a", reaction: "❤️", action: .add)
        ])
        #expect(await source.messageRequestCount() == 2)
        #expect(store.messageActionFeedback == "反应已提交，正在同步。")
    }

    @Test func messageReactionIsNotAvailableAfterWithdrawal() async {
        let message = V2ConversationMessageItem(id: "message-a", revision: 2, text: "消息已撤回", createdAt: .now, isOutgoing: true, isWithdrawn: true)
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let changer = V2MessageReactionChangerFake(result: .accepted)
        let store = V2ConversationDetailStore(dataSource: source, sender: nil, messageReactionChanger: changer, userID: "current-user", roomID: "room-a")

        await store.changeReaction("👍", on: message)

        #expect(!store.canReactToMessage(message))
        #expect(await changer.requests().isEmpty)
    }

    @Test func messageEditUsesProjectionRevisionAndRefreshesAfterAcknowledgement() async {
        let message = V2ConversationMessageItem(id: "message-a", revision: 5, text: "原文", createdAt: .now, isOutgoing: true, isWithdrawn: false)
        let source = V2ConversationDataSourceFake(summaries: [], messages: [message])
        let editor = V2MessageEditorFake(result: .accepted)
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            messageEditor: editor,
            userID: "current-user",
            roomID: "room-a"
        )

        let shouldDismissEditor = await store.editMessage(message, text: "  新文本  ")

        #expect(shouldDismissEditor)
        #expect(await editor.requests() == [.init(messageID: "message-a", roomID: "room-a", expectedMessageRevision: 5, text: "新文本")])
        #expect(await source.messageRequestCount() == 1)
        #expect(store.messageActionFeedback == "编辑已提交，正在同步。")
    }

    @Test func messageEditKeepsEditorOpenAfterTerminalRejection() async {
        let message = V2ConversationMessageItem(id: "message-a", revision: 5, text: "原文", createdAt: .now, isOutgoing: true, isWithdrawn: false)
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let editor = V2MessageEditorFake(result: .rejected(code: "REVISION_CONFLICT"))
        let store = V2ConversationDetailStore(dataSource: source, sender: nil, messageEditor: editor, userID: "current-user", roomID: "room-a")

        let shouldDismissEditor = await store.editMessage(message, text: "新文本")

        #expect(!shouldDismissEditor)
        #expect(await editor.requests().count == 1)
        #expect(store.messageActionFeedback == "编辑被拒绝（REVISION_CONFLICT），请刷新后重试。")
    }

    @Test func messageRefreshReportsTheNewestVisibleRoomSequence() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [
            .init(id: "message-a", roomSequence: 4, revision: 1, text: "较早", createdAt: .now, isOutgoing: false, isWithdrawn: false),
            .init(id: "message-b", roomSequence: 9, revision: 1, text: "最新", createdAt: .now, isOutgoing: true, isWithdrawn: false)
        ])
        let reporter = V2ConversationReadReporterFake(result: .queuedForRetry)
        let store = V2ConversationDetailStore(dataSource: source, sender: nil, readReceiptReporter: reporter, userID: "current-user", roomID: "room-a")

        await store.refresh()

        #expect(store.state == .loaded)
        #expect(await reporter.requests() == [.init(roomID: "room-a", roomSequence: 9)])
    }

    @Test func directConversationTrimsInputAndReturnsOpenedRoom() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let opener = V2DirectConversationOpenerFake(roomID: "room-direct")
        let resolver = V2ConversationPublicIdentityResolverFake(values: ["other_user": "other-user"])
        let store = V2ConversationListStore(
            dataSource: source,
            userID: "current-user",
            directConversationOpener: opener,
            publicIdentityResolver: resolver
        )

        let roomID = await store.openDirectConversation(handle: "  @other_user  ")

        #expect(roomID == "room-direct")
        #expect(await opener.targets() == ["other-user"])
        #expect(store.directConversationFeedback == nil)
    }

    @Test func directConversationRejectsBlankTargetBeforeNetwork() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let opener = V2DirectConversationOpenerFake(roomID: "room-direct")
        let store = V2ConversationListStore(
            dataSource: source,
            userID: "current-user",
            directConversationOpener: opener
        )

        let roomID = await store.openDirectConversation(handle: " \n ")

        #expect(roomID == nil)
        #expect(store.directConversationFeedback == "请输入对方的公开 ID。")
        #expect(await opener.targets().isEmpty)
    }

    @Test func groupConversationSplitsCanonicalMemberInputAndReturnsRoom() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let creator = V2GroupConversationCreatorFake(result: .created(roomID: "room-group"))
        let resolver = V2ConversationPublicIdentityResolverFake(values: ["user_a": "user-a", "user_b": "user-b"])
        let store = V2ConversationListStore(dataSource: source, userID: "current-user", publicIdentityResolver: resolver, groupConversationCreator: creator)

        let roomID = await store.createGroupConversation(title: " 项目群 ", memberHandlesText: " @user_a,\n@user_b ")

        #expect(roomID == "room-group")
        #expect(await creator.requests() == [.init(title: " 项目群 ", memberUserIDs: ["user-a", "user-b"])])
    }

    @Test func groupConversationKeepsDurableRetryVisible() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let creator = V2GroupConversationCreatorFake(result: .queuedForRetry)
        let store = V2ConversationListStore(dataSource: source, userID: "current-user", groupConversationCreator: creator)

        let roomID = await store.createGroupConversation(title: "项目群", memberHandlesText: "")

        #expect(roomID == nil)
        #expect(store.groupConversationFeedback == "建群请求已安全保存，连接恢复后会继续。")
    }

    @Test func groupMemberDirectoryPaginatesThroughAnInjectableReader() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let reader = V2GroupMemberDirectoryFake(pages: [
            nil: .init(
                membershipRevision: 3,
                actorRole: "成员",
                members: [
                    .init(id: "owner", role: "群主", handle: "owner_1", displayName: "群主"),
                    .init(id: "member-a", role: "成员", handle: "member_a", displayName: "成员 A")
                ],
                nextCursor: "member-a"
            ),
            "member-a": .init(
                membershipRevision: 3,
                actorRole: "成员",
                members: [.init(id: "member-b", role: "成员")],
                nextCursor: nil
            )
        ])
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            groupMemberDirectory: reader
        )

        await store.loadGroupMembers(reset: true)
        await store.loadGroupMembers()

        #expect(store.groupMembers.map(\.id) == ["owner", "member-a", "member-b"])
        #expect(store.groupMembers.first?.displayName == "群主")
        #expect(store.groupMembers.first?.handle == "owner_1")
        #expect(store.groupMemberRevision == 3)
        #expect(!store.canLoadMoreGroupMembers)
        #expect(store.groupMemberFeedback == nil)
        #expect(await reader.requestedCursors() == [nil, "member-a"])
    }

    @Test func groupMembershipChangeUsesTheDirectoryRevisionAndRefreshes() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let page = V2GroupMemberPage(
            membershipRevision: 8,
            actorRole: "群主",
            members: [.init(id: "member-a", role: "成员")],
            nextCursor: nil
        )
        let reader = V2GroupMemberDirectoryFake(pages: [nil: page])
        let changer = V2GroupMembershipChangerFake(result: .accepted)
        let resolver = V2ConversationPublicIdentityResolverFake(values: ["member_b": "member-b"])
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            groupMemberDirectory: reader,
            groupMembershipChanger: changer,
            publicIdentityResolver: resolver
        )

        await store.loadGroupMembers(reset: true)
        await store.changeGroupMembership(targetUserID: "@member_b", action: .add)

        #expect(store.canAddGroupMembers)
        #expect(await changer.requests() == [.init(roomID: "room-group", targetUserID: "member-b", action: .add, expectedMembershipRevision: 8)])
        #expect(await reader.requestedCursors() == [nil, nil])
        #expect(store.groupMemberFeedback == nil)
    }

    @Test func strangerMessagePreferenceKeepsDurableQueuedIntentVisible() async {
        let reader = V2StrangerMessagePreferenceReaderFake(value: false)
        let updater = V2StrangerMessagePreferenceUpdaterFake(result: .queuedForRetry)
        let store = V2PrivacySettingsStore(reader: reader, updater: updater)

        await store.refresh()
        await store.setAllowsStrangerMessages(true)

        #expect(store.state == .loaded)
        #expect(store.allowsStrangerMessages)
        #expect(store.feedback == "设置已安全保存，连接恢复后会同步。")
        #expect(await updater.requestedValues() == [true])
    }

    @Test func strangerMessagePreferenceDoesNotChangeOnTerminalRejection() async {
        let reader = V2StrangerMessagePreferenceReaderFake(value: true)
        let updater = V2StrangerMessagePreferenceUpdaterFake(result: .rejected(code: "FORBIDDEN"))
        let store = V2PrivacySettingsStore(reader: reader, updater: updater)

        await store.refresh()
        await store.setAllowsStrangerMessages(false)

        #expect(store.allowsStrangerMessages)
        #expect(store.feedback == "设置被拒绝（FORBIDDEN）。")
    }
}

private actor V2ConversationDataSourceFake: V2ConversationDataSource {
    private let summaries: [V2ConversationListItem]
    private let messages: [V2ConversationMessageItem]
    private var requestedMessageCount = 0

    init(summaries: [V2ConversationListItem], messages: [V2ConversationMessageItem]) {
        self.summaries = summaries
        self.messages = messages
    }

    func conversationSummaries(for userID: String) async throws -> [V2ConversationListItem] {
        summaries
    }

    func messages(in roomID: String, for userID: String) async throws -> [V2ConversationMessageItem] {
        requestedMessageCount += 1
        return messages
    }

    func messageRequestCount() -> Int { requestedMessageCount }
}

private actor V2ConversationSenderFake: V2ConversationSending {
    private let result: V2ConversationSendOutcome
    private var messages: [V2SentMessage] = []

    init(result: V2ConversationSendOutcome) {
        self.result = result
    }

    func send(text: String, media: [V2MediaReference], in roomID: String) async throws -> V2ConversationSendOutcome {
        messages.append(.init(text: text, media: media, roomID: roomID))
        return result
    }

    func sentMessages() -> [V2SentMessage] {
        messages
    }
}

private struct V2SentMessage: Equatable, Sendable {
    let text: String
    let media: [V2MediaReference]
    let roomID: String

    init(text: String, media: [V2MediaReference] = [], roomID: String) {
        self.text = text
        self.media = media
        self.roomID = roomID
    }
}

private actor V2ConversationAttachmentStagerFake: V2ConversationAttachmentStaging {
    private let result: Result<V2StagedConversationAttachment, Error>
    private var discarded: [V2StagedConversationAttachment] = []

    init(result: Result<V2StagedConversationAttachment, Error>) { self.result = result }

    func stageImportedFile(at _: URL) throws -> V2StagedConversationAttachment {
        try result.get()
    }

    func discard(_ attachment: V2StagedConversationAttachment) {
        discarded.append(attachment)
    }

    func discardedAttachments() -> [V2StagedConversationAttachment] { discarded }
}

private actor V2ConversationAttachmentUploaderFake: V2ConversationAttachmentUploading {
    private let result: Result<V2MediaReference, Error>
    private var uploads: [V2StagedConversationAttachment] = []

    init(result: Result<V2MediaReference, Error>) { self.result = result }

    func upload(_ attachment: V2StagedConversationAttachment) throws -> V2MediaReference {
        uploads.append(attachment)
        return try result.get()
    }

    func uploadedAttachments() -> [V2StagedConversationAttachment] { uploads }
}

private enum V2ConversationMediaDownloadFailure: Error, Sendable {
    case failed
}

private actor V2ConversationMediaDownloaderFake: V2ConversationMediaDownloading {
    enum Result: Sendable {
        case success(V2DownloadedConversationMedia)
        case failure
    }

    private let result: Result
    private var requestsValue: [V2MediaReference] = []

    init(result: Result) {
        self.result = result
    }

    func download(_ media: V2MediaReference) throws -> V2DownloadedConversationMedia {
        requestsValue.append(media)
        switch result {
        case .success(let downloaded): return downloaded
        case .failure: throw V2ConversationMediaDownloadFailure.failed
        }
    }

    func requests() -> [V2MediaReference] { requestsValue }
}

private actor V2MediaDownloadTargetResolverFake: V2ClientMediaDownloadTargetResolver {
    private let target: V2ClientMediaTransferTarget
    private var requestsValue: [MediaID] = []

    init(target: V2ClientMediaTransferTarget) {
        self.target = target
    }

    func resolveDownloadTarget(mediaID: MediaID) -> V2ClientMediaTransferTarget {
        requestsValue.append(mediaID)
        return target
    }

    func requests() -> [MediaID] { requestsValue }
}

private enum V2MediaByteTransferFakeFailure: Error, Sendable {
    case uploadIsUnexpected
}

private actor V2MediaByteTransferFake: V2ClientMediaByteTransfer {
    private let downloadedData: Data
    private var destinationsValue: [URL] = []

    init(downloadedData: Data) {
        self.downloadedData = downloadedData
    }

    func upload(fileURL _: URL, target _: V2ClientMediaTransferTarget) throws {
        throw V2MediaByteTransferFakeFailure.uploadIsUnexpected
    }

    func download(target _: V2ClientMediaTransferTarget, destinationURL: URL) throws {
        destinationsValue.append(destinationURL)
        try downloadedData.write(to: destinationURL)
    }

    func downloadDestinations() -> [URL] { destinationsValue }
}

private enum V2AttachmentUploadFailure: Error { case failed }

private actor V2MessageWithdrawerFake: V2MessageWithdrawing {
    struct Request: Equatable, Sendable {
        let messageID: String
        let roomID: String
        let expectedMessageRevision: UInt64
    }

    private let result: V2MessageWithdrawalOutcome
    private var requestsValue: [Request] = []

    init(result: V2MessageWithdrawalOutcome) { self.result = result }

    func withdraw(messageID: String, in roomID: String, expectedMessageRevision: UInt64) async throws -> V2MessageWithdrawalOutcome {
        requestsValue.append(.init(messageID: messageID, roomID: roomID, expectedMessageRevision: expectedMessageRevision))
        return result
    }

    func requests() -> [Request] { requestsValue }
}

private actor V2MessageReactionChangerFake: V2MessageReactionChanging {
    struct Request: Equatable, Sendable {
        let messageID: String
        let roomID: String
        let reaction: String
        let action: V2MessageReactionAction
    }

    private let result: V2MessageReactionOutcome
    private var requestsValue: [Request] = []

    init(result: V2MessageReactionOutcome) { self.result = result }

    func changeReaction(messageID: String, in roomID: String, reaction: String, action: V2MessageReactionAction) async throws -> V2MessageReactionOutcome {
        requestsValue.append(.init(messageID: messageID, roomID: roomID, reaction: reaction, action: action))
        return result
    }

    func requests() -> [Request] { requestsValue }
}

private actor V2MessageEditorFake: V2MessageEditing {
    struct Request: Equatable, Sendable {
        let messageID: String
        let roomID: String
        let expectedMessageRevision: UInt64
        let text: String
    }

    private let result: V2MessageEditOutcome
    private var requestsValue: [Request] = []

    init(result: V2MessageEditOutcome) { self.result = result }

    func edit(messageID: String, in roomID: String, expectedMessageRevision: UInt64, text: String) async throws -> V2MessageEditOutcome {
        requestsValue.append(.init(messageID: messageID, roomID: roomID, expectedMessageRevision: expectedMessageRevision, text: text))
        return result
    }

    func requests() -> [Request] { requestsValue }
}

private actor V2ConversationReadReporterFake: V2ConversationReadReporting {
    struct Request: Equatable, Sendable {
        let roomID: String
        let roomSequence: UInt64
    }

    private let result: V2ReadReceiptReportOutcome
    private var requestsValue: [Request] = []

    init(result: V2ReadReceiptReportOutcome) { self.result = result }

    func recordReadThrough(roomID: String, roomSequence: UInt64) async throws -> V2ReadReceiptReportOutcome {
        requestsValue.append(.init(roomID: roomID, roomSequence: roomSequence))
        return result
    }

    func requests() -> [Request] { requestsValue }
}

private actor V2DirectConversationOpenerFake: V2DirectConversationOpening {
    private let roomID: String
    private var openedTargets: [String] = []

    init(roomID: String) {
        self.roomID = roomID
    }

    func openConversation(with publicIdentity: V2PublicIdentity) async throws -> String {
        openedTargets.append(publicIdentity.userID.rawValue)
        return roomID
    }

    func targets() -> [String] {
        openedTargets
    }
}

private actor V2ConversationPublicIdentityResolverFake: V2ConversationPublicIdentityResolving {
    private let values: [String: String]

    init(values: [String: String]) { self.values = values }

    func resolve(handle: String) async throws -> V2PublicIdentity {
        let normalized = try V2PublicHandle(handle).rawValue
        guard let userID = values[normalized] else { throw V2PublicIdentityDirectoryClientError.notFound }
        return try .init(userID: .init(userID), handle: .init(normalized), displayName: normalized)
    }
}

private actor V2GroupConversationCreatorFake: V2GroupConversationCreating {
    private let result: V2GroupConversationCreationOutcome
    private var requestsValue: [Request] = []
    init(result: V2GroupConversationCreationOutcome) { self.result = result }
    func createConversation(title: String, initialMemberUserIDs: [String]) async throws -> V2GroupConversationCreationOutcome {
        requestsValue.append(.init(title: title, memberUserIDs: initialMemberUserIDs))
        return result
    }
    func requests() -> [Request] { requestsValue }
    struct Request: Equatable, Sendable { let title: String; let memberUserIDs: [String] }
}

private actor V2GroupMemberDirectoryFake: V2GroupMemberDirectoryReading {
    private let pages: [String?: V2GroupMemberPage]
    private var cursors: [String?] = []

    init(pages: [String?: V2GroupMemberPage]) {
        self.pages = pages
    }

    func members(in roomID: String, cursor: String?) async throws -> V2GroupMemberPage {
        cursors.append(cursor)
        guard let page = pages[cursor] else { throw CancellationError() }
        return page
    }

    func requestedCursors() -> [String?] { cursors }
}

private actor V2GroupMembershipChangerFake: V2GroupMembershipChanging {
    struct Request: Equatable, Sendable {
        let roomID: String
        let targetUserID: String
        let action: V2RoomMembershipAction
        let expectedMembershipRevision: UInt64
    }

    private let result: V2GroupMembershipChangeOutcome
    private var requestsValue: [Request] = []

    init(result: V2GroupMembershipChangeOutcome) { self.result = result }

    func changeMembership(roomID: String, targetUserID: String, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) async throws -> V2GroupMembershipChangeOutcome {
        requestsValue.append(.init(roomID: roomID, targetUserID: targetUserID, action: action, expectedMembershipRevision: expectedMembershipRevision))
        return result
    }

    func requests() -> [Request] { requestsValue }
}

private actor V2StrangerMessagePreferenceReaderFake: V2StrangerMessagePreferenceReading {
    private let value: Bool?

    init(value: Bool?) {
        self.value = value
    }

    func strangerMessagePreference() async throws -> Bool? {
        value
    }
}

private actor V2StrangerMessagePreferenceUpdaterFake: V2StrangerMessagePreferenceUpdating {
    private let result: V2StrangerMessagePreferenceUpdateOutcome
    private var values: [Bool] = []

    init(result: V2StrangerMessagePreferenceUpdateOutcome) {
        self.result = result
    }

    func update(allowsStrangerMessages: Bool) async throws -> V2StrangerMessagePreferenceUpdateOutcome {
        values.append(allowsStrangerMessages)
        return result
    }

    func requestedValues() -> [Bool] {
        values
    }
}
