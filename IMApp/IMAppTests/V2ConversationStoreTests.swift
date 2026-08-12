import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2ConversationStoreTests {
    @Test func conversationListShowsAnEmptyDirectRoomWithItsAuthorizedIdentity() throws {
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000e02")
        let identity = try V2PublicIdentity(
            userID: .init("00000000-0000-0000-0000-000000000e03"),
            handle: .init("empty_direct"),
            displayName: "尚未聊天的用户"
        )
        let updatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let items = V2GRDBConversationDataSource.mergingEmptyProjectionItems(
            messageItems: [],
            profiles: [],
            directIdentities: [.init(roomID: roomID, publicIdentity: identity, updatedAt: updatedAt)]
        )

        #expect(items == [
            .init(id: roomID.rawValue, title: "尚未聊天的用户", preview: "暂无消息", lastActivity: updatedAt, isOutgoing: false, kind: .direct)
        ])
    }

    @Test func emptyConversationKeepsItsDurablePinnedArchiveAndMuteState() throws {
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000e12")
        let identity = try V2PublicIdentity(
            userID: .init("00000000-0000-0000-0000-000000000e13"),
            handle: .init("empty_state"),
            displayName: "空会话"
        )
        let updatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let muteUntil = updatedAt.addingTimeInterval(3_600)
        let state = V2ClientConversationState(
            roomID: roomID,
            isPinned: true,
            isArchived: true,
            muteUntil: muteUntil,
            updatedAt: updatedAt
        )

        let items = V2GRDBConversationDataSource.mergingEmptyProjectionItems(
            messageItems: [],
            profiles: [],
            directIdentities: [.init(roomID: roomID, publicIdentity: identity, updatedAt: updatedAt)],
            conversationStates: [roomID: state]
        )

        #expect(items == [
            .init(id: roomID.rawValue, title: "空会话", preview: "暂无消息", lastActivity: updatedAt, isOutgoing: false, kind: .direct, isPinned: true, isArchived: true, muteUntil: muteUntil)
        ])
    }

    @Test func detailStoreExposesGroupControlsOnlyForKnownGroupRooms() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source = V2ConversationDataSourceFake(
            summaries: [
                .init(id: "room-direct", title: "私聊", preview: "你好", lastActivity: date, isOutgoing: false, kind: .direct),
                .init(id: "room-group", title: "项目群", preview: "大家好", lastActivity: date, isOutgoing: false, kind: .group)
            ],
            messages: []
        )
        let store = V2ConversationListStore(dataSource: source, userID: "current-user")
        await store.refresh()

        #expect(!store.detailStore(for: "room-direct").isGroupConversation)
        #expect(store.detailStore(for: "room-group").isGroupConversation)
    }

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

    @Test func listRefreshIgnoresAResponseSupersededByANewerRefresh() async {
        let source = V2SequencedConversationDataSource()
        let store = V2ConversationListStore(dataSource: source, userID: "current-user")
        let staleItem = V2ConversationListItem(id: "room-stale", title: "旧会话", preview: "旧消息", lastActivity: .now, isOutgoing: false)
        let currentItem = V2ConversationListItem(id: "room-current", title: "新会话", preview: "新消息", lastActivity: .now, isOutgoing: false)

        let firstRefresh = Task { await store.refresh() }
        await source.waitUntilSummaryRequestCount(1)
        let secondRefresh = Task { await store.refresh() }
        await source.waitUntilSummaryRequestCount(2)

        await source.completeSummaryRequest(at: 1, with: [currentItem])
        await secondRefresh.value
        await source.completeSummaryRequest(at: 0, with: [staleItem])
        await firstRefresh.value

        #expect(store.state == .loaded)
        #expect(store.items == [currentItem])
    }

    @Test func messageRefreshIgnoresAResponseSupersededByANewerRefresh() async {
        let source = V2SequencedConversationDataSource()
        let store = V2ConversationDetailStore(dataSource: source, sender: nil, userID: "current-user", roomID: "room-a")
        let staleMessage = V2ConversationMessageItem(id: "message-stale", revision: 1, text: "旧消息", createdAt: .now, isOutgoing: false, isWithdrawn: false)
        let currentMessage = V2ConversationMessageItem(id: "message-current", revision: 1, text: "新消息", createdAt: .now, isOutgoing: false, isWithdrawn: false)

        let firstRefresh = Task { await store.refresh() }
        await source.waitUntilMessageRequestCount(1)
        let secondRefresh = Task { await store.refresh() }
        await source.waitUntilMessageRequestCount(2)

        await source.completeMessageRequest(at: 1, with: [currentMessage])
        await secondRefresh.value
        await source.completeMessageRequest(at: 0, with: [staleMessage])
        await firstRefresh.value

        #expect(store.state == .loaded)
        #expect(store.messages == [currentMessage])
    }

    @Test func messageRefreshIgnoresAFailureSupersededByANewerRefresh() async {
        let source = V2SequencedConversationDataSource()
        let store = V2ConversationDetailStore(dataSource: source, sender: nil, userID: "current-user", roomID: "room-a")
        let currentMessage = V2ConversationMessageItem(id: "message-current", revision: 1, text: "新消息", createdAt: .now, isOutgoing: false, isWithdrawn: false)

        let firstRefresh = Task { await store.refresh() }
        await source.waitUntilMessageRequestCount(1)
        let secondRefresh = Task { await store.refresh() }
        await source.waitUntilMessageRequestCount(2)

        await source.completeMessageRequest(at: 1, with: [currentMessage])
        await secondRefresh.value
        await source.failMessageRequest(at: 0)
        await firstRefresh.value

        #expect(store.state == .loaded)
        #expect(store.messages == [currentMessage])
    }

    @Test func detailRefreshesItsLocalProjectionAfterASynchronizedUpdate() async {
        let source = V2SequencedConversationDataSource()
        let notifier = V2ProjectionChangeNotifier()
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-a",
            projectionChangeNotifier: notifier
        )
        let initialMessage = V2ConversationMessageItem(
            id: "message-initial",
            revision: 1,
            text: "同步前消息",
            createdAt: .now,
            isOutgoing: false,
            isWithdrawn: false
        )
        let synchronizedMessage = V2ConversationMessageItem(
            id: "message-synchronized",
            revision: 1,
            text: "同步后消息",
            createdAt: .now,
            isOutgoing: false,
            isWithdrawn: false
        )

        let observer = Task { await store.observeProjectionChanges() }
        await source.waitUntilMessageRequestCount(1)
        await source.completeMessageRequest(at: 0, with: [initialMessage])
        await notifier.publish()
        await source.waitUntilMessageRequestCount(2)
        await source.completeMessageRequest(at: 1, with: [initialMessage, synchronizedMessage])
        await notifier.publish()
        await source.waitUntilMessageRequestCount(3)

        #expect(store.messages == [initialMessage, synchronizedMessage])

        await source.completeMessageRequest(at: 2, with: [initialMessage, synchronizedMessage])
        await Task.yield()
        observer.cancel()
        await observer.value
    }

    @Test func messageRefreshPreservesOnlyOpaqueAttachmentReferences() async throws {
        let reference = V2MediaReference(mediaID: try .init("00000000-0000-0000-0000-000000000501"))
        let message = V2ConversationMessageItem(
            id: "message-with-attachment",
            revision: 1,
            text: "附件说明",
            media: [reference],
            mediaPresentations: [try testPresentation(for: reference)],
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
            mediaPresentations: [try testPresentation(for: reference)],
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
            mediaPresentations: [try testPresentation(for: reference)],
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

    @Test func refreshedRedactionDiscardsEveryCachedAttachmentFromTheFormerMessage() async throws {
        let firstReference = V2MediaReference(mediaID: try .init("00000000-0000-0000-0000-000000000513"))
        let secondReference = V2MediaReference(mediaID: try .init("00000000-0000-0000-0000-000000000514"))
        let visible = V2ConversationMessageItem(
            id: "message-later-redacted",
            revision: 1,
            text: "带有两个附件的消息",
            media: [firstReference, secondReference],
            mediaPresentations: [try testPresentation(for: firstReference), try testPresentation(for: secondReference)],
            createdAt: .now,
            isOutgoing: false,
            isWithdrawn: false
        )
        let redacted = V2ConversationMessageItem(
            id: visible.id,
            revision: 2,
            text: "消息已撤回",
            createdAt: visible.createdAt,
            isOutgoing: false,
            isWithdrawn: true
        )
        let source = V2SequencedConversationDataSource()
        let downloader = V2ConversationMediaCacheDiscardingFake()
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-a",
            mediaDownloader: downloader
        )

        let initialRefresh = Task { await store.refresh() }
        await source.waitUntilMessageRequestCount(1)
        await source.completeMessageRequest(at: 0, with: [visible])
        await initialRefresh.value

        let redactionRefresh = Task { await store.refresh() }
        await source.waitUntilMessageRequestCount(2)
        await source.completeMessageRequest(at: 1, with: [redacted])
        await redactionRefresh.value

        #expect(store.messages == [redacted])
        #expect(await downloader.discardedReferences() == [firstReference, secondReference])
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

    @Test func messageSendAllowsOnlyOneDurableSubmissionAtATime() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2SuspendingConversationSender()
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-a"
        )
        store.draft = "只发送一次"

        let firstSubmission = Task { await store.sendDraft() }
        await sender.waitUntilSending()
        await store.sendDraft()

        #expect(store.isSending)
        #expect(await sender.sentMessages() == [.init(text: "只发送一次", roomID: "room-a")])
        await sender.complete()
        await firstSubmission.value

        #expect(!store.isSending)
        #expect(store.draft.isEmpty)
    }

    @Test func messageSendIgnoresLateSuccessAfterCancellation() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2SuspendingConversationSender()
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-a"
        )
        store.draft = "保留草稿"

        let submission = Task { await store.sendDraft() }
        await sender.waitUntilSending()
        submission.cancel()
        await sender.complete()
        await submission.value

        #expect(!store.isSending)
        #expect(store.draft == "保留草稿")
        #expect(store.sendFeedback == nil)
    }

    @Test func messageSendExplainsRateLimitWithoutDiscardingTheDraft() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2ConversationSenderFake(result: .rejected(code: "RATE_LIMITED"))
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-a"
        )
        store.draft = "稍后再发"

        await store.sendDraft()

        #expect(store.draft == "稍后再发")
        #expect(store.sendFeedback == "发送失败：发送频率已达上限，请稍后再试。")
        #expect(await sender.sentMessages() == [.init(text: "稍后再发", roomID: "room-a")])
    }

    @Test func messageSendKeepsPrivacyDenialReasonOpaque() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2ConversationSenderFake(result: .rejected(code: "FORBIDDEN"))
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-a"
        )
        store.draft = "陌生消息"

        await store.sendDraft()

        #expect(store.draft == "陌生消息")
        #expect(store.sendFeedback == "当前无法向此会话发送消息。")
        #expect(await sender.sentMessages() == [.init(text: "陌生消息", roomID: "room-a")])
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

    @Test func invalidMentionDoesNotUploadOrScanStagedAttachments() async throws {
        let staged = V2StagedConversationAttachment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000612")!,
            fileURL: URL(fileURLWithPath: "/tmp/v2-invalid-mention-attachment"),
            displayName: "document.pdf",
            contentType: "application/pdf",
            byteCount: 42
        )
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2ConversationSenderFake(result: .accepted)
        let stager = V2ConversationAttachmentStagerFake(result: .success(staged))
        let reference = V2MediaReference(mediaID: try .init("00000000-0000-0000-0000-000000000613"))
        let uploader = V2ConversationAttachmentUploaderFake(result: .success(reference))
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-group",
            isGroupConversation: true,
            attachmentStager: stager,
            attachmentUploader: uploader
        )
        store.draft = "附件说明"
        store.mentionHandlesText = "@member_a"

        await store.stageAttachment(from: URL(fileURLWithPath: "/tmp/imported-document.pdf"))
        await store.sendDraft()

        #expect(await uploader.uploadedAttachments().isEmpty)
        #expect(await sender.sentMessages().isEmpty)
        #expect(store.attachments.count == 1)
        #expect(store.draft == "附件说明")
        #expect(store.mentionHandlesText == "@member_a")
        #expect(store.sendFeedback == "身份目录暂不可用，无法解析提及对象。")
        #expect(await stager.discardedAttachments().isEmpty)
    }

    @Test func groupMessageResolvesPublicHandlesAndSendsBoundedMentionTargets() async throws {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2ConversationSenderFake(result: .accepted)
        let resolver = V2ConversationPublicIdentityResolverFake(values: ["member_a": "member-a"])
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-group",
            isGroupConversation: true,
            publicIdentityResolver: resolver
        )
        store.draft = "请关注"
        store.mentionHandlesText = "@member_a, @all"
        let expectedMentions: [V2MentionTarget] = [.user(try .init("member-a")), .everyone]

        await store.sendDraft()

        #expect(await sender.sentMessages() == [
            .init(text: "请关注", roomID: "room-group", mentions: expectedMentions)
        ])
        #expect(store.mentionHandlesText.isEmpty)
        #expect(store.sendFeedback == "已发送，正在同步。")
    }

    @Test func groupMessageSendsEveryoneMentionWhenTheIdentityDirectoryIsUnavailable() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2ConversationSenderFake(result: .accepted)
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-group",
            isGroupConversation: true
        )
        store.draft = "全体注意"
        store.mentionHandlesText = "@all"

        await store.sendDraft()

        #expect(await sender.sentMessages() == [
            .init(text: "全体注意", roomID: "room-group", mentions: [.everyone])
        ])
        #expect(store.mentionHandlesText.isEmpty)
        #expect(store.sendFeedback == "已发送，正在同步。")
    }

    @Test func groupMessageDoesNotSendDuplicateMentionTargets() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2ConversationSenderFake(result: .accepted)
        let resolver = V2ConversationPublicIdentityResolverFake(values: ["member_a": "member-a"])
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-group",
            isGroupConversation: true,
            publicIdentityResolver: resolver
        )
        store.draft = "请关注"
        store.mentionHandlesText = "@member_a, @member_a"

        await store.sendDraft()

        #expect(await sender.sentMessages().isEmpty)
        #expect(store.draft == "请关注")
        #expect(store.sendFeedback == "提及对象不能重复。")
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
        #expect(try staged.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try stagingDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

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

    @Test func messageWithdrawalAllowsOnlyOneInFlightActionPerMessage() async {
        let message = V2ConversationMessageItem(
            id: "message-a",
            revision: 4,
            text: "需要撤回",
            createdAt: .now,
            isOutgoing: true,
            isWithdrawn: false
        )
        let source = V2ConversationDataSourceFake(summaries: [], messages: [message])
        let withdrawer = V2SuspendingMessageWithdrawer(result: .accepted)
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            messageWithdrawer: withdrawer,
            userID: "current-user",
            roomID: "room-a"
        )

        let firstWithdrawal = Task { await store.withdrawMessage(message) }
        await withdrawer.waitUntilRequested()
        await store.withdrawMessage(message)

        #expect(store.isMessageActionInFlight(message))
        #expect(!store.canWithdrawMessage(message))
        #expect(!store.canEditMessage(message))
        #expect(!store.canReactToMessage(message))
        #expect(await withdrawer.requests().count == 1)

        await withdrawer.complete()
        await firstWithdrawal.value

        #expect(!store.isMessageActionInFlight(message))
        #expect(await withdrawer.requests().count == 1)
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

    @Test func visibleMessageReportsTheNewestVisibleRoomSequence() async throws {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [
            .init(id: "message-a", roomSequence: 4, revision: 1, text: "较早", createdAt: .now, isOutgoing: false, isWithdrawn: false),
            .init(id: "message-b", roomSequence: 9, revision: 1, text: "最新", createdAt: .now, isOutgoing: true, isWithdrawn: false)
        ])
        let reporter = V2ConversationReadReporterFake(result: .queuedForRetry)
        let store = V2ConversationDetailStore(dataSource: source, sender: nil, readReceiptReporter: reporter, userID: "current-user", roomID: "room-a")

        await store.refresh()
        await store.reportVisibleMessage(try #require(store.messages.last))

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

    @Test func cancellingDirectConversationResolutionDoesNotOpenARoom() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let opener = V2DirectConversationOpenerFake(roomID: "room-direct")
        let resolver = V2SuspendingConversationPublicIdentityResolver()
        let store = V2ConversationListStore(
            dataSource: source,
            userID: "current-user",
            directConversationOpener: opener,
            publicIdentityResolver: resolver
        )

        let operation = Task { await store.openDirectConversation(handle: "@other_user") }
        await resolver.waitUntilResolving()
        operation.cancel()

        #expect(await operation.value == nil)
        #expect(await opener.targets().isEmpty)
        #expect(store.directConversationFeedback == nil)
    }

    @Test func cancellingDirectConversationAfterAnUncooperativeResolutionDoesNotOpenARoom() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let opener = V2DirectConversationOpenerFake(roomID: "room-direct")
        let resolver = V2CancellationIgnoringConversationPublicIdentityResolver()
        let store = V2ConversationListStore(
            dataSource: source,
            userID: "current-user",
            directConversationOpener: opener,
            publicIdentityResolver: resolver
        )

        let operation = Task { await store.openDirectConversation(handle: "@other_user") }
        await resolver.waitUntilResolving()
        operation.cancel()
        await resolver.completeResolution()

        #expect(await operation.value == nil)
        #expect(await opener.targets().isEmpty)
        #expect(store.directConversationFeedback == nil)
    }

    @Test func cancellingDirectConversationAfterLateOpenDoesNotReturnARoom() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let opener = V2SuspendingDirectConversationOpener(roomID: "room-direct")
        let resolver = V2ConversationPublicIdentityResolverFake(values: ["other_user": "other-user"])
        let store = V2ConversationListStore(
            dataSource: source,
            userID: "current-user",
            directConversationOpener: opener,
            publicIdentityResolver: resolver
        )

        let operation = Task { await store.openDirectConversation(handle: "@other_user") }
        await opener.waitUntilOpening()
        operation.cancel()
        await opener.complete()

        #expect(await operation.value == nil)
        #expect(store.directConversationFeedback == nil)
    }

    @Test func directConversationAllowsOnlyOneInFlightOpen() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let opener = V2SuspendingDirectConversationOpener(roomID: "room-direct")
        let resolver = V2ConversationPublicIdentityResolverFake(values: ["other_user": "other-user"])
        let store = V2ConversationListStore(
            dataSource: source,
            userID: "current-user",
            directConversationOpener: opener,
            publicIdentityResolver: resolver
        )

        let firstOpen = Task { await store.openDirectConversation(handle: "@other_user") }
        await opener.waitUntilOpening()
        let duplicateResult = await store.openDirectConversation(handle: "@other_user")

        #expect(duplicateResult == nil)
        #expect(store.isOpeningDirectConversation)
        #expect(await opener.openingCount() == 1)
        await opener.complete()
        #expect(await firstOpen.value == "room-direct")
        #expect(!store.isOpeningDirectConversation)
    }

    @Test func cancellingGroupCreationAfterAnUncooperativeResolutionDoesNotCreateARoom() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let creator = V2GroupConversationCreatorFake(result: .created(roomID: "room-group"))
        let resolver = V2CancellationIgnoringConversationPublicIdentityResolver()
        let store = V2ConversationListStore(
            dataSource: source,
            userID: "current-user",
            publicIdentityResolver: resolver,
            groupConversationCreator: creator
        )

        let operation = Task { await store.createGroupConversation(title: "项目群", memberHandlesText: "@other_user") }
        await resolver.waitUntilResolving()
        operation.cancel()
        await resolver.completeResolution()

        #expect(await operation.value == nil)
        #expect(await creator.requests().isEmpty)
        #expect(store.groupConversationFeedback == nil)
    }

    @Test func groupConversationSplitsCanonicalMemberInputAndReturnsRoom() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let creator = V2GroupConversationCreatorFake(result: .created(roomID: "room-group"))
        let resolver = V2ConversationPublicIdentityResolverFake(values: ["user_a": "user-a", "user_b": "user-b"])
        let store = V2ConversationListStore(dataSource: source, userID: "current-user", publicIdentityResolver: resolver, groupConversationCreator: creator)

        let roomID = await store.createGroupConversation(title: " 项目群 ", memberHandlesText: " @user_a,\n@user_b ")

        #expect(roomID == "room-group")
        #expect(await creator.requests() == [.init(title: " 项目群 ", memberUserIDs: ["user-a", "user-b"])])
        #expect(store.detailStore(for: "room-group").isGroupConversation)
    }

    @Test func groupConversationKeepsDurableRetryVisible() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let creator = V2GroupConversationCreatorFake(result: .queuedForRetry(operationID: "group-operation-1"))
        let store = V2ConversationListStore(dataSource: source, userID: "current-user", groupConversationCreator: creator)

        let roomID = await store.createGroupConversation(title: "项目群", memberHandlesText: "")

        #expect(roomID == nil)
        #expect(store.groupConversationFeedback == "建群请求已安全保存；取消可阻止其在恢复连接后继续创建。")
        #expect(store.pendingGroupConversationOperationID == "group-operation-1")

        await store.cancelPendingGroupConversationCreation()

        #expect(await creator.cancelledOperationIDs() == ["group-operation-1"])
        #expect(store.pendingGroupConversationOperationID == nil)
        #expect(store.groupConversationFeedback == "建群请求正在取消；恢复连接后会完成取消。")
    }

    @Test func groupConversationRestoresDurableFinalizingStatusAfterUIRecreation() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let creator = V2GroupConversationCreatorFake(
            result: .queuedForRetry(operationID: "unused"),
            restoredStatus: .finalizing(operationID: "group-operation-2")
        )
        let store = V2ConversationListStore(dataSource: source, userID: "current-user", groupConversationCreator: creator)

        await store.refresh()

        #expect(store.pendingGroupConversationOperationID == nil)
        #expect(store.groupConversationFeedback == "群聊已进入创建阶段，无法取消；完成后会显示在会话列表。")
    }

    @Test func groupConversationAllowsOnlyOneInFlightCreation() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let creator = V2SuspendingGroupConversationCreator(result: .created(roomID: "room-group"))
        let store = V2ConversationListStore(
            dataSource: source,
            userID: "current-user",
            groupConversationCreator: creator
        )

        let firstCreation = Task {
            await store.createGroupConversation(title: "项目群", memberHandlesText: "")
        }
        await creator.waitUntilCreating()
        let duplicateResult = await store.createGroupConversation(title: "项目群", memberHandlesText: "")

        #expect(duplicateResult == nil)
        #expect(store.isCreatingGroupConversation)
        #expect(await creator.creationCount() == 1)
        await creator.complete()
        #expect(await firstCreation.value == "room-group")
        #expect(!store.isCreatingGroupConversation)
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

    @Test func groupMemberLoadAllowsOnlyOneInFlightDirectoryRequest() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let reader = V2SuspendingGroupMemberDirectory(page: .init(
            membershipRevision: 3,
            actorRole: "成员",
            members: [.init(id: "owner", role: "群主")],
            nextCursor: nil
        ))
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            isGroupConversation: true,
            groupMemberDirectory: reader
        )

        let firstLoad = Task { await store.loadGroupMembers(reset: true) }
        await reader.waitUntilRequested()
        await store.loadGroupMembers(reset: true)

        #expect(store.isLoadingGroupMembers)
        #expect(await reader.requestedCursors() == [nil])
        await reader.complete()
        await firstLoad.value

        #expect(!store.isLoadingGroupMembers)
        #expect(store.groupMembers.map(\.id) == ["owner"])
        #expect(store.groupMemberFeedback == nil)
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

    @Test func groupMembershipChangeAllowsOnlyOneInFlightCommand() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let page = V2GroupMemberPage(
            membershipRevision: 8,
            actorRole: "群主",
            members: [.init(id: "member-a", role: "成员")],
            nextCursor: nil
        )
        let reader = V2GroupMemberDirectoryFake(pages: [nil: page])
        let changer = V2SuspendingGroupMembershipChanger(result: .queuedForRetry)
        let resolver = V2ConversationPublicIdentityResolverFake(values: ["member_b": "member-b"])
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            isGroupConversation: true,
            groupMemberDirectory: reader,
            groupMembershipChanger: changer,
            publicIdentityResolver: resolver
        )
        await store.loadGroupMembers(reset: true)

        let firstChange = Task { await store.changeGroupMembership(targetUserID: "@member_b", action: .add) }
        await changer.waitUntilRequested()
        await store.changeGroupMembership(targetUserID: "member-a", action: .remove)

        #expect(store.isChangingGroupMembership)
        #expect(await changer.requests() == [.init(roomID: "room-group", targetUserID: "member-b", action: .add, expectedMembershipRevision: 8)])
        await changer.complete()
        await firstChange.value

        #expect(!store.isChangingGroupMembership)
        #expect(store.groupMemberFeedback == "成员变更已安全保存，连接恢复后会继续。")
    }

    @Test func groupMembershipChangeIgnoresLateSuccessAfterCancellation() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let page = V2GroupMemberPage(
            membershipRevision: 8,
            actorRole: "群主",
            members: [.init(id: "member-a", role: "成员")],
            nextCursor: nil
        )
        let reader = V2GroupMemberDirectoryFake(pages: [nil: page])
        let changer = V2SuspendingGroupMembershipChanger(result: .accepted)
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            isGroupConversation: true,
            groupMemberDirectory: reader,
            groupMembershipChanger: changer
        )
        await store.loadGroupMembers(reset: true)

        let change = Task { await store.changeGroupMembership(targetUserID: "member-a", action: .remove) }
        await changer.waitUntilRequested()
        change.cancel()
        await changer.complete()
        await change.value

        #expect(!store.isChangingGroupMembership)
        #expect(store.groupMemberFeedback == nil)
        #expect(await reader.requestedCursors() == [nil])
    }

    @Test func cancellingMemberAdditionAfterAnUncooperativeIdentityResolutionDoesNotChangeMembership() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let page = V2GroupMemberPage(
            membershipRevision: 8,
            actorRole: "群主",
            members: [.init(id: "member-a", role: "成员")],
            nextCursor: nil
        )
        let reader = V2GroupMemberDirectoryFake(pages: [nil: page])
        let changer = V2GroupMembershipChangerFake(result: .accepted)
        let resolver = V2CancellationIgnoringConversationPublicIdentityResolver()
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            isGroupConversation: true,
            groupMemberDirectory: reader,
            groupMembershipChanger: changer,
            publicIdentityResolver: resolver
        )
        await store.loadGroupMembers(reset: true)

        let change = Task { await store.changeGroupMembership(targetUserID: "@member_b", action: .add) }
        await resolver.waitUntilResolving()
        change.cancel()
        await resolver.completeResolution()
        await change.value

        #expect(await changer.requests().isEmpty)
        #expect(!store.isChangingGroupMembership)
        #expect(store.groupMemberFeedback == nil)
    }

    @Test func groupMuteUsesItsOwnDurableModerationBoundary() async throws {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let page = V2GroupMemberPage(
            membershipRevision: 8,
            actorRole: "管理员",
            members: [.init(id: "member-a", role: "成员")],
            nextCursor: nil
        )
        let reader = V2GroupMemberDirectoryFake(pages: [nil: page])
        let muter = V2GroupMemberMuterFake(result: .accepted)
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            isGroupConversation: true,
            groupMemberDirectory: reader,
            groupMemberMuter: muter
        )

        await store.loadGroupMembers(reset: true)
        await store.muteGroupMember(try #require(store.groupMembers.first))

        let request = try #require(await muter.requests().first)
        #expect(request.roomID == "room-group")
        #expect(request.targetUserID == "member-a")
        #expect(request.reasonCode == "ADMIN_ACTION")
        #expect(request.muteUntil.timeIntervalSinceNow > 3_500)
        #expect(store.groupMemberFeedback == "禁言已提交，正在同步。")
        #expect(!store.isApplyingGroupModeration)
    }

    @Test func moderatedRemovalUsesItsOwnAuditedBoundaryAndRefreshesTheRoster() async throws {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let page = V2GroupMemberPage(
            membershipRevision: 8,
            actorRole: "群主",
            members: [.init(id: "member-a", role: "成员")],
            nextCursor: nil
        )
        let reader = V2GroupMemberDirectoryFake(pages: [nil: page])
        let remover = V2ModeratedGroupMemberRemoverFake(result: .accepted)
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            isGroupConversation: true,
            groupMemberDirectory: reader,
            moderatedGroupMemberRemover: remover
        )

        await store.loadGroupMembers(reset: true)
        await store.removeGroupMemberByModerator(try #require(store.groupMembers.first))

        #expect(await remover.requests() == [.init(roomID: "room-group", targetUserID: "member-a", reasonCode: "ADMIN_ACTION")])
        #expect(await reader.requestedCursors() == [nil, nil])
        #expect(store.groupMemberFeedback == nil)
        #expect(!store.isApplyingGroupModeration)
    }

    @Test func groupMembershipChangeWaitsForInFlightModeratedRemoval() async throws {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let page = V2GroupMemberPage(
            membershipRevision: 8,
            actorRole: "群主",
            members: [.init(id: "member-a", role: "成员")],
            nextCursor: nil
        )
        let reader = V2GroupMemberDirectoryFake(pages: [nil: page])
        let remover = V2SuspendingModeratedGroupMemberRemover(result: .accepted)
        let changer = V2GroupMembershipChangerFake(result: .accepted)
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            isGroupConversation: true,
            groupMemberDirectory: reader,
            groupMembershipChanger: changer,
            moderatedGroupMemberRemover: remover
        )

        await store.loadGroupMembers(reset: true)
        let member = try #require(store.groupMembers.first)
        let removal = Task { await store.removeGroupMemberByModerator(member) }
        await remover.waitUntilRequested()

        await store.changeGroupMembership(targetUserID: "member-b", action: .add)

        #expect(store.isApplyingGroupModeration)
        #expect(!store.isChangingGroupMembership)
        #expect(await changer.requests().isEmpty)
        await remover.complete()
        await removal.value
        #expect(!store.isApplyingGroupModeration)
    }

    @Test func rejectedGroupModerationKeepsTheServerReasonOpaque() async throws {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let page = V2GroupMemberPage(
            membershipRevision: 8,
            actorRole: "管理员",
            members: [.init(id: "member-a", role: "成员")],
            nextCursor: nil
        )
        let reader = V2GroupMemberDirectoryFake(pages: [nil: page])
        let muter = V2GroupMemberMuterFake(result: .rejected(code: "TARGET_POLICY"))
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            isGroupConversation: true,
            groupMemberDirectory: reader,
            groupMemberMuter: muter
        )

        await store.loadGroupMembers(reset: true)
        await store.muteGroupMember(try #require(store.groupMembers.first))

        #expect(store.groupMemberFeedback == "无法完成群管理操作。")
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

    @Test func userAddPreferenceKeepsDurableQueuedIntentVisible() async {
        let reader = V2StrangerMessagePreferenceReaderFake(value: true)
        let updater = V2StrangerMessagePreferenceUpdaterFake(result: .accepted)
        let userAddReader = V2UserAddPreferenceReaderFake(value: true)
        let userAddUpdater = V2UserAddPreferenceUpdaterFake(result: .queuedForRetry)
        let store = V2PrivacySettingsStore(reader: reader, updater: updater, userAddReader: userAddReader, userAddUpdater: userAddUpdater)

        await store.refresh()
        await store.setAllowsBeingAdded(false)

        #expect(store.state == .loaded)
        #expect(!store.allowsBeingAdded)
        #expect(store.feedback == "设置已安全保存，连接恢复后会同步。")
        #expect(await userAddUpdater.requestedValues() == [false])
    }

    @Test func liveActivityPreferencesRefreshAndPersistBothValuesAtomically() async {
        let reader = V2StrangerMessagePreferenceReaderFake(value: true)
        let updater = V2StrangerMessagePreferenceUpdaterFake(result: .accepted)
        let liveActivityReader = V2LiveActivityPreferenceReaderFake(
            value: .init(allowsOnlinePresence: false, allowsTypingIndicators: true, updatedAt: .now)
        )
        let liveActivityUpdater = V2LiveActivityPreferenceUpdaterFake(result: .accepted)
        let store = V2PrivacySettingsStore(
            reader: reader,
            updater: updater,
            liveActivityUpdater: liveActivityUpdater,
            liveActivityReader: liveActivityReader
        )

        await store.refresh()
        await store.setLiveActivityPermission(typing: false)

        #expect(store.state == .loaded)
        #expect(!store.allowsOnlinePresence)
        #expect(!store.allowsTypingIndicators)
        #expect(store.feedback == "已更新在线与输入状态设置。")
        #expect(await liveActivityUpdater.requests() == [.init(online: false, typing: false)])
    }

    @Test func rejectedLiveActivityPreferenceKeepsTheLastProjectedValues() async {
        let reader = V2StrangerMessagePreferenceReaderFake(value: true)
        let updater = V2StrangerMessagePreferenceUpdaterFake(result: .accepted)
        let liveActivityReader = V2LiveActivityPreferenceReaderFake(
            value: .init(allowsOnlinePresence: true, allowsTypingIndicators: false, updatedAt: .now)
        )
        let liveActivityUpdater = V2LiveActivityPreferenceUpdaterFake(result: .rejected(code: "FORBIDDEN"))
        let store = V2PrivacySettingsStore(
            reader: reader,
            updater: updater,
            liveActivityUpdater: liveActivityUpdater,
            liveActivityReader: liveActivityReader
        )

        await store.refresh()
        await store.setLiveActivityPermission(online: false)

        #expect(store.allowsOnlinePresence)
        #expect(!store.allowsTypingIndicators)
        #expect(store.feedback == "设置被拒绝（FORBIDDEN）。")
        #expect(await liveActivityUpdater.requests() == [.init(online: false, typing: false)])
    }

    @Test func cancelledLiveActivityPreferenceIgnoresALateSuccess() async {
        let reader = V2StrangerMessagePreferenceReaderFake(value: true)
        let updater = V2StrangerMessagePreferenceUpdaterFake(result: .accepted)
        let liveActivityReader = V2LiveActivityPreferenceReaderFake(
            value: .init(allowsOnlinePresence: true, allowsTypingIndicators: true, updatedAt: .now)
        )
        let liveActivityUpdater = V2LateLiveActivityPreferenceUpdater()
        let store = V2PrivacySettingsStore(
            reader: reader,
            updater: updater,
            liveActivityUpdater: liveActivityUpdater,
            liveActivityReader: liveActivityReader
        )

        await store.refresh()
        let update = Task { await store.setLiveActivityPermission(online: false) }
        await liveActivityUpdater.waitUntilResponseIsPending()
        update.cancel()
        await liveActivityUpdater.resumeAccepted()
        await update.value

        #expect(store.allowsOnlinePresence)
        #expect(store.allowsTypingIndicators)
        #expect(store.feedback == nil)
        #expect(!store.isSaving)
    }

    @Test func strangerMessagePreferenceRefreshIgnoresAFailureSupersededByANewerRefresh() async {
        let reader = V2SequencedStrangerMessagePreferenceReader()
        let updater = V2StrangerMessagePreferenceUpdaterFake(result: .accepted)
        let store = V2PrivacySettingsStore(reader: reader, updater: updater)

        let firstRefresh = Task { await store.refresh() }
        await reader.waitUntilRequestCount(1)
        let secondRefresh = Task { await store.refresh() }
        await reader.waitUntilRequestCount(2)

        await reader.completeRequest(at: 1, with: false)
        await secondRefresh.value
        await reader.failRequest(at: 0)
        await firstRefresh.value

        #expect(store.state == .loaded)
        #expect(!store.allowsStrangerMessages)
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

    @Test func strangerMessagePreferenceCancellationRestoresTheSavingState() async {
        let reader = V2StrangerMessagePreferenceReaderFake(value: true)
        let updater = V2StrangerMessagePreferenceUpdaterFake(error: CancellationError())
        let store = V2PrivacySettingsStore(reader: reader, updater: updater)

        await store.refresh()
        await store.setAllowsStrangerMessages(false)

        #expect(store.state == .loaded)
        #expect(store.allowsStrangerMessages)
        #expect(!store.isSaving)
        #expect(store.feedback == nil)
        #expect(await updater.requestedValues() == [false])
    }

    @Test func strangerMessagePreferenceIgnoresLateSuccessAfterCancellation() async {
        let reader = V2StrangerMessagePreferenceReaderFake(value: true)
        let updater = V2LateStrangerMessagePreferenceUpdater()
        let store = V2PrivacySettingsStore(reader: reader, updater: updater)

        await store.refresh()
        let update = Task { await store.setAllowsStrangerMessages(false) }
        await updater.waitUntilResponseIsPending()
        update.cancel()
        await updater.resumeAccepted()
        await update.value

        #expect(store.allowsStrangerMessages)
        #expect(!store.isSaving)
        #expect(store.feedback == nil)
    }

    @Test func userBlockResolvesAPublicHandleThenPersistsTheDurableCommand() async throws {
        let targetID = "00000000-0000-0000-0000-000000000e03"
        let expectedTargetID = try UserID(targetID).rawValue
        let resolver = V2UserBlockPublicIdentityResolverFake(values: ["blocked_user": targetID])
        let changer = V2UserBlockChangerFake(result: .queuedForRetry)
        let store = V2UserBlockSettingsStore(
            resolver: resolver,
            changer: changer,
            currentUserID: try .init("00000000-0000-0000-0000-000000000e02")
        )

        await store.changeBlock(handle: "  @BLOCKED_USER  ", action: .block)

        #expect(await resolver.requestedHandles() == ["@BLOCKED_USER"])
        #expect(await changer.requests() == [.init(targetUserID: expectedTargetID, action: .block)])
        #expect(store.feedback == "屏蔽请求已安全保存，连接恢复后会同步。")
        #expect(!store.isChanging)
    }

    @Test func userBlockRejectsSelfBeforeWritingACommand() async throws {
        let currentUserID = "00000000-0000-0000-0000-000000000e02"
        let resolver = V2UserBlockPublicIdentityResolverFake(values: ["self_user": currentUserID])
        let changer = V2UserBlockChangerFake(result: .accepted)
        let store = V2UserBlockSettingsStore(
            resolver: resolver,
            changer: changer,
            currentUserID: try .init(currentUserID)
        )

        await store.changeBlock(handle: "@self_user", action: .block)

        #expect(await changer.requests().isEmpty)
        #expect(store.feedback == "不能屏蔽自己。")
        #expect(!store.isChanging)
    }

    @Test func userBlockDoesNotExposeTheServerRejectionCode() async throws {
        let resolver = V2UserBlockPublicIdentityResolverFake(values: ["blocked_user": "00000000-0000-0000-0000-000000000e03"])
        let changer = V2UserBlockChangerFake(result: .rejected(code: "TARGET_POLICY"))
        let store = V2UserBlockSettingsStore(
            resolver: resolver,
            changer: changer,
            currentUserID: try .init("00000000-0000-0000-0000-000000000e02")
        )

        await store.changeBlock(handle: "@blocked_user", action: .unblock)

        #expect(store.feedback == "无法完成此用户设置。")
        #expect(!store.isChanging)
    }

    @Test func userBlockIgnoresLateSuccessAfterCancellation() async throws {
        let resolver = V2UserBlockPublicIdentityResolverFake(
            values: ["blocked_user": "00000000-0000-0000-0000-000000000e03"]
        )
        let changer = V2LateUserBlockChanger()
        let store = V2UserBlockSettingsStore(
            resolver: resolver,
            changer: changer,
            currentUserID: try .init("00000000-0000-0000-0000-000000000e02")
        )

        let change = Task { await store.changeBlock(handle: "@blocked_user", action: .block) }
        await changer.waitUntilResponseIsPending()
        change.cancel()
        await changer.resumeAccepted()
        await change.value

        #expect(!store.isChanging)
        #expect(store.feedback == nil)
    }

    @Test func visibleHybridGroupPollStopsForANonHybridRoomWithoutNetworkLoop() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let synchronizer = V2ActiveHybridGroupSynchronizerFake(outcomes: [.notHybridRoom])
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-standard",
            isGroupConversation: true,
            activeHybridGroupSynchronizer: synchronizer
        )

        await store.pollVisibleHybridGroupEvents()

        #expect(await synchronizer.subscriptionRequests() == ["room-standard"])
    }

    @Test func visibleHybridGroupUsesATLSWakeBeforeTheNextCursorPullAndUnsubscribesOnExit() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let synchronizer = V2SubscribedHybridGroupSynchronizerFake()
        let store = V2ConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-hybrid",
            isGroupConversation: true,
            activeHybridGroupSynchronizer: synchronizer
        )

        let task = Task { await store.pollVisibleHybridGroupEvents() }
        await synchronizer.waitForSynchronizationCount(1)
        await synchronizer.waitForWakeCount(1)
        await synchronizer.emitWake(.init(roomID: "room-hybrid", highWatermark: 8))
        await synchronizer.waitForSynchronizationCount(2)
        await synchronizer.waitForWakeCount(2)

        task.cancel()
        await synchronizer.emitWake(.init(roomID: "room-hybrid", highWatermark: 8))
        await task.value

        #expect(await synchronizer.subscribedRoomIDs() == ["room-hybrid"])
        #expect(await synchronizer.unsubscribedRoomIDs() == ["room-hybrid"])
    }

    @Test func messageSearchStorePublishesHitsAndPreservesTheNextPageCursor() async throws {
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000f01")
        let messageID: MessageID = try .init("00000000-0000-0000-0000-000000000f02")
        let senderID: UserID = try .init("00000000-0000-0000-0000-000000000f03")
        let hit = V2MessageSearchHit(
            messageID: messageID,
            roomID: roomID,
            roomSequence: 9,
            senderUserID: senderID,
            text: "你好，搜索结果",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let searcher = V2MessageSearchFake(result: .success(.init(hits: [hit], nextCursor: nil)))
        let store = V2ConversationSearchStore(searcher: searcher)
        store.query = "你好"

        await store.search()

        #expect(store.state == .loaded)
        #expect(store.hits == [hit])
        #expect(!store.canLoadMore)
        #expect(await searcher.requests().map(\.query) == ["你好"])
    }

    @Test func messageSearchStorePassesTheSelectedSenderFilter() async throws {
        let senderID: UserID = try .init("00000000-0000-0000-0000-000000000f04")
        let searcher = V2MessageSearchFake(result: .success(.init(hits: [], nextCursor: nil)))
        let store = V2ConversationSearchStore(searcher: searcher)
        store.query = "你好"
        store.filterToSender(senderID)

        await store.search()

        #expect(await searcher.requests().map(\.senderUserID) == [senderID])
    }

    @Test func typingStateExpiresAndAnOlderLeaseCannotClearANewerOne() throws {
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000f05")
        let peerID: UserID = try .init("00000000-0000-0000-0000-000000000f06")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let store = V2ConversationDetailStore(
            dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            sender: nil,
            userID: "current-user",
            roomID: roomID.rawValue
        )
        let firstExpiry = now.addingTimeInterval(3)
        let secondExpiry = now.addingTimeInterval(6)

        store.applyTypingState(.init(roomID: roomID, userID: peerID, isTyping: true, expiresAt: firstExpiry), now: now)
        store.applyTypingState(.init(roomID: roomID, userID: peerID, isTyping: true, expiresAt: secondExpiry), now: now)
        store.expireTypingState(for: peerID, expectedExpiry: firstExpiry)
        #expect(store.typingUserIDs == [peerID])

        store.expireTypingState(for: peerID, expectedExpiry: secondExpiry)
        #expect(store.typingUserIDs.isEmpty)
    }

    @Test func conversationListSeparatesArchivedItemsFromTheInbox() async {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let source = V2ConversationDataSourceFake(
            summaries: [
                .init(id: "inbox", title: "收件箱", preview: "消息", lastActivity: date, isOutgoing: false),
                .init(id: "archive", title: "归档", preview: "消息", lastActivity: date, isOutgoing: false, isArchived: true)
            ],
            messages: []
        )
        let store = V2ConversationListStore(dataSource: source, userID: "current-user")

        await store.refresh()
        #expect(store.visibleItems.map(\.id) == ["inbox"])
        store.isShowingArchived = true
        #expect(store.visibleItems.map(\.id) == ["archive"])
    }

    @Test func messageSearchStoreShowsIndexingUntilTheBackgroundBuildCompletes() async {
        let searcher = V2MessageSearchFake(result: .failure(.indexUnavailable(.building)))
        let store = V2ConversationSearchStore(searcher: searcher)
        store.query = "你好"

        await store.search()

        #expect(store.state == .indexing)
        #expect(store.hits.isEmpty)
    }

    @Test func currentConversationMessageSearchUsesTheRoomScope() async throws {
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000f11")
        let searcher = V2MessageSearchFake(result: .success(.init(hits: [], nextCursor: nil)))
        let detail = V2ConversationDetailStore(
            dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            messageSearcher: searcher,
            sender: nil,
            userID: "current-user",
            roomID: roomID.rawValue
        )
        let store = try #require(detail.messageSearchStore())
        store.query = "你好"

        await store.search()

        #expect(await searcher.requests().map(\.scope) == [.room(roomID)])
    }
}

private func testPresentation(for reference: V2MediaReference) throws -> V2MediaPresentation {
    try .init(
        mediaID: reference.mediaID,
        kind: .file,
        contentType: "application/octet-stream",
        byteCount: 0
    )
}

private actor V2ActiveHybridGroupSynchronizerFake: V2ActiveHybridGroupSynchronizing {
    private var outcomes: [V2ActiveHybridGroupSyncOutcome]
    private var roomIDs: [String] = []
    private var subscriptionRoomIDs: [String] = []

    init(outcomes: [V2ActiveHybridGroupSyncOutcome]) {
        self.outcomes = outcomes
    }

    func synchronizeOnePage(roomID: String) throws -> V2ActiveHybridGroupSyncOutcome {
        roomIDs.append(roomID)
        guard !outcomes.isEmpty else { return .notHybridRoom }
        return outcomes.removeFirst()
    }

    func subscribe(roomID: String) -> V2ActiveHybridGroupSubscriptionOutcome {
        subscriptionRoomIDs.append(roomID)
        return .notHybridRoom
    }
    func nextWake() async throws -> V2ActiveHybridGroupWake { throw CancellationError() }
    func unsubscribe(roomID _: String) {}

    func requestedRoomIDs() -> [String] { roomIDs }
    func subscriptionRequests() -> [String] { subscriptionRoomIDs }
}

private actor V2SubscribedHybridGroupSynchronizerFake: V2ActiveHybridGroupSynchronizing {
    private var synchronizationCount = 0
    private var wakeCount = 0
    private var synchronizationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var wakeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var wakeContinuation: CheckedContinuation<V2ActiveHybridGroupWake, Never>?
    private var subscribed: [String] = []
    private var unsubscribed: [String] = []

    func synchronizeOnePage(roomID _: String) -> V2ActiveHybridGroupSyncOutcome {
        synchronizationCount += 1
        resumeSynchronizationWaiters()
        return .synchronized(appliedEventCount: 0, hasMore: false)
    }

    func subscribe(roomID: String) -> V2ActiveHybridGroupSubscriptionOutcome {
        subscribed.append(roomID)
        return .subscribed(highWatermark: 0)
    }

    func nextWake() async throws -> V2ActiveHybridGroupWake {
        try Task.checkCancellation()
        wakeCount += 1
        resumeWakeWaiters()
        return await withCheckedContinuation { wakeContinuation = $0 }
    }

    func unsubscribe(roomID: String) { unsubscribed.append(roomID) }

    func waitForSynchronizationCount(_ expected: Int) async {
        guard synchronizationCount < expected else { return }
        await withCheckedContinuation { synchronizationWaiters.append((expected, $0)) }
    }

    func waitForWakeCount(_ expected: Int) async {
        guard wakeCount < expected else { return }
        await withCheckedContinuation { wakeWaiters.append((expected, $0)) }
    }

    func emitWake(_ wake: V2ActiveHybridGroupWake) {
        let continuation = wakeContinuation
        wakeContinuation = nil
        continuation?.resume(returning: wake)
    }

    func subscribedRoomIDs() -> [String] { subscribed }
    func unsubscribedRoomIDs() -> [String] { unsubscribed }

    private func resumeSynchronizationWaiters() {
        let ready = synchronizationWaiters.filter { $0.0 <= synchronizationCount }
        synchronizationWaiters.removeAll { $0.0 <= synchronizationCount }
        for (_, continuation) in ready { continuation.resume() }
    }

    private func resumeWakeWaiters() {
        let ready = wakeWaiters.filter { $0.0 <= wakeCount }
        wakeWaiters.removeAll { $0.0 <= wakeCount }
        for (_, continuation) in ready { continuation.resume() }
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

    func timeline(in _: String, for _: String) async throws -> [V2ConversationTimelineItem] {
        messages.map { .message($0, timelineSequence: $0.roomSequence) }
    }

    func messageRequestCount() -> Int { requestedMessageCount }
}

private actor V2MessageSearchFake: V2ConversationMessageSearching {
    private let result: Result<V2MessageSearchPage, V2MessageSearchError>
    private var receivedRequests: [V2MessageSearchRequest] = []

    init(result: Result<V2MessageSearchPage, V2MessageSearchError>) {
        self.result = result
    }

    func searchMessages(_ request: V2MessageSearchRequest) async throws -> V2MessageSearchPage {
        receivedRequests.append(request)
        return try result.get()
    }

    func requests() -> [V2MessageSearchRequest] { receivedRequests }
}

private actor V2SequencedConversationDataSource: V2ConversationDataSource {
    private var summaryRequestCount = 0
    private var summaryRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var summaryContinuations: [CheckedContinuation<[V2ConversationListItem], Never>?] = []
    private var messageRequestCount = 0
    private var messageRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var messageContinuations: [CheckedContinuation<Result<[V2ConversationMessageItem], V2SequencedConversationDataSourceFailure>, Never>?] = []

    func conversationSummaries(for _: String) async throws -> [V2ConversationListItem] {
        summaryRequestCount += 1
        let waiters = summaryRequestWaiters
        summaryRequestWaiters = []
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            summaryContinuations.append(continuation)
        }
    }

    func messages(in _: String, for _: String) async throws -> [V2ConversationMessageItem] {
        messageRequestCount += 1
        let waiters = messageRequestWaiters
        messageRequestWaiters = []
        waiters.forEach { $0.resume() }
        return try await withCheckedContinuation { continuation in
            messageContinuations.append(continuation)
        }.get()
    }

    func timeline(in _: String, for _: String) async throws -> [V2ConversationTimelineItem] {
        []
    }

    func waitUntilSummaryRequestCount(_ expectedCount: Int) async {
        while summaryRequestCount < expectedCount {
            await withCheckedContinuation { summaryRequestWaiters.append($0) }
        }
    }

    func completeSummaryRequest(at index: Int, with items: [V2ConversationListItem]) {
        guard summaryContinuations.indices.contains(index), let continuation = summaryContinuations[index] else {
            return
        }
        summaryContinuations[index] = nil
        continuation.resume(returning: items)
    }

    func waitUntilMessageRequestCount(_ expectedCount: Int) async {
        while messageRequestCount < expectedCount {
            await withCheckedContinuation { messageRequestWaiters.append($0) }
        }
    }

    func completeMessageRequest(at index: Int, with messages: [V2ConversationMessageItem]) {
        guard messageContinuations.indices.contains(index), let continuation = messageContinuations[index] else {
            return
        }
        messageContinuations[index] = nil
        continuation.resume(returning: .success(messages))
    }

    func failMessageRequest(at index: Int) {
        guard messageContinuations.indices.contains(index), let continuation = messageContinuations[index] else {
            return
        }
        messageContinuations[index] = nil
        continuation.resume(returning: .failure(.failed))
    }
}

private enum V2SequencedConversationDataSourceFailure: Error, Sendable {
    case failed
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

    func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], in roomID: String) async throws -> V2ConversationSendOutcome {
        messages.append(.init(text: text, media: media, roomID: roomID, mentions: mentions))
        return result
    }

    func sentMessages() -> [V2SentMessage] {
        messages
    }
}

private actor V2SuspendingConversationSender: V2ConversationSending {
    private var messages: [V2SentMessage] = []
    private var beganSending = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    func send(text: String, media: [V2MediaReference], in roomID: String) async throws -> V2ConversationSendOutcome {
        try await send(text: text, media: media, mentions: [], in: roomID)
    }

    func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], in roomID: String) async throws -> V2ConversationSendOutcome {
        messages.append(.init(text: text, media: media, roomID: roomID, mentions: mentions))
        beganSending = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { completion = $0 }
        return .accepted
    }

    func waitUntilSending() async {
        guard !beganSending else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func complete() {
        completion?.resume()
        completion = nil
    }

    func sentMessages() -> [V2SentMessage] { messages }
}

private struct V2SentMessage: Equatable, Sendable {
    let text: String
    let media: [V2MediaReference]
    let roomID: String
    let mentions: [V2MentionTarget]

    init(text: String, media: [V2MediaReference] = [], roomID: String, mentions: [V2MentionTarget] = []) {
        self.text = text
        self.media = media
        self.roomID = roomID
        self.mentions = mentions
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

private actor V2ConversationMediaCacheDiscardingFake: V2ConversationMediaDownloading, V2ConversationMediaCacheDiscarding {
    private var discarded: [V2MediaReference] = []

    func download(_: V2MediaReference) async throws -> V2DownloadedConversationMedia {
        throw V2ConversationMediaDownloadFailure.failed
    }

    func discard(_ media: V2MediaReference) {
        discarded.append(media)
    }

    func discardedReferences() -> [V2MediaReference] { discarded }
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

private actor V2SuspendingMessageWithdrawer: V2MessageWithdrawing {
    private let result: V2MessageWithdrawalOutcome
    private var requestsValue: [V2MessageWithdrawerFake.Request] = []
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    init(result: V2MessageWithdrawalOutcome) {
        self.result = result
    }

    func withdraw(messageID: String, in roomID: String, expectedMessageRevision: UInt64) async throws -> V2MessageWithdrawalOutcome {
        requestsValue.append(.init(messageID: messageID, roomID: roomID, expectedMessageRevision: expectedMessageRevision))
        requestWaiter?.resume()
        requestWaiter = nil
        await withCheckedContinuation { completion = $0 }
        return result
    }

    func waitUntilRequested() async {
        guard requestsValue.isEmpty else { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func complete() {
        completion?.resume()
        completion = nil
    }

    func requests() -> [V2MessageWithdrawerFake.Request] { requestsValue }
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

private actor V2SuspendingDirectConversationOpener: V2DirectConversationOpening {
    private let roomID: String
    private var count = 0
    private var openingWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    init(roomID: String) {
        self.roomID = roomID
    }

    func openConversation(with _: V2PublicIdentity) async throws -> String {
        count += 1
        openingWaiter?.resume()
        openingWaiter = nil
        await withCheckedContinuation { completion = $0 }
        return roomID
    }

    func waitUntilOpening() async {
        guard completion == nil else { return }
        await withCheckedContinuation { openingWaiter = $0 }
    }

    func complete() {
        completion?.resume()
        completion = nil
    }

    func openingCount() -> Int { count }
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

private actor V2SuspendingConversationPublicIdentityResolver: V2ConversationPublicIdentityResolving {
    private var beganResolving = false
    private var startWaiter: CheckedContinuation<Void, Never>?

    func resolve(handle _: String) async throws -> V2PublicIdentity {
        beganResolving = true
        startWaiter?.resume()
        startWaiter = nil
        try await Task.sleep(for: .seconds(60))
        return try .init(userID: .init("other-user"), handle: .init("other_user"), displayName: "Other")
    }

    func waitUntilResolving() async {
        guard !beganResolving else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
}

private actor V2CancellationIgnoringConversationPublicIdentityResolver: V2ConversationPublicIdentityResolving {
    private var beganResolving = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resolutionContinuation: CheckedContinuation<Void, Never>?

    func resolve(handle _: String) async throws -> V2PublicIdentity {
        beganResolving = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { resolutionContinuation = $0 }
        return try .init(userID: .init("other-user"), handle: .init("other_user"), displayName: "Other")
    }

    func waitUntilResolving() async {
        guard !beganResolving else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func completeResolution() {
        resolutionContinuation?.resume()
        resolutionContinuation = nil
    }
}

private actor V2GroupConversationCreatorFake: V2GroupConversationCreating {
    private let result: V2GroupConversationCreationOutcome
    private let restoredStatus: V2RestoredGroupConversationCreationStatus?
    private var requestsValue: [Request] = []
    private var cancelledOperationIDsValue: [String] = []
    init(result: V2GroupConversationCreationOutcome, restoredStatus: V2RestoredGroupConversationCreationStatus? = nil) {
        self.result = result
        self.restoredStatus = restoredStatus
    }
    func createConversation(title: String, initialMemberUserIDs: [String]) async throws -> V2GroupConversationCreationOutcome {
        requestsValue.append(.init(title: title, memberUserIDs: initialMemberUserIDs))
        return result
    }
    func cancelConversationCreation(operationID: String) async throws -> V2GroupConversationCancellationOutcome {
        cancelledOperationIDsValue.append(operationID)
        return .queuedForRetry
    }
    func restoredCreationStatus() async throws -> V2RestoredGroupConversationCreationStatus? { restoredStatus }
    func requests() -> [Request] { requestsValue }
    func cancelledOperationIDs() -> [String] { cancelledOperationIDsValue }
    struct Request: Equatable, Sendable { let title: String; let memberUserIDs: [String] }
}

private actor V2SuspendingGroupConversationCreator: V2GroupConversationCreating {
    private let result: V2GroupConversationCreationOutcome
    private var count = 0
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    init(result: V2GroupConversationCreationOutcome) {
        self.result = result
    }

    func createConversation(
        title _: String,
        initialMemberUserIDs _: [String]
    ) async throws -> V2GroupConversationCreationOutcome {
        count += 1
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { completion = $0 }
        return result
    }

    func cancelConversationCreation(operationID _: String) async throws -> V2GroupConversationCancellationOutcome { .queuedForRetry }

    func waitUntilCreating() async {
        guard count == 0 else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func complete() {
        completion?.resume()
        completion = nil
    }

    func creationCount() -> Int { count }
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

private actor V2SuspendingGroupMemberDirectory: V2GroupMemberDirectoryReading {
    private let page: V2GroupMemberPage
    private var cursors: [String?] = []
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    init(page: V2GroupMemberPage) {
        self.page = page
    }

    func members(in _: String, cursor: String?) async throws -> V2GroupMemberPage {
        cursors.append(cursor)
        requestWaiter?.resume()
        requestWaiter = nil
        await withCheckedContinuation { completion = $0 }
        return page
    }

    func waitUntilRequested() async {
        guard !cursors.isEmpty else {
            await withCheckedContinuation { requestWaiter = $0 }
            return
        }
    }

    func complete() {
        completion?.resume()
        completion = nil
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

private actor V2GroupMemberMuterFake: V2GroupMemberMuting {
    struct Request: Sendable {
        let roomID: String
        let targetUserID: String
        let muteUntil: Date
        let reasonCode: String
    }

    private let result: V2GroupModerationOutcome
    private var requestsValue: [Request] = []

    init(result: V2GroupModerationOutcome) { self.result = result }

    func muteMember(roomID: String, targetUserID: String, muteUntil: Date, reasonCode: V2ModerationReasonCode) async throws -> V2GroupModerationOutcome {
        requestsValue.append(.init(roomID: roomID, targetUserID: targetUserID, muteUntil: muteUntil, reasonCode: reasonCode.rawValue))
        return result
    }

    func requests() -> [Request] { requestsValue }
}

private actor V2ModeratedGroupMemberRemoverFake: V2ModeratedGroupMemberRemoving {
    struct Request: Equatable, Sendable {
        let roomID: String
        let targetUserID: String
        let reasonCode: String
    }

    private let result: V2GroupModerationOutcome
    private var requestsValue: [Request] = []

    init(result: V2GroupModerationOutcome) { self.result = result }

    func removeMemberByModerator(roomID: String, targetUserID: String, reasonCode: V2ModerationReasonCode) async throws -> V2GroupModerationOutcome {
        requestsValue.append(.init(roomID: roomID, targetUserID: targetUserID, reasonCode: reasonCode.rawValue))
        return result
    }

    func requests() -> [Request] { requestsValue }
}

private actor V2SuspendingModeratedGroupMemberRemover: V2ModeratedGroupMemberRemoving {
    private let result: V2GroupModerationOutcome
    private var didReceiveRequest = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    init(result: V2GroupModerationOutcome) {
        self.result = result
    }

    func removeMemberByModerator(
        roomID _: String,
        targetUserID _: String,
        reasonCode _: V2ModerationReasonCode
    ) async throws -> V2GroupModerationOutcome {
        didReceiveRequest = true
        requestWaiter?.resume()
        requestWaiter = nil
        await withCheckedContinuation { completion = $0 }
        return result
    }

    func waitUntilRequested() async {
        guard !didReceiveRequest else { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func complete() {
        completion?.resume()
        completion = nil
    }
}

private actor V2SuspendingGroupMembershipChanger: V2GroupMembershipChanging {
    struct Request: Equatable, Sendable {
        let roomID: String
        let targetUserID: String
        let action: V2RoomMembershipAction
        let expectedMembershipRevision: UInt64
    }

    private let result: V2GroupMembershipChangeOutcome
    private var requestsValue: [Request] = []
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    init(result: V2GroupMembershipChangeOutcome) {
        self.result = result
    }

    func changeMembership(roomID: String, targetUserID: String, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) async throws -> V2GroupMembershipChangeOutcome {
        requestsValue.append(.init(roomID: roomID, targetUserID: targetUserID, action: action, expectedMembershipRevision: expectedMembershipRevision))
        requestWaiter?.resume()
        requestWaiter = nil
        await withCheckedContinuation { completion = $0 }
        return result
    }

    func waitUntilRequested() async {
        guard requestsValue.isEmpty else { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func complete() {
        completion?.resume()
        completion = nil
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

private actor V2UserAddPreferenceReaderFake: V2UserAddPreferenceReading {
    private let value: Bool?
    init(value: Bool?) { self.value = value }
    func userAddPreference() async throws -> Bool? { value }
}

private actor V2SequencedStrangerMessagePreferenceReader: V2StrangerMessagePreferenceReading {
    private var requestCount = 0
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuations: [CheckedContinuation<Result<Bool?, V2SequencedStrangerMessagePreferenceReaderFailure>, Never>?] = []

    func strangerMessagePreference() async throws -> Bool? {
        requestCount += 1
        let waiters = requestWaiters
        requestWaiters = []
        waiters.forEach { $0.resume() }
        return try await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }.get()
    }

    func waitUntilRequestCount(_ expectedCount: Int) async {
        while requestCount < expectedCount {
            await withCheckedContinuation { requestWaiters.append($0) }
        }
    }

    func completeRequest(at index: Int, with value: Bool?) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else { return }
        continuations[index] = nil
        continuation.resume(returning: .success(value))
    }

    func failRequest(at index: Int) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else { return }
        continuations[index] = nil
        continuation.resume(returning: .failure(.failed))
    }
}

private enum V2SequencedStrangerMessagePreferenceReaderFailure: Error, Sendable {
    case failed
}

private actor V2StrangerMessagePreferenceUpdaterFake: V2StrangerMessagePreferenceUpdating {
    private let result: Result<V2StrangerMessagePreferenceUpdateOutcome, Error>
    private var values: [Bool] = []

    init(result: V2StrangerMessagePreferenceUpdateOutcome) {
        self.result = .success(result)
    }

    init(error: Error) {
        self.result = .failure(error)
    }

    func update(allowsStrangerMessages: Bool) async throws -> V2StrangerMessagePreferenceUpdateOutcome {
        values.append(allowsStrangerMessages)
        return try result.get()
    }

    func requestedValues() -> [Bool] {
        values
    }
}

private actor V2UserAddPreferenceUpdaterFake: V2UserAddPreferenceUpdating {
    private let result: V2UserAddPreferenceUpdateOutcome
    private var values: [Bool] = []
    init(result: V2UserAddPreferenceUpdateOutcome) { self.result = result }
    func update(allowsBeingAdded: Bool) async throws -> V2UserAddPreferenceUpdateOutcome { values.append(allowsBeingAdded); return result }
    func requestedValues() -> [Bool] { values }
}

private actor V2LiveActivityPreferenceReaderFake: V2LiveActivityPreferenceReading {
    private let value: V2LiveActivityPreferences

    init(value: V2LiveActivityPreferences) {
        self.value = value
    }

    func preferences() async throws -> V2LiveActivityPreferences {
        value
    }
}

private actor V2LiveActivityPreferenceUpdaterFake: V2LiveActivityPreferenceUpdating {
    struct Request: Equatable, Sendable {
        let online: Bool
        let typing: Bool
    }

    private let result: V2LiveActivityPreferenceUpdateOutcome
    private var values: [Request] = []

    init(result: V2LiveActivityPreferenceUpdateOutcome) {
        self.result = result
    }

    func update(
        allowsOnlinePresence: Bool,
        allowsTypingIndicators: Bool
    ) async throws -> V2LiveActivityPreferenceUpdateOutcome {
        values.append(.init(online: allowsOnlinePresence, typing: allowsTypingIndicators))
        return result
    }

    func requests() -> [Request] {
        values
    }
}

private actor V2LateLiveActivityPreferenceUpdater: V2LiveActivityPreferenceUpdating {
    private var responseWaiter: CheckedContinuation<V2LiveActivityPreferenceUpdateOutcome, Never>?
    private var responseReadyWaiter: CheckedContinuation<Void, Never>?

    func update(
        allowsOnlinePresence _: Bool,
        allowsTypingIndicators _: Bool
    ) async throws -> V2LiveActivityPreferenceUpdateOutcome {
        await withCheckedContinuation { continuation in
            responseWaiter = continuation
            responseReadyWaiter?.resume()
            responseReadyWaiter = nil
        }
    }

    func waitUntilResponseIsPending() async {
        guard responseWaiter == nil else { return }
        await withCheckedContinuation { responseReadyWaiter = $0 }
    }

    func resumeAccepted() {
        guard let responseWaiter else { return }
        self.responseWaiter = nil
        responseWaiter.resume(returning: .accepted)
    }
}

private actor V2LateStrangerMessagePreferenceUpdater: V2StrangerMessagePreferenceUpdating {
    private var responseWaiter: CheckedContinuation<V2StrangerMessagePreferenceUpdateOutcome, Never>?
    private var responseReadyWaiter: CheckedContinuation<Void, Never>?

    func update(allowsStrangerMessages _: Bool) async throws -> V2StrangerMessagePreferenceUpdateOutcome {
        await withCheckedContinuation { continuation in
            responseWaiter = continuation
            responseReadyWaiter?.resume()
            responseReadyWaiter = nil
        }
    }

    func waitUntilResponseIsPending() async {
        guard responseWaiter == nil else { return }
        await withCheckedContinuation { responseReadyWaiter = $0 }
    }

    func resumeAccepted() {
        guard let responseWaiter else { return }
        self.responseWaiter = nil
        responseWaiter.resume(returning: .accepted)
    }
}

private actor V2UserBlockPublicIdentityResolverFake: V2PublicIdentityResolving {
    private let values: [String: String]
    private var handles: [String] = []

    init(values: [String: String]) {
        self.values = values
    }

    func resolve(handle: String) async throws -> V2PublicIdentity {
        handles.append(handle)
        let canonical = try V2PublicHandle(handle).rawValue
        guard let userID = values[canonical] else { throw V2PublicIdentityDirectoryClientError.notFound }
        return try .init(userID: .init(userID), handle: .init(canonical), displayName: canonical)
    }

    func requestedHandles() -> [String] {
        handles
    }
}

private actor V2UserBlockChangerFake: V2UserBlockChanging {
    struct Request: Equatable, Sendable {
        let targetUserID: String
        let action: V2UserBlockAction
    }

    private let result: V2UserBlockChangeOutcome
    private var requestsValue: [Request] = []

    init(result: V2UserBlockChangeOutcome) {
        self.result = result
    }

    func changeBlock(targetUserID: String, action: V2UserBlockAction) async throws -> V2UserBlockChangeOutcome {
        requestsValue.append(.init(targetUserID: targetUserID, action: action))
        return result
    }

    func requests() -> [Request] {
        requestsValue
    }
}

private actor V2LateUserBlockChanger: V2UserBlockChanging {
    private var responseWaiter: CheckedContinuation<V2UserBlockChangeOutcome, Never>?
    private var responseReadyWaiter: CheckedContinuation<Void, Never>?

    func changeBlock(targetUserID _: String, action _: V2UserBlockAction) async throws -> V2UserBlockChangeOutcome {
        await withCheckedContinuation { continuation in
            responseWaiter = continuation
            responseReadyWaiter?.resume()
            responseReadyWaiter = nil
        }
    }

    func waitUntilResponseIsPending() async {
        guard responseWaiter == nil else { return }
        await withCheckedContinuation { responseReadyWaiter = $0 }
    }

    func resumeAccepted() {
        guard let responseWaiter else { return }
        self.responseWaiter = nil
        responseWaiter.resume(returning: .accepted)
    }
}
