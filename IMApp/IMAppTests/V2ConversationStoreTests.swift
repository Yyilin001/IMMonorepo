import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
import SwiftUI
import UIKit
@testable import IMApp

@MainActor
struct V2ConversationStoreTests {
    @Test func firstImageTimelineAndLaterSafeAreaLayoutKeepTheWholeLastRowVisible() async throws {
        let messages = try (0..<9).map { index in
            let media = V2MediaReference(mediaID: .init(uuid: UUID()))
            return V2ConversationMessageItem(id: UUID().uuidString, roomSequence: UInt64(index + 1), revision: 1,
                text: "Photo \(index)", media: [media],
                mediaPresentations: [try .init(mediaID: media.mediaID, kind: .image, contentType: "image/png", byteCount: 4)],
                createdAt: Date(timeIntervalSince1970: Double(index)), isOutgoing: true, isWithdrawn: false)
        }
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: messages),
            sender: nil, userID: UUID().uuidString, roomID: UUID().uuidString)
        await store.refresh()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack { V2ConversationDetailView(store: store) })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func collection(in view: UIView) -> UICollectionView? {
            if let result = view as? UICollectionView, result.numberOfSections > 0,
               result.numberOfItems(inSection: 0) == messages.count { return result }
            for child in view.subviews { if let result = collection(in: child) { return result } }
            return nil
        }
        func settledTail() async throws {
            var stableFrames = 0
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                window.layoutIfNeeded(); host.view.layoutIfNeeded()
                if let list = collection(in: host.view), list.bounds.height > 0,
                   let last = list.layoutAttributesForItem(at: .init(item: messages.count - 1, section: 0)) {
                    let edge = list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
                    let gap = max(0, edge - list.contentOffset.y)
                    let tailIsVisible = last.frame.maxY <= list.bounds.maxY - list.adjustedContentInset.bottom + 1
                    stableFrames = gap <= 1 && tailIsVisible ? stableFrames + 1 : 0
                    if stableFrames >= 5 { return }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Last image row must settle completely above the composer and safe area")
        }
        try await settledTail()
        host.additionalSafeAreaInsets.bottom = 80
        try await settledTail()
    }

    @Test func initialMessageSnapshotDoesNotWaitForImageAuthorizationOrDecode() async throws {
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2ConversationMessageItem(id: UUID().uuidString, revision: 1, text: "",
            media: [media], mediaPresentations: [try .init(mediaID: media.mediaID, kind: .image,
                contentType: "image/png", byteCount: 4)], createdAt: .now, isOutgoing: false, isWithdrawn: false)
        let reader = V2ConversationMediaDownloaderFake(result: .failure)
        let thumbnails = V2LocalMediaThumbnailCache(directories: []) { _, _ in
            Issue.record("Initial timeline must not decode images"); return nil
        }
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: [message]),
            sender: nil, userID: "current-user", roomID: "room-a", mediaDownloader: reader, mediaThumbnails: thumbnails)
        await store.refresh()
        #expect(store.messages == [message])
        #expect(store.state == .loaded)
        #expect(await reader.cacheLookups == 0)
        #expect(await reader.requests().isEmpty)
        #expect(store.initialImagePreviews.isEmpty)
        await thumbnails.close()
    }

    @Test func localTimelinePublishesWhileAncillaryMetadataIsStillPaused() async {
        let message = V2ConversationMessageItem(id: UUID().uuidString, revision: 1, text: "cached message",
            createdAt: .now, isOutgoing: false, isWithdrawn: false)
        let reader = V2ConversationDataSourceFake(summaries: [], messages: [message])
        await reader.pauseHistoryRead()
        let store = makeConversationDetailStore(dataSource: reader, sender: nil, userID: "user", roomID: "room")
        let refresh = Task { await store.refresh() }
        await reader.waitForHistoryRead()
        #expect(store.messages == [message])
        #expect(store.state == .loaded)
        await reader.resumeHistoryRead()
        await refresh.value
    }

    @Test func imageRowLoadsThumbnailAndDownloadsOriginalOnlyOnOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "thumbnail-route-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let target = try V2ClientMediaTransferTarget(downloadPlan: .init(mode: .httpGet,
            url: #require(URL(string: "https://media.invalid/fixture")), expiresAt: .distantFuture, expectedByteCount: 4,
            checksum: .init(value: "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a")))
        let files = try await makeResourceMediaTestDownloader(downloader: .init(
            targetResolver: V2MediaDownloadTargetResolverFake(target: target), byteTransfer: V2MediaByteTransferFake(downloadedData: Data([1,2,3,4]))), directory: root)
        let file = try await files.download(media)
        let pixel = V2SendableImage(image: UIImage())
        let thumbnails = V2LocalMediaThumbnailCache(directories: [root]) { _, size in
            #expect(size == 1280 || size == 2048); return pixel
        }
        let reader = V2ConversationMediaDownloaderFake(result: .success(file), cached: file)
        let message = V2ConversationMessageItem(id: UUID().uuidString, revision: 1, text: "",
            media: [media], mediaPresentations: [try .init(mediaID: media.mediaID, kind: .image,
                contentType: "image/png", byteCount: 4)], createdAt: .now, isOutgoing: false, isWithdrawn: false)
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: [message]),
            sender: nil, userID: "current-user", roomID: "room-a", mediaDownloader: reader, mediaThumbnails: thumbnails)
        await store.refresh()
        await store.loadImagePreview(media, from: message)
        #expect(await reader.previewRequests == 1)
        #expect(await reader.requests().isEmpty)
        #expect(store.initialImagePreviews[media.mediaID]?.image === pixel.image)
        #expect(store.mediaDownloadState(for: media) == .notDownloaded)
        #expect(await store.originalImage(media, from: message) === pixel.image)
        #expect(await reader.requests() == [media])
        await thumbnails.close(); try await files.close()
    }

    @Test func reopenedTimelinePublishesDecodedPreviewInItsFirstSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "first-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let target = try V2ClientMediaTransferTarget(downloadPlan: .init(mode: .httpGet,
            url: #require(URL(string: "https://media.invalid/fixture")), expiresAt: .distantFuture, expectedByteCount: 4,
            checksum: .init(value: "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a")))
        let files = try await makeResourceMediaTestDownloader(downloader: .init(
            targetResolver: V2MediaDownloadTargetResolverFake(target: target), byteTransfer: V2MediaByteTransferFake(downloadedData: Data([1,2,3,4]))), directory: root)
        let file = try await files.download(media)
        let pixel = V2SendableImage(image: UIImage())
        let decodeCount = FirstPreviewDecodeCount()
        let thumbnails = V2LocalMediaThumbnailCache(directories: [root]) { _, _ in
            await decodeCount.record(); return pixel
        }
        let lease = try await file.borrowFile()
        _ = await thumbnails.thumbnail(fileURL: lease.fileURL, maximumPixelSize: 1280)
        await lease.release()
        let reader = V2ConversationMediaDownloaderFake(result: .failure, cachedPreview: file)
        let message = V2ConversationMessageItem(id: UUID().uuidString, revision: 1, text: "", media: [media],
            mediaPresentations: [try .init(mediaID: media.mediaID, kind: .image, contentType: "image/png", byteCount: 4)],
            createdAt: .now, isOutgoing: false, isWithdrawn: false)
        let source = V2ConversationDataSourceFake(summaries: [], messages: [message])
        await source.pauseHistoryRead()
        let store = makeConversationDetailStore(dataSource: source, sender: nil, userID: UUID().uuidString,
            roomID: UUID().uuidString, mediaDownloader: reader, mediaThumbnails: thumbnails)
        let refresh = Task { await store.refresh() }
        await source.waitForHistoryRead()
        #expect(store.state == .loaded)
        #expect(store.messages == [message])
        #expect(store.imagePreviewStates[media.mediaID] == .downloaded(file))
        #expect(store.initialImagePreviews[media.mediaID]?.image === pixel.image)
        #expect(await decodeCount.value == 1)
        #expect(await reader.previewRequests == 0)
        #expect(await reader.requests().isEmpty)
        await source.resumeHistoryRead(); await refresh.value
        await thumbnails.close(); try await files.close()
    }

    @Test func cancelledOldImageRowCannotEraseANewerPreviewResult() async throws {
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2ConversationMessageItem(id: UUID().uuidString, revision: 1, text: "", media: [media],
            mediaPresentations: [try .init(mediaID: media.mediaID, kind: .image, contentType: "image/png", byteCount: 4)],
            createdAt: .now, isOutgoing: false, isWithdrawn: false)
        let reader = V2PreviewDemandGate(), thumbnails = V2LocalMediaThumbnailCache(directories: [])
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: [message]),
            sender: nil, userID: "user", roomID: "room", mediaDownloader: reader, mediaThumbnails: thumbnails)
        await store.refresh()
        let old = Task { await store.loadImagePreview(media, from: message) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await reader.calls == 0 { try #require(ContinuousClock.now < deadline); await Task.yield() }
        old.cancel()
        await store.loadImagePreview(media, from: message)
        #expect(store.imagePreviewStates[media.mediaID] == .failed)
        await reader.releaseFirst()
        await old.value
        #expect(store.imagePreviewStates[media.mediaID] == .failed)
        await thumbnails.close()
    }

    @Test(arguments: [false, true])
    func restoresCachedMessageMediaWithoutStartingADownload(hit: Bool) async throws {
        let reference = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2ConversationMessageItem(id: UUID().uuidString, revision: 1, text: "cached photo",
            media: [reference], mediaPresentations: [try testPresentation(for: reference)], createdAt: .now, isOutgoing: false, isWithdrawn: false)
        let file = V2DownloadedConversationMedia(mediaID: reference.mediaID, fileURL: URL(fileURLWithPath: "/tmp/opaque-cache-state-test"))
        let reader = V2ConversationMediaDownloaderFake(result: .failure, cached: hit ? file : nil)
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: [message]),
            sender: nil, userID: "current-user", roomID: "room-a", mediaDownloader: reader)
        await store.refresh()
        await store.restoreCachedMedia(reference, from: message)
        #expect(store.mediaDownloadState(for: reference) == (hit ? .downloaded(file) : .notDownloaded))
        #expect(await reader.requests().isEmpty)
        #expect(store.messageActionFeedback == nil)
    }

    @Test("a normalized photo enters the real chat draft without a provider or normalization file")
    func stagesNormalizedPhotoDirectlyIntoChatDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chat-normalized-photo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await V2OriginalResourceTestFixture(root: root)
        let data = UIGraphicsImageRenderer(size: .init(width: 8, height: 8)).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.blue.setFill(); context.fill(.init(x: 0, y: 0, width: 8, height: 8))
        }
        let photo = V2NormalizedPhoto(data: data, format: .jpeg)
        let room = RoomID(uuid: UUID())
        let page = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            sender: nil, userID: fixture.scope.accountID.rawValue, roomID: room.rawValue, attachmentStager: fixture.stager)
        await page.stageAttachment(photo: photo)
        let draft = try #require(page.attachments.first)
        #expect(page.attachments.count == 1 && draft.state == .staged)
        #expect(draft.attachment.displayName == "照片.jpg" && draft.attachment.contentType == "image/jpeg")
        #expect(try await fixture.stager.selectedAttachments(purpose: .messageDraft(room)).map(\.id) == [draft.id])
        let lease = try await page.borrowAttachment(id: draft.id)
        #expect(try Data(contentsOf: lease.fileURL) == data)
        await lease.release()
        #expect(try await fixture.resources.storageSnapshot().transferReservedBytes == 0)
        await page.removeAttachment(id: draft.id)
        #expect(page.attachments.isEmpty)
        let cleanup = try await fixture.resources.planCleanup()
        #expect(try await fixture.resources.commitCleanup(cleanup).deletedCount == 1)
        try await fixture.close()
    }

    @Test("a reconstructed chat restores only its own durable original selections without duplicates")
    func restoresOriginalDraftAfterColdAccountOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chat-original-restore-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "draft.txt"); try Data("saved attachment".utf8).write(to: source)
        let fixture = try await V2OriginalResourceTestFixture(root: root)
        let room = RoomID(uuid: UUID()), otherRoom = RoomID(uuid: UUID())
        let draft = try await fixture.stager.stageImportedFile(at: source, purpose: .messageDraft(room))
        _ = try await fixture.stager.stageImportedFile(at: source, purpose: .messageDraft(otherRoom))
        try await fixture.close()
        let restored = try await V2OriginalResourceTestFixture(root: root, scope: fixture.scope)
        let page = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            sender: nil, userID: fixture.scope.accountID.rawValue, roomID: room.rawValue, attachmentStager: restored.stager)
        async let first: Void = page.refresh()
        async let second: Void = page.refresh()
        _ = await (first, second)
        #expect(page.attachments.map(\.id) == [draft.id])
        #expect(page.attachments.first?.state == .staged)
        let lease = try await page.borrowAttachment(id: draft.id)
        #expect(try Data(contentsOf: lease.fileURL) == Data("saved attachment".utf8))
        await lease.release()
        await page.removeAttachment(id: draft.id)
        await page.refresh()
        #expect(page.attachments.isEmpty)
        #expect(try await restored.stager.selectedAttachments(purpose: .messageDraft(room)).isEmpty)
        #expect(try await restored.stager.selectedAttachments(purpose: .messageDraft(otherRoom)).count == 1)
        try await restored.close()
    }

    @Test func identicalTimelineRefreshDoesNotAdvanceRevisionAndMetadataRefreshSkipsTimelineRead() async {
        let message = V2ConversationMessageItem(id: "stable-message", roomSequence: 1, revision: 1,
            text: "hello", createdAt: .now, isOutgoing: false, isWithdrawn: false)
        let source = V2ConversationDataSourceFake(summaries: [], messages: [message])
        let store = makeConversationDetailStore(dataSource: source, sender: nil, userID: "current-user", roomID: "room-a")
        await store.refresh()
        let firstRevision = store.timelineRevision
        let readsAfterInitialLoad = await source.messageRequestCount()

        await store.refresh(scopes: .conversationTimeline)
        #expect(store.timelineRevision == firstRevision)
        #expect(await source.messageRequestCount() == readsAfterInitialLoad + 1)

        let readsBeforeMetadata = await source.messageRequestCount()
        await store.refresh(scopes: .conversationMetadata)
        #expect(await source.messageRequestCount() == readsBeforeMetadata)
        #expect(store.timelineRevision == firstRevision)
    }

    @Test func conversationSnapshotMetricRequiresAnActualAppliedListRead() async {
        let source = V2ConversationDataSourceFake(summaries: [
            .init(id: "metric-room", title: "Room", preview: "Message", lastActivity: .now, isOutgoing: false, kind: .unknown)
        ], messages: [])
        let store = makeConversationListStore(dataSource: source, userID: "current-user")
        let diagnostics = V2NetworkDiagnostics()
        await store.refresh()
        #expect(diagnostics.snapshot().projections.isEmpty)
        let stamp = V2ConversationCommitMeasurement(committedAt: .now, diagnostics: diagnostics)
        await V2ProjectionVisibilityScope.$conversationCommit.withValue(stamp) { await store.refresh() }
        #expect(store.items.map(\.id) == ["metric-room"])
        #expect(diagnostics.snapshot().projections.count == 1)
        #expect(diagnostics.snapshot().projections.first?.phase == .didCommitToConversationSnapshot)
        await V2ProjectionVisibilityScope.$conversationCommit.withValue(stamp) { await store.refresh() }
        #expect(diagnostics.snapshot().projections.count == 1)
    }

    @Test func conversationRefreshFailureKeepsLoadedContent() async {
        let source = V2ConversationDataSourceFake(summaries: [
            .init(id: "retained-room", title: "Room", preview: "Message", lastActivity: .now, isOutgoing: false, kind: .unknown)
        ], messages: [])
        let store = makeConversationListStore(dataSource: source, userID: "current-user")
        await store.refresh()
        let original = store.items
        await source.failNextSummaryRead()
        await store.refresh()
        #expect(store.state == .loaded)
        #expect(store.items == original)
        #expect(store.conversationRefreshFeedback != nil)
    }

    @Test func privacyRefreshFailureKeepsLoadedForm() async {
        let reader = V2SequencedStrangerMessagePreferenceReader()
        let store = V2PrivacySettingsStore(reader: reader, updater: V2StrangerMessagePreferenceUpdaterFake(result: .accepted))
        let first = Task { await store.refresh() }
        await reader.waitUntilRequestCount(1)
        await reader.completeRequest(at: 0, with: false)
        await first.value
        let refresh = Task { await store.refresh() }
        await reader.waitUntilRequestCount(2)
        #expect(store.state == .loaded)
        await reader.failRequest(at: 1)
        await refresh.value
        #expect(store.state == .loaded)
        #expect(!store.allowsStrangerMessages)
        #expect(store.feedback != nil)
    }

    @Test func conversationListShowsAnEmptyDirectRoomWithItsAuthorizedIdentity() throws {
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000e02")
        let identity = try V2PublicIdentity(
            userID: .init("00000000-0000-0000-0000-000000000e03"),
            handle: .init("empty_direct"),
            displayName: "尚未聊天的用户",
            accountKind: .regular
        )
        let updatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let items = V2GRDBConversationDataSource.mergingEmptyProjectionItems(
            messageItems: [],
            profiles: [],
            directIdentities: [.init(roomID: roomID, publicIdentity: identity, updatedAt: updatedAt.addingTimeInterval(3600), roomCreatedAt: updatedAt)]
        )

        #expect(items == [
            .init(id: roomID.rawValue, title: "尚未聊天的用户", preview: "暂无消息", lastActivity: updatedAt, isOutgoing: false, kind: .direct(accountKind: .regular), presentationKey: .init(userID: identity.userID, context: .directConversation))
        ])
    }

    @Test func emptyConversationKeepsItsDurablePinnedArchiveAndMuteState() throws {
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000e12")
        let identity = try V2PublicIdentity(
            userID: .init("00000000-0000-0000-0000-000000000e13"),
            handle: .init("empty_state"),
            displayName: "空会话",
            accountKind: .regular
        )
        let updatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let muteUntil = updatedAt.addingTimeInterval(3_600)
        let state = V2ClientConversationState(
            roomID: roomID,
            isPinned: true,
            isArchived: true,
            muteUntil: muteUntil,
            updatedAt: updatedAt,
            revision: .init(rawValue: 1)!
        )

        let items = V2GRDBConversationDataSource.mergingEmptyProjectionItems(
            messageItems: [],
            profiles: [],
            directIdentities: [.init(roomID: roomID, publicIdentity: identity, updatedAt: updatedAt.addingTimeInterval(3600), roomCreatedAt: updatedAt)],
            conversationStates: [roomID: state]
        )

        #expect(items == [
            .init(id: roomID.rawValue, title: "空会话", preview: "暂无消息", lastActivity: updatedAt, isOutgoing: false, kind: .direct(accountKind: .regular), isPinned: true, isArchived: true, muteUntil: muteUntil, presentationKey: .init(userID: identity.userID, context: .directConversation))
        ])
    }

    @Test("message authors use the known room kind and peer, never a row's outgoing flag", arguments: [V2ConversationKind.group, .direct(accountKind: .regular), .unknown])
    func authorContextFollowsConversation(kind: V2ConversationKind) {
        let actor = UserID(uuid: UUID()), peer = UserID(uuid: UUID()), stranger = UserID(uuid: UUID())
        let room = RoomID(uuid: UUID())
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let store = V2ConversationDetailStore(
            environment: .init(userID: actor.rawValue, projections: .init(dataSource: source)),
            context: .init(roomID: room.rawValue, kind: kind, presentationKey: .init(userID: peer, context: .directConversation)))
        for user in [actor, peer, stranger] {
            for outgoing in [false, true] {
                let message = V2ConversationMessageItem(id: "author-context", revision: 1, text: "", createdAt: .now,
                    isOutgoing: outgoing, isWithdrawn: false, senderUserID: user)
                let expected: V2ProfileViewLookupKey?
                switch kind {
                case .group: expected = .init(userID: user, context: .room(room))
                case .direct:
                    if user == actor || user == peer { expected = .init(userID: user, context: .room(room)) }
                    else { expected = nil }
                case .unknown: expected = nil
                }
                #expect(store.authorPresentationKey(for: message) == expected)
            }
        }
        if case .direct = kind {
            #expect(store.presentationKey == .init(userID: peer, context: .directConversation))
        } else { #expect(store.presentationKey == nil) }
        if case .unknown = kind { #expect(store.authorPresentationContext == nil) }
    }

    @Test("missing or mismatched private identity cannot select a display context")
    func directAuthorRequiresPeerIdentity() {
        let actor = UserID(uuid: UUID()), peer = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let invalidKeys: [V2ProfileViewLookupKey?] = [nil, .init(userID: actor, context: .directConversation),
            .init(userID: peer, context: .relationship), .init(userID: peer, context: .room(room))]
        for key in invalidKeys {
            let store = V2ConversationDetailStore(
                environment: .init(userID: actor.rawValue, projections: .init(dataSource: source)),
                context: .init(roomID: room.rawValue, kind: .direct(accountKind: .regular), presentationKey: key))
            #expect(store.presentationKey == nil)
            #expect(store.authorPresentationContext == nil)
        }
    }

    @Test func detailStoreExposesGroupControlsOnlyForKnownGroupRooms() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source = V2ConversationDataSourceFake(
            summaries: [
                .init(id: "room-direct", title: "私聊", preview: "你好", lastActivity: date, isOutgoing: false, kind: .direct(accountKind: .regular)),
                .init(id: "room-group", title: "项目群", preview: "大家好", lastActivity: date, isOutgoing: false, kind: .group)
            ],
            messages: []
        )
        let store = makeConversationListStore(dataSource: source, userID: "current-user")
        await store.refresh()

        #expect(!store.detailStore(for: "room-direct").isGroupConversation)
        #expect(store.detailStore(for: "room-group").isGroupConversation)
    }

    @Test func listRefreshUsesOnlyTheConversationDataSource() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source = V2ConversationDataSourceFake(
            summaries: [
                .init(id: "room-a", title: "会话 room-a", preview: "你好", lastActivity: date, isOutgoing: false, kind: .unknown)
            ],
            messages: []
        )
        let store = makeConversationListStore(dataSource: source, userID: "current-user")

        await store.refresh()

        #expect(store.state == .loaded)
        #expect(store.items.map(\.id) == ["room-a"])
        #expect(store.items.first?.preview == "你好")
    }

    @Test func listRefreshIgnoresAResponseSupersededByANewerRefresh() async {
        let source = V2SequencedConversationDataSource()
        let store = makeConversationListStore(dataSource: source, userID: "current-user")
        let staleItem = V2ConversationListItem(id: "room-stale", title: "旧会话", preview: "旧消息", lastActivity: .now, isOutgoing: false, kind: .unknown)
        let currentItem = V2ConversationListItem(id: "room-current", title: "新会话", preview: "新消息", lastActivity: .now, isOutgoing: false, kind: .unknown)

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
        let store = makeConversationDetailStore(dataSource: source, sender: nil, userID: "current-user", roomID: "room-a")
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
        let store = makeConversationDetailStore(dataSource: source, sender: nil, userID: "current-user", roomID: "room-a")
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

    @Test func longConversationUsesABoundedSlidingWindowAndCanReturnToLatest() async {
        let history = (1 ... 1_000).map { sequence in
            V2ConversationMessageItem(
                id: String(format: "message-%04d", sequence),
                roomSequence: UInt64(sequence),
                revision: 1,
                text: "message \(sequence)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
                isOutgoing: false,
                isWithdrawn: false
            )
        }
        let source = V2ConversationDataSourceFake(summaries: [], messages: history)
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-a"
        )

        await store.refresh()
        #expect(store.messages.map(\.roomSequence) == Array(921 ... 1_000).map(UInt64.init))

        for _ in 0..<10 { await store.loadOlderTimeline() }
        #expect(store.messages.count == 800)
        #expect(store.messages.first?.roomSequence == 121)
        #expect(store.messages.last?.roomSequence == 920)
        #expect(store.isBrowsingHistoricalTimeline)

        await store.returnToLatestTimeline()
        #expect(store.messages.count == 800)
        #expect(store.messages.first?.roomSequence == 201)
        #expect(store.messages.last?.roomSequence == 1_000)
        #expect(!store.isBrowsingHistoricalTimeline)
    }

    @Test("deep search jumps use one window read and can move to newer history")
    func directTimelineLocation() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: Self.locationHistory())
        let store = makeConversationDetailStore(dataSource: source, sender: nil, userID: "current-user", roomID: "room-a")
        await store.refresh()
        await store.loadTimeline(containing: "location-5")
        #expect(store.messages.first?.roomSequence == 1 && store.messages.last?.roomSequence == 44)
        #expect(await source.messageRequestCount() == 2)
        #expect(store.isBrowsingHistoricalTimeline && !store.canLoadOlderTimeline)
        await store.loadTimeline(containing: "location-4500")
        #expect(store.messages.first?.roomSequence == 4460 && store.messages.last?.roomSequence == 4539)
        #expect(store.timeline.count == 80 && store.canLoadOlderTimeline)
        #expect(await source.messageRequestCount() == 3)
        await store.returnToLatestTimeline()
        #expect(store.messages.last?.roomSequence == 5000 && !store.isBrowsingHistoricalTimeline)
    }

    @Test("a later navigation owns the window even when the old read ignores cancellation")
    func supersededTimelineLocation() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: Self.locationHistory())
        let gate = V2ListWindowReadGate()
        let store = makeConversationDetailStore(dataSource: V2GatedTimelineLocations(source: source, gate: gate), sender: nil, userID: "current-user", roomID: "room-a")
        await store.refresh()
        await gate.arm()
        let old = Task { await store.loadTimeline(containing: "location-5") }
        await gate.waitForRead()
        await store.loadTimeline(containing: "location-4500")
        let current = store.timeline
        await gate.release()
        await old.value
        #expect(store.timeline == current && store.messages.contains { $0.id == "location-4500" })
        await store.refresh()
        #expect(store.timeline == current)
    }

    @Test("refresh during location is deferred, and cancellation releases the location owner")
    func refreshDuringTimelineLocation() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: Self.locationHistory())
        let gate = V2ListWindowReadGate()
        let store = makeConversationDetailStore(dataSource: V2GatedTimelineLocations(source: source, gate: gate), sender: nil, userID: "current-user", roomID: "room-a")
        await store.refresh()
        await gate.arm()
        let locating = Task { await store.loadTimeline(containing: "location-500") }
        await gate.waitForRead()
        await store.refresh()
        #expect(await source.messageRequestCount() == 2)
        await gate.release()
        await locating.value
        #expect(await source.messageRequestCount() == 3)
        #expect(store.messages.first?.roomSequence == 460 && store.messages.last?.roomSequence == 539)
        let current = store.timeline
        await gate.arm()
        let cancelled = Task { await store.loadTimeline(containing: "location-5") }
        await gate.waitForRead()
        cancelled.cancel()
        await gate.release()
        await cancelled.value
        #expect(store.timeline == current && store.messageActionFeedback == nil)
        await store.loadTimeline(containing: "location-4500")
        #expect(store.messages.first?.roomSequence == 4460)
    }

    @Test("missing and withdrawn search results retain the current window with explicit feedback")
    func unavailableTimelineLocation() async {
        let history = Self.locationHistory()
        let source = V2ConversationDataSourceFake(summaries: [], messages: history)
        let store = makeConversationDetailStore(dataSource: source, sender: nil, userID: "current-user", roomID: "room-a")
        await store.refresh()
        let current = store.timeline
        await store.loadTimeline(containing: "missing")
        #expect(store.timeline == current && store.messageActionFeedback != nil)
        let withdrawn = V2ConversationMessageItem(id: "withdrawn", roomSequence: 1, revision: 2, text: "", createdAt: .now, isOutgoing: false, isWithdrawn: true)
        let other = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: [withdrawn]), sender: nil, userID: "current-user", roomID: "room-a")
        await other.loadTimeline(containing: "withdrawn")
        #expect(other.state == .failed && other.messageActionFeedback != nil)
    }

    @Test("production SQLite and App rendering directly locate mixed history beyond 800 items")
    func productionTimelineLocation() async throws {
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let directory = FileManager.default.temporaryDirectory.appending(path: "app-timeline-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = try await V2LocalStoreBootstrapper(bindingStore: V2RuntimeInstallationBindingStoreFake()).open(databaseURL: directory.appending(path: "local.sqlite"), userID: user)
        func messageID(_ n: Int) -> String { String(format: "00000000-0000-0000-0003-%012d", n) }
        let records: [V2ClientSyncRecord] = try (1...1_000).map { n in
            let activity = n.isMultiple(of: 5)
            var payload: [String: Any] = ["event_type": activity ? "direct_message_restricted" : "message.accepted", "room_id": room.rawValue, "timeline_sequence": n, "server_created_at_ms": 1_750_000_000_000 + n]
            if !activity {
                payload["message_id"] = messageID(n); payload["room_sequence"] = n; payload["message_revision"] = 1
                payload["sender_user_id"] = user.rawValue; payload["text"] = "message \(n)"
            }
            return try .init(sequence: UInt64(n), sourceEventID: .init(String(format: "00000000-0000-0000-0004-%012d", n)), projectionKind: activity ? "timeline_activity" : "message", payload: JSONSerialization.data(withJSONObject: payload))
        }
        let activities = try records.filter { $0.projectionKind == "timeline_activity" }.enumerated().map { index, record in
            try V2ClientSyncRecord(sequence: UInt64(index + 1), sourceEventID: record.sourceEventID,
                projectionKind: record.projectionKind, payload: record.payload)
        }
        _ = try await local.apply(.init(generation: 1, records: activities, nextSyncToken: .init("location-token"),
            receipt: .init("location-receipt"), hasMore: false, capabilityProfile: "base"))
        let messages = try records.filter { $0.projectionKind == "message" }.map { record in
            try V2ClientGroupEvent(sourceEventID: record.sourceEventID, roomSequence: record.sequence,
                projectionKind: record.projectionKind, payload: record.payload)
        }
        _ = try await local.applyGroupEventPage(.init(roomID: room, events: messages, nextRoomSequence: 1_000, hasMore: false))
        let store = makeConversationDetailStore(dataSource: V2GRDBConversationDataSource(localStore: local, requestLatestVisible: { _ in }), sender: nil, userID: user.rawValue, roomID: room.rawValue)
        await store.refresh()
        await store.loadTimeline(containing: messageID(1))
        #expect(store.timeline.map(\.timelineSequence) == (1...40).map(UInt64.init))
        #expect(store.messages.contains { $0.id == messageID(1) })
        await store.loadTimeline(containing: messageID(501))
        #expect(store.timeline.map(\.timelineSequence) == (461...540).map(UInt64.init))
        let historical = store.timeline
        await store.refresh()
        #expect(store.timeline == historical)
        await store.loadOlderTimeline()
        #expect(store.timeline.count == 160 && store.timeline.first?.timelineSequence == 381)
        await store.returnToLatestTimeline()
        #expect(store.timeline.last?.timelineSequence == 1000 && !store.isBrowsingHistoricalTimeline)
        try await local.close()
    }

    @Test("the actual detail ScrollView moves to the loaded search target")
    func actualTimelineSearchScroll() async throws {
        await V2UITestWindowOwnership.acquire()
        defer { V2UITestWindowOwnership.release() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let source = V2ConversationDataSourceFake(summaries: [], messages: Self.locationHistory())
        let store = makeConversationDetailStore(dataSource: source, sender: nil, userID: "current-user", roomID: "room-a")
        await store.refresh()
        let host = UIHostingController(rootView: NavigationStack { V2ConversationDetailView(store: store, initiallyFocusedMessageID: "location-4500") })
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func timelineScroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, !(scroll is UITextView), scroll.contentSize.height > 2000 { return scroll }
            for child in view.subviews { if let scroll = timelineScroll(in: child) { return scroll } }
            return nil
        }
        var moved = false
        for _ in 0..<250 {
            host.view.layoutIfNeeded()
            if store.messages.first?.roomSequence == 4460, let scroll = timelineScroll(in: host.view) {
                let visibleCenter = (scroll.contentOffset.y + scroll.bounds.height / 2) / scroll.contentSize.height
                if scroll.contentOffset.y > 1000 && (0.35...0.65).contains(visibleCenter) { moved = true; break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(moved, "The loaded middle target must move the real ScrollView away from its initial top position")
    }

    private static func locationHistory() -> [V2ConversationMessageItem] {
        (1...5_000).map { V2ConversationMessageItem(id: "location-\($0)", roomSequence: UInt64($0), revision: 1, text: "history", createdAt: .distantPast, isOutgoing: false, isWithdrawn: false) }
    }

    @Test func detailRefreshesItsLocalProjectionAfterASynchronizedUpdate() async {
        let source = V2SequencedConversationDataSource()
        let notifier = V2ProjectionChangeNotifier()
        let store = makeConversationDetailStore(
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

        func waitForMessages(_ expected: [V2ConversationMessageItem]) async {
            for _ in 0..<1_000 {
                if store.messages == expected { return }
                await Task.yield()
            }
            #expect(store.messages == expected)
        }
        let observer = Task { await store.observeProjectionChanges() }
        await source.waitUntilMessageRequestCount(1)
        await source.completeMessageRequest(at: 0, with: [initialMessage])
        await waitForMessages([initialMessage])
        await notifier.publish()
        await source.waitUntilMessageRequestCount(2)
        await source.completeMessageRequest(at: 1, with: [initialMessage, synchronizedMessage])
        await waitForMessages([initialMessage, synchronizedMessage])
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
        let store = makeConversationDetailStore(
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-a",
            mediaDownloader: downloader
        )
        await store.refresh()

        await store.downloadMedia(reference, from: message)

        #expect(await downloader.requests() == [reference])
        #expect(await downloader.lastMessageLocation == (try V2MediaMessageLocation(roomID: .init("room-a"), messageID: .init(message.id))))
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
        let store = makeConversationDetailStore(
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
        let store = makeConversationDetailStore(
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
        let store = makeConversationDetailStore(
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
        let store = makeConversationDetailStore(
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
        let store = makeConversationDetailStore(
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
        let store = makeConversationDetailStore(
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
        let store = makeConversationDetailStore(
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

    @Test func attachmentOnlyMessageFreezesIntentAndTransfersFileOwnership() async throws {
        let staged = V2StagedConversationAttachment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
            displayName: "diagram.png",
            contentType: "image/png",
            byteCount: 42
        )
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2ConversationSenderFake(result: .queuedForRetry)
        let stager = V2ConversationAttachmentStagerFake(result: .success(staged))
        let uploader = V2ConversationResourceSenderFake(result: .success(()))
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-a",
            attachmentStager: stager,
            resourceSender: uploader
        )

        await store.stageAttachment(from: URL(fileURLWithPath: "/tmp/imported-diagram.png"))
        await store.sendDraft()

        #expect(await uploader.uploadedAttachments() == [staged])
        #expect(await sender.sentMessages().isEmpty)
        #expect(await uploader.frozenRooms() == [try RoomID("room-a")])
        #expect(await stager.discardedAttachments().isEmpty)
        #expect(store.attachments.isEmpty)
        #expect(store.sendFeedback == nil)
    }

    @Test(arguments: [false, true])
    func failedResourceIntentRetainsTheDraftAndFiles(senderUnavailable: Bool) async {
        let staged = V2StagedConversationAttachment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000611")!,
            displayName: "document.pdf",
            contentType: "application/pdf",
            byteCount: 42
        )
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2ConversationSenderFake(result: .accepted)
        let stager = V2ConversationAttachmentStagerFake(result: .success(staged))
        let uploader = V2ConversationResourceSenderFake(result: .failure(V2AttachmentUploadFailure.failed))
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-a",
            attachmentStager: stager,
            resourceSender: senderUnavailable ? nil : uploader
        )
        store.draft = "附件说明"

        await store.stageAttachment(from: URL(fileURLWithPath: "/tmp/imported-document.pdf"))
        await store.sendDraft()

        #expect(await sender.sentMessages().isEmpty)
        #expect(store.draft == "附件说明")
        #expect(store.attachments.count == 1)
        #expect(store.attachments.first?.state == .staged)
        #expect(store.sendFeedback == (senderUnavailable ? "附件发送暂不可用。" : "无法保存待发送消息。"))
        #expect(await uploader.uploadedAttachments() == (senderUnavailable ? [] : [staged]))
        #expect(await stager.discardedAttachments().isEmpty)
    }

    @Test func invalidMentionDoesNotUploadOrScanStagedAttachments() async throws {
        let staged = V2StagedConversationAttachment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000612")!,
            displayName: "document.pdf",
            contentType: "application/pdf",
            byteCount: 42
        )
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let sender = V2ConversationSenderFake(result: .accepted)
        let stager = V2ConversationAttachmentStagerFake(result: .success(staged))
        let uploader = V2ConversationResourceSenderFake(result: .success(()))
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-group",
            kind: .group,
            attachmentStager: stager,
            resourceSender: uploader
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-group",
            kind: .group,
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-group",
            kind: .group
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: sender,
            userID: "current-user",
            roomID: "room-group",
            kind: .group,
            publicIdentityResolver: resolver
        )
        store.draft = "请关注"
        store.mentionHandlesText = "@member_a, @member_a"

        await store.sendDraft()

        #expect(await sender.sentMessages().isEmpty)
        #expect(store.draft == "请关注")
        #expect(store.sendFeedback == "提及对象不能重复。")
    }

    @Test func attachmentStagerImportsABorrowableOriginalAndCleanupNeverDeletesTheCallerSource() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "original-copy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "imported-note.txt")
        try Data("private attachment bytes".utf8).write(to: source)
        let fixture = try await V2OriginalResourceTestFixture(root: root)
        let staged = try await fixture.stager.stageImportedFile(at: source, purpose: .personalAvatar)
        let lease = try await fixture.stager.borrow(.selection(staged.localAssetID))
        let file = lease.fileURL
        #expect(file != source && file.deletingLastPathComponent().lastPathComponent == "files")
        #expect(try Data(contentsOf: file) == Data(contentsOf: source))
        #expect(staged.displayName == "imported-note.txt")
        #expect(staged.byteCount == Int64("private attachment bytes".utf8.count))
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try fixture.scope.resourceFilesDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        await fixture.stager.discard(staged)
        #expect(try await fixture.resources.planCleanup().fileIDs.isEmpty)
        await lease.release()
        let plan = try await fixture.resources.planCleanup()
        #expect(try await fixture.resources.commitCleanup(plan).deletedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        try await fixture.close()
    }

    @Test func resourceMaintenanceNeverDeletesUnownedImports() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "original-unowned-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let callerFile = root.appending(path: "keep.txt"), unrelated = root.appending(path: "not-a-managed-partial")
        try Data("keep".utf8).write(to: callerFile); try Data("external".utf8).write(to: unrelated)
        let fixture = try await V2OriginalResourceTestFixture(root: root)
        try await fixture.resources.maintainCache()
        #expect(FileManager.default.fileExists(atPath: callerFile.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        try await fixture.close()
    }

    @Test func originalAdmissionUsesTheSharedPhysicalBudgetAndNeverEvictsAnActiveDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "original-budget-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oversized = root.appending(path: "oversized.bin"), first = root.appending(path: "first.bin"), second = root.appending(path: "second.bin")
        try Data(repeating: 1, count: 9).write(to: oversized)
        try Data(repeating: 2, count: 6).write(to: first); try Data(repeating: 3, count: 6).write(to: second)
        let facts = try first.resourceValues(forKeys: [.totalFileAllocatedSizeKey,.fileAllocatedSizeKey])
        let allocation = Int64(try #require(facts.totalFileAllocatedSize ?? facts.fileAllocatedSize))
        let fixture = try await V2OriginalResourceTestFixture(root: root, policy: .init(maximumFileBytes: 8, maximumFileCount: 2), byteBudget: max(allocation,6) + 5)
        await #expect(throws: V2ConversationAttachmentStagingError.fileTooLarge) { try await fixture.stager.stageImportedFile(at: oversized, purpose: .personalAvatar) }
        let staged = try await fixture.stager.stageImportedFile(at: first, purpose: .personalAvatar)
        await #expect(throws: V2ConversationAttachmentStagingError.stagingQuotaExceeded) { try await fixture.stager.stageImportedFile(at: second, purpose: .personalAvatar) }
        #expect(try await fixture.read(.selection(staged.localAssetID)) == Data(repeating: 2, count: 6))
        #expect(try await fixture.resources.storageSnapshot().files.count == 1)
        try await fixture.close()
    }

    @Test func foregroundMediaDownloaderUsesFreshAuthorizedTransferAndOpaqueCacheFilename() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("v2-media-cache-" + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        // Media IDs are deliberately URL-path-safe. The cache name must still
        // be opaque rather than exposing even a valid identifier.
        let reference = V2MediaReference(mediaID: try .init("media-identifier-must-not-be-a-path"))
        let target = try V2ClientMediaTransferTarget(downloadPlan: .init(mode: .httpGet,
            url: #require(URL(string: "https://media.invalid/object")), expiresAt: .distantFuture,
            expectedByteCount: 4, checksum: .init(value: "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a")))
        let resolver = V2MediaDownloadTargetResolverFake(target: target)
        let transfer = V2MediaByteTransferFake(downloadedData: Data([1, 2, 3, 4]))
        let client = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: transfer)
        let downloader = try await makeResourceMediaTestDownloader(
            downloader: client,
            directory: root
        )

        let downloaded = try await downloader.download(reference)

        #expect(await resolver.requests() == [reference.mediaID])
        let stableTemporary = try #require(await transfer.downloadDestinations().first)
        #expect(stableTemporary.deletingLastPathComponent().lastPathComponent == "transfers")
        #expect(UUID(uuidString: stableTemporary.lastPathComponent) != nil)
        #expect(!stableTemporary.lastPathComponent.contains(reference.mediaID.rawValue))
        #expect(try Data(contentsOf: downloaded.fileURL) == Data([1, 2, 3, 4]))
        #expect(!downloaded.fileURL.lastPathComponent.contains(reference.mediaID.rawValue))
        #expect(downloaded.fileURL.deletingLastPathComponent().lastPathComponent == "files")

        try Data([9, 9, 9, 9]).write(to: downloaded.fileURL)
        let replaced = try await downloader.download(reference)
        #expect(replaced.fileURL != downloaded.fileURL)
        #expect(!fileManager.fileExists(atPath: downloaded.fileURL.path))
        #expect(try Data(contentsOf: replaced.fileURL) == Data([1, 2, 3, 4]))
        #expect(await transfer.downloadDestinations().count == 2)
        #expect(!fileManager.fileExists(atPath: stableTemporary.path))
        try await downloader.close()
    }

    @Test func resourceMaintenanceDoesNotDeleteUnownedFiles() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("v2-media-cache-cleanup-" + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let target = try V2ClientMediaTransferTarget(downloadPlan: .init(mode: .httpGet,
            url: #require(URL(string: "https://media.invalid/object")), expiresAt: .distantFuture,
            expectedByteCount: 0, checksum: .init(value: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")))
        let downloader = try await makeResourceMediaTestDownloader(
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

        try await downloader.performMaintenance()

        #expect(fileManager.fileExists(atPath: orphan.path))
        #expect(fileManager.fileExists(atPath: retained.path))
        try await downloader.close()
    }

    @Test func resourceMediaSharesOnePhysicalFileAcrossEquivalentIdentifiers() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("v2-media-cache-capacity-" + UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let target = try V2ClientMediaTransferTarget(downloadPlan: .init(mode: .httpGet,
            url: #require(URL(string: "https://media.invalid/object")), expiresAt: .distantFuture,
            expectedByteCount: 4, checksum: .init(value: "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a")))
        let downloader = try await makeResourceMediaTestDownloader(
            downloader: .init(
                targetResolver: V2MediaDownloadTargetResolverFake(target: target),
                byteTransfer: V2MediaByteTransferFake(downloadedData: Data([1, 2, 3, 4]))
            ),
            directory: root,
            cachePolicy: .init(maximumByteCount: 1_048_576, maximumEntryCount: 1, maximumAge: 3_600)
        )
        let first = try await downloader.download(.init(mediaID: .init("cache-first")))
        let second = try await downloader.download(.init(mediaID: .init("cache-second")))

        #expect(first.fileURL == second.fileURL)
        #expect(fileManager.fileExists(atPath: second.fileURL.path))
        #expect(try fileManager.contentsOfDirectory(at: second.fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil).count == 1)
        try await downloader.close()
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
        let store = makeConversationDetailStore(
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
        let store = makeConversationDetailStore(
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
        let store = makeConversationDetailStore(
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            messageReactionChanger: changer,
            userID: "current-user",
            roomID: "room-a"
        )

        await store.changeReaction("👍", on: message,action:.remove)
        await store.changeReaction("❤️", on: message,action:.add)

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
        let store = makeConversationDetailStore(dataSource: source, sender: nil, messageReactionChanger: changer, userID: "current-user", roomID: "room-a")

        await store.changeReaction("👍", on: message)

        #expect(!store.canReactToMessage(message))
        #expect(await changer.requests().isEmpty)
    }

    @Test func messageEditUsesProjectionRevisionAndRefreshesAfterAcknowledgement() async {
        let message = V2ConversationMessageItem(id: "message-a", revision: 5, text: "原文", createdAt: .now, isOutgoing: true, isWithdrawn: false)
        let source = V2ConversationDataSourceFake(summaries: [], messages: [message])
        let editor = V2MessageEditorFake(result: .accepted)
        let store = makeConversationDetailStore(
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
        let store = makeConversationDetailStore(dataSource: source, sender: nil, messageEditor: editor, userID: "current-user", roomID: "room-a")

        let shouldDismissEditor = await store.editMessage(message, text: "新文本")

        #expect(!shouldDismissEditor)
        #expect(await editor.requests().count == 1)
        #expect(store.messageActionFeedback == "编辑被拒绝（REVISION_CONFLICT），请刷新后重试。")
    }

    @Test func reactionExplicitOfflineTargetSurvivesPageAndUnknownNeedsUserContinuation() async throws {
        let f=try V2AppMessageWorkFixture();defer { f.remove() }
        let messageID=MessageID(uuid:UUID()),remote=V2AppReactionClient(account:f.account)
        let service=V2MessageReactionOperationService(accountID:f.account,store:f.store,client:remote)
        let message=V2ConversationMessageItem(id:messageID.rawValue,revision:1,text:"消息",createdAt:.now,isOutgoing:false,isWithdrawn:false)
        let detail=makeConversationDetailStore(dataSource:V2ConversationDataSourceFake(summaries:[],messages:[]),sender:nil,messageReactionChanger:V2OperationMessageReactionChanger(service:service),userID:f.account.rawValue,roomID:f.room.rawValue)
        let page=Task { await detail.observeReactionIntents() }
        await detail.changeReaction("👍",on:message,action:.remove)
        let intent=try #require(try await f.store.nextReactionDraft(now:Date()))
        #expect(intent.targetState == .absent)
        #expect(await remote.calls==0)
        page.cancel();await page.value
        #expect(try await f.store.nextReactionDraft(now:Date())==intent)
        #expect(try await service.prepareNextIntent())
        let work=try #require(try await f.store.operationWork(id:intent.id))
        let claim=try await f.claim(work)
        try await f.store.deferOperationWork(claim,until:Date(),code:"RESPONSE_LOST",scheduling:.needsAttention)
        let secondPage=Task { await detail.observeReactionIntents() }
        let deadline=ContinuousClock.now + .seconds(3)
        while detail.pendingReactions.first?.work?.scheduling != .needsAttention { try #require(ContinuousClock.now<deadline);await Task.yield() }
        await detail.refresh()
        #expect(try await f.store.operationWork(id:intent.id)?.scheduling == .needsAttention)
        await detail.resumeReactionIntent(intent.id)
        #expect(try await f.store.operationWork(id:intent.id)?.nextAction == .reconcile)
        #expect(try await f.store.reactionCommand(workID:intent.id).targetState == .absent)
        secondPage.cancel();await secondPage.value
        try await f.store.close()
    }

    @Test func messageMutationUnknownKeepsSavedDraftAndRequiresExplicitContinuation() async throws {
        let f=try V2AppMessageWorkFixture();defer { f.remove() }
        let messageID=MessageID(uuid:UUID())
        let id=try await f.mutation.enqueueEdit(roomID:f.room,messageID:messageID,expectedRevision:1,text:"已保存草稿")
        let work=try #require(try await f.store.operationWork(id:id))
        let claim=try await f.claim(work)
        try await f.store.deferOperationWork(claim,until:Date(),code:"RESPONSE_LOST",scheduling:.needsAttention)
        let message=V2ConversationMessageItem(id:messageID.rawValue,revision:1,text:"原文",createdAt:.now,isOutgoing:true,isWithdrawn:false)
        let detail=makeConversationDetailStore(dataSource:V2ConversationDataSourceFake(summaries:[],messages:[]),sender:nil,messageEditor:V2OperationMessageEditor(service:f.mutation),userID:f.account.rawValue,roomID:f.room.rawValue)
        let observer=Task { await detail.observeMessageMutations() }
        let deadline=ContinuousClock.now + .seconds(3)
        while detail.messageMutations.isEmpty { try #require(ContinuousClock.now<deadline);await Task.yield() }
        #expect(!(await detail.editMessage(message,text:"修改后的草稿")))
        #expect(detail.messageActionFeedback?.contains("尚未确认") == true)
        #expect(try await f.store.operationWork(id:id)?.scheduling == .needsAttention)
        guard case .edit(let frozen)=try await f.store.messageMutationPayload(workID:id) else { Issue.record("missing draft");return }
        #expect(frozen.text == "已保存草稿")
        observer.cancel();await observer.value
        #expect(try await f.store.operationWork(id:id)?.scheduling == .needsAttention)
        let secondObserver=Task { await detail.observeMessageMutations() }
        await detail.resumeMessageMutation(id)
        #expect(try await f.store.operationWork(id:id)?.nextAction == .reconcile)
        #expect(try await f.store.messageMutationPayload(workID:id) == .edit(frozen))
        #expect(await f.remote.calls == 0)
        secondObserver.cancel();await secondObserver.value
        try await f.store.close()
    }

    @Test func readSyncRequiresExplicitUserContinuation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path:"read-sync-ui-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let user = UserID(uuid:UUID()), room = RoomID(uuid:UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL:directory.appending(path:"state.sqlite"),installationBinding:.init(value:UUID()),userID:user)
        let service = V2ReadReceiptOperationService(accountID:user,store:local,client:ReadSyncAttentionClient())
        _ = try await service.enqueue(roomID:room,readThrough:3)
        _ = try await local.prepareNextReadReceiptIntent(accountID:user)
        let first = try #require(try await local.dueOperationWork(now:.now,kinds:[.readReceipt]).first)
        for _ in 0..<2 {
            let work = try #require(try await local.operationWork(id:first.id))
            guard case .claimed(let claim) = try await local.claimOperationWork(id:work.id,ownerID:UUID(),action:work.nextAction,now:work.nextActionAt) else { Issue.record("expected claim"); return }
            try await service.execute(claim)
        }
        let reporter = V2OperationConversationReadReporter(service:service)
        let detail = makeConversationDetailStore(dataSource:V2ConversationDataSourceFake(summaries:[],messages:[]),sender:nil,readReceiptReporter:reporter,userID:user.rawValue,roomID:room.rawValue)
        let observation = Task { await detail.observeReadSync() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !detail.readSyncNeedsAttention { try #require(ContinuousClock.now < deadline); await Task.yield() }
        _ = try await reporter.recordReadThrough(roomID:room.rawValue,roomSequence:8)
        await detail.refresh()
        #expect(try await local.operationWork(id:first.id)?.scheduling == .needsAttention)
        #expect(try await local.roomReadWatermark(roomID:room) == 8)
        await detail.resumeReadSync()
        while detail.readSyncNeedsAttention { try #require(ContinuousClock.now < deadline); await Task.yield() }
        #expect(try await local.operationWork(id:first.id)?.nextAction == .reconcile)
        observation.cancel(); await observation.value
        try await local.close()
    }

    @Test func visibleMessageReportsTheNewestVisibleRoomSequence() async throws {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [
            .init(id: "message-a", roomSequence: 4, revision: 1, text: "较早", createdAt: .now, isOutgoing: false, isWithdrawn: false),
            .init(id: "message-b", roomSequence: 9, revision: 1, text: "最新", createdAt: .now, isOutgoing: true, isWithdrawn: false)
        ])
        let reporter = V2ConversationReadReporterFake(result: .queuedForRetry)
        let store = makeConversationDetailStore(dataSource: source, sender: nil, readReceiptReporter: reporter, userID: "current-user", roomID: "room-a")

        await store.refresh()
        await store.reportVisibleMessage(try #require(store.messages.last))

        #expect(store.state == .loaded)
        #expect(await reporter.requests() == [.init(roomID: "room-a", roomSequence: 9)])
    }

    @Test func roomEntryAdvancesTheReadLineToTheKnownHeadBeyondTheLastMessage() async {
        // 房间尾部是非消息事件（编辑、reaction、置顶…）：房间头已经前进到 11，
        // 而最后一条可见消息仍停在 10。只上报消息序号会让未读永久停在 1。
        let source = V2ConversationDataSourceFake(summaries: [], messages: [
            .init(id: "message-a", roomSequence: 10, revision: 1, text: "最新消息", createdAt: .now, isOutgoing: false, isWithdrawn: false)
        ])
        await source.setReadCheckpoint(.init(knownHead: 11, appliedRoomSequence: 11))
        let reporter = V2ConversationReadReporterFake(result: .queuedForRetry)
        let store = makeConversationDetailStore(dataSource: source, sender: nil, readReceiptReporter: reporter, userID: "current-user", roomID: "room-a")

        await store.refresh()

        #expect(await reporter.requests() == [.init(roomID: "room-a", roomSequence: 11)])

        let revision = store.timelineRevision
        await source.setReadCheckpoint(.init(knownHead: 12, appliedRoomSequence: 12))
        await store.refresh(scopes: .conversationTimeline)
        #expect(store.timelineRevision == revision)
        await source.setReadCheckpoint(.init(knownHead: 13, appliedRoomSequence: 13))
        await store.refresh(scopes: .conversationMetadata)
        #expect(store.timelineRevision == revision)
        #expect(await reporter.requests().map(\.roomSequence) == [11, 12, 13])
    }

    @Test func roomEntryOnlyAdvancesToWhatTheDeviceAlreadyApplied() async {
        // 本地还落后于房间头（还有没收到的事件）：只上报真实已应用位置，不虚报。
        let source = V2ConversationDataSourceFake(summaries: [], messages: [
            .init(id: "message-a", roomSequence: 10, revision: 1, text: "最新消息", createdAt: .now, isOutgoing: false, isWithdrawn: false)
        ])
        await source.setReadCheckpoint(.init(knownHead: 14, appliedRoomSequence: 12))
        let reporter = V2ConversationReadReporterFake(result: .queuedForRetry)
        let store = makeConversationDetailStore(dataSource: source, sender: nil, readReceiptReporter: reporter, userID: "current-user", roomID: "room-a")

        await store.refresh()

        #expect(await reporter.requests() == [.init(roomID: "room-a", roomSequence: 12)])
    }

    @Test func unknownRoomHeadLeavesTheReadLineAtTheAppliedSequence() async {
        // 未读目录还没轮转到这个房间：房间头未知，但本地已应用位置是已知事实。
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        await source.setReadCheckpoint(.init(knownHead: nil, appliedRoomSequence: 6))
        let reporter = V2ConversationReadReporterFake(result: .queuedForRetry)
        let store = makeConversationDetailStore(dataSource: source, sender: nil, readReceiptReporter: reporter, userID: "current-user", roomID: "room-a")

        await store.refresh()

        #expect(await reporter.requests() == [.init(roomID: "room-a", roomSequence: 6)])
    }

    @Test func roomEntryWithoutAnyLocalEvidenceNeverInventsAReadPosition() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [
            .init(id: "message-a", roomSequence: 10, revision: 1, text: "最新消息", createdAt: .now, isOutgoing: false, isWithdrawn: false)
        ])
        await source.setReadCheckpoint(.init(knownHead: 11, appliedRoomSequence: nil))
        let reporter = V2ConversationReadReporterFake(result: .queuedForRetry)
        let store = makeConversationDetailStore(dataSource: source, sender: nil, readReceiptReporter: reporter, userID: "current-user", roomID: "room-a")

        await store.refresh()

        #expect(await reporter.requests().isEmpty)
    }

    @Test func browsingHistoricalTimelineDoesNotAdvanceTheReadLine() async {
        // 跳到历史位置时把已读线推到最新端会谎报"已经读完"。
        let history = (1...45).map { sequence in
            V2ConversationMessageItem(
                id: "message-\(sequence)",
                roomSequence: UInt64(sequence),
                revision: 1,
                text: "消息 \(sequence)",
                createdAt: .now,
                isOutgoing: false,
                isWithdrawn: false
            )
        }
        let source = V2ConversationDataSourceFake(summaries: [], messages: history)
        await source.setReadCheckpoint(.init(knownHead: 45, appliedRoomSequence: 45))
        let reporter = V2ConversationReadReporterFake(result: .queuedForRetry)
        let store = makeConversationDetailStore(dataSource: source, sender: nil, readReceiptReporter: reporter, userID: "current-user", roomID: "room-a")

        await store.loadTimeline(containing: "message-1")
        await store.refresh()

        #expect(store.isBrowsingHistoricalTimeline)
        #expect(await reporter.requests().isEmpty)
    }

    @Test func visibleRoomPollSubscribesForADirectConversation() async {
        // 私聊默认已是读模型房间：按会话类型过滤会让私聊打开时不补齐未读尾部。
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let synchronizer = V2ActiveHybridGroupSynchronizerFake(outcomes: [.notHybridRoom])
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-direct",
            kind: .direct(accountKind: .regular),
            activeHybridGroupSynchronizer: synchronizer
        )

        await store.pollVisibleHybridGroupEvents()

        #expect(await synchronizer.subscriptionRequests() == ["room-direct"])
    }

    @Test func profileConversationRegistersIdentityBeforeItsListProjectionArrives() async throws {
        let peer = try V2PublicIdentity(userID: .init(uuid: UUID()), handle: .init("profile_peer"),
            displayName: "Profile peer", accountKind: .regular)
        let room = RoomID(uuid: UUID()).rawValue
        let opener = V2DirectConversationOpenerFake(roomID: room)
        let store = makeConversationListStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            userID: UserID(uuid: UUID()).rawValue, directConversationOpener: opener)
        #expect(await store.openDirectConversation(with: peer) == room)
        #expect(store.items.isEmpty)
        let detail = store.detailStore(for: room)
        #expect(detail.kind == .direct(accountKind: .regular))
        #expect(detail.presentationKey == .init(userID: peer.userID, context: .directConversation))
        #expect(detail.authorPresentationContext != nil)
        #expect(await opener.targets() == [peer.userID.rawValue])
    }

    @Test func profileConversationReusesExistingDirectRoomWithoutOpeningAgain() async throws {
        let peer = try V2PublicIdentity(userID: .init(uuid: UUID()), handle: .init("existing_peer"),
            displayName: "Existing peer", accountKind: .regular)
        let room = RoomID(uuid: UUID()).rawValue
        let source = V2ConversationDataSourceFake(summaries: [
            .init(id: room, title: "", preview: "Message", lastActivity: .now, isOutgoing: false,
                kind: .direct(accountKind: .regular), presentationKey: .init(userID: peer.userID, context: .directConversation))
        ], messages: [])
        let opener = V2DirectConversationOpenerFake(roomID: RoomID(uuid: UUID()).rawValue)
        let store = makeConversationListStore(dataSource: source, userID: UserID(uuid: UUID()).rawValue,
            directConversationOpener: opener)
        await store.refresh()
        #expect(await store.openDirectConversation(with: peer) == room)
        #expect(await opener.targets().isEmpty)
    }

    @Test func concurrentProfileAndNewChatRequestsDoNotOpenTwice() async throws {
        let peer = try V2PublicIdentity(userID: .init(uuid: UUID()), handle: .init("busy_peer"),
            displayName: "Busy peer", accountKind: .regular)
        let room = RoomID(uuid: UUID()).rawValue
        let opener = V2SuspendingDirectConversationOpener(roomID: room)
        let store = makeConversationListStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            userID: UserID(uuid: UUID()).rawValue, directConversationOpener: opener)
        let opening = Task { await store.openDirectConversation(with: peer) }
        await opener.waitUntilOpening()
        #expect(await store.openDirectConversation(with: peer) == nil)
        #expect(await opener.openingCount() == 1)
        await opener.complete()
        #expect(await opening.value == room)
    }

    @Test func directConversationTrimsInputAndReturnsOpenedRoom() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let opener = V2DirectConversationOpenerFake(roomID: "room-direct")
        let resolver = V2ConversationPublicIdentityResolverFake(values: ["other_user": "other-user"])
        let store = makeConversationListStore(
            dataSource: source,
            userID: "current-user",
            directConversationOpener: opener,
            publicIdentityResolver: resolver
        )

        let roomID = await store.openDirectConversation(handle: "  @other_user  ")

        #expect(roomID == "room-direct")
        #expect(await opener.targets() == ["other-user"])
        #expect(store.directConversationFeedback == nil)
        let detail = store.detailStore(for: "room-direct")
        #expect(detail.presentationKey?.userID.rawValue == "other-user")
        #expect(detail.presentationKey?.context == .directConversation)
        #expect(detail.authorPresentationContext != nil)
    }

    @Test func directConversationRejectsBlankTargetBeforeNetwork() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let opener = V2DirectConversationOpenerFake(roomID: "room-direct")
        let store = makeConversationListStore(
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
        let store = makeConversationListStore(
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
        let store = makeConversationListStore(
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
        let store = makeConversationListStore(
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
        let store = makeConversationListStore(
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
        let store = makeConversationListStore(
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
        let store = makeConversationListStore(dataSource: source, userID: "current-user", publicIdentityResolver: resolver, groupConversationCreator: creator)

        let roomID = await store.createGroupConversation(title: " 项目群 ", memberHandlesText: " @user_a,\n@user_b ")

        #expect(roomID == "room-group")
        #expect(await creator.requests() == [.init(title: " 项目群 ", memberUserIDs: ["user-a", "user-b"])])
        #expect(store.detailStore(for: "room-group").isGroupConversation)
    }

    @Test func directoryGroupOutsideInboxRetainsItsGroupCapabilitiesAndTitle() throws {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let store = makeConversationListStore(dataSource: source, userID: "current-user")
        let group = try V2ClientGroupDirectoryItem(roomID: .init("archived-group"), title: "归档群", isArchived: true)
        store.prepareGroupConversation(group)
        let detail = store.detailStore(for: group.roomID.rawValue)
        #expect(detail.isGroupConversation)
        #expect(detail.title == "归档群")
        #expect(store.items.isEmpty)
    }

    @Test func queuedGroupCreationCompletionIsMatchedToItsOriginalOperation() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let creator = V2GroupConversationCreatorFake(result: .queuedForRetry(operationID: "original-group-operation"))
        let store = makeConversationListStore(dataSource: source, userID: "current-user", groupConversationCreator: creator)
        #expect(await store.createGroupConversation(title: "群", memberHandlesText: "") == nil)
        #expect(store.completedGroupCreation == nil)
        #expect(await store.createGroupConversation(title: "重复提交", memberHandlesText: "") == nil)
        #expect(await creator.requests().count == 1)
        await creator.setRestoredStatus(.finalizing(operationID: "original-group-operation"))
        await store.refresh()
        #expect(store.activeGroupCreationOperationID == "original-group-operation")
        #expect(store.pendingGroupConversationOperationID == nil)
        await creator.setRestoredStatus(.created(roomID: "created-group"))
        await store.refresh()
        #expect(store.completedGroupCreation == .init(operationID: "original-group-operation", roomID: "created-group"))
        #expect(store.detailStore(for: "created-group").isGroupConversation)
        #expect(store.detailStore(for: "created-group").title == "群")
        #expect(store.pendingGroupConversationOperationID == nil)
    }

    @Test func groupConversationKeepsDurableRetryVisible() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let creator = V2GroupConversationCreatorFake(result: .queuedForRetry(operationID: "group-operation-1"))
        let store = makeConversationListStore(dataSource: source, userID: "current-user", groupConversationCreator: creator)

        let roomID = await store.createGroupConversation(title: "项目群", memberHandlesText: "")

        #expect(roomID == nil)
        #expect(store.groupConversationFeedback == "建群请求已安全保存；取消结果由服务器确认。")
        #expect(store.pendingGroupConversationOperationID == "group-operation-1")

        await store.cancelPendingGroupConversationCreation()

        #expect(await creator.cancelledOperationIDs() == ["group-operation-1"])
        #expect(store.pendingGroupConversationOperationID == nil)
        #expect(store.groupConversationFeedback == "正在核对取消结果；若创建已开始，将继续确认原结果。")
    }

    @Test func groupConversationRestoresDurableFinalizingStatusAfterUIRecreation() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let creator = V2GroupConversationCreatorFake(
            result: .queuedForRetry(operationID: "unused"),
            restoredStatus: .finalizing(operationID: "group-operation-2")
        )
        let store = makeConversationListStore(dataSource: source, userID: "current-user", groupConversationCreator: creator)

        await store.refresh()

        #expect(store.pendingGroupConversationOperationID == nil)
        #expect(store.groupConversationFeedback == "群聊已进入创建阶段，无法取消；完成后会显示在会话列表。")
    }

    @Test func groupConversationAllowsOnlyOneInFlightCreation() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let creator = V2SuspendingGroupConversationCreator(result: .created(roomID: "room-group"))
        let store = makeConversationListStore(
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

    @Test(arguments: [false, true])
    func ordinaryMemberRefreshKeepsDisplayWithoutGrantingManagement(authorityChanged: Bool) async {
        let page = V2GroupMemberPage(membershipRevision: 3, actorRole: "管理员",
            members: [.init(id: "member-a", role: "成员")], nextCursor: nil)
        let reader = V2ScriptedGroupMemberDirectory(results: [.success(page),
            .failure(.server(code: "UNAVAILABLE", retryable: true, retryAfterSeconds: 0, currentRevision: nil)), .success(page)])
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            sender: nil, userID: "current-user", roomID: "room-group", kind: .group, groupMemberDirectory: reader)
        await store.loadGroupMembers(reset: true)
        #expect(store.canAddGroupMembers)
        await store.loadGroupMembers(reset: true, reason: authorityChanged ? .authorizationChanged : .userInitiated)
        #expect(store.groupMembers.count == (authorityChanged ? 0 : 1))
        #expect(store.groupMemberDirectoryIsStale)
        #expect(store.groupActorRole == nil)
        #expect(!store.canAddGroupMembers)
        #expect(!store.canRemoveGroupMember(page.members[0]))
        #expect(store.groupMemberFeedback != nil)
        await store.loadGroupMembers(reset: true)
        #expect(store.groupMembers.map(\.id) == ["member-a"])
        #expect(!store.groupMemberDirectoryIsStale)
        #expect(store.canAddGroupMembers)
        #expect(store.groupMemberFeedback == nil)
        #expect(await reader.requestedCursors() == [nil, nil, nil])
    }

    @Test func groupMemberDirectoryPaginatesThroughAnInjectableReader() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let reader = V2GroupMemberDirectoryFake(pages: [
            nil: .init(
                membershipRevision: 3,
                actorRole: "成员",
                members: [
                    .init(id: "owner", role: "群主"),
                    .init(id: "member-a", role: "成员")
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            groupMemberDirectory: reader
        )

        await store.loadGroupMembers(reset: true)
        await store.loadGroupMembers()

        #expect(store.groupMembers.map(\.id) == ["owner", "member-a", "member-b"])
        #expect(store.groupMembers.first?.role == "群主")
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            kind: .group,
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

    @Test func groupMemberDirectoryRestartsWhenMembershipChangesBetweenPages() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let reader = V2ScriptedGroupMemberDirectory(results: [
            .success(.init(
                membershipRevision: 3,
                actorRole: "群主",
                members: [.init(id: "old-owner", role: "群主")],
                nextCursor: "opaque-revision-3"
            )),
            .failure(.server(code: "REVISION_CONFLICT", retryable: false, retryAfterSeconds: 0, currentRevision: 4)),
            .success(.init(
                membershipRevision: 4,
                actorRole: "群主",
                members: [
                    .init(id: "current-owner", role: "群主"),
                    .init(id: "current-member", role: "成员")
                ],
                nextCursor: nil
            ))
        ])
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            kind: .group,
            groupMemberDirectory: reader
        )

        await store.loadGroupMembers(reset: true)
        await store.loadGroupMembers()

        #expect(await reader.requestedCursors() == [nil, "opaque-revision-3", nil])
        #expect(store.groupMembers.map(\.id) == ["current-owner", "current-member"])
        #expect(store.groupMemberRevision == 4)
        #expect(!store.canLoadMoreGroupMembers)
        #expect(store.groupMemberFeedback == nil)
    }

    @Test(arguments: ["conflict", "changed-page", "FORBIDDEN", "NOT_FOUND", "reset", "network"])
    func groupMemberInvalidationClearsOldManagementState(scenario: String) async {
        let first = V2GroupMemberPage(membershipRevision: 3, actorRole: "管理员",
            members: [.init(id: "member-a", role: "成员")],
            nextCursor: "revision-3")
        var results: [Result<V2GroupMemberPage, V2RealtimeTransportError>] = [.success(first)]
        if scenario == "conflict" {
            results.append(.failure(.server(code: "REVISION_CONFLICT", retryable: false, retryAfterSeconds: 0, currentRevision: 4)))
        } else if scenario == "changed-page" {
            results.append(.success(.init(membershipRevision: 4, actorRole: "成员", members: [], nextCursor: nil)))
        }
        results.append(.failure(.server(code: ["FORBIDDEN", "NOT_FOUND"].contains(scenario) ? scenario : "UNAVAILABLE",
            retryable: true, retryAfterSeconds: 0, currentRevision: nil)))
        let reader = V2ScriptedGroupMemberDirectory(results: results)
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            sender: nil, userID: "current-user", roomID: "room-group", kind: .group, groupMemberDirectory: reader)
        await store.loadGroupMembers(reset: true)
        #expect(store.canAddGroupMembers)
        await store.loadGroupMembers(reset: scenario == "reset", reason: .authorizationChanged)
        if scenario == "network" {
            #expect(store.groupMembers.map(\.id) == ["member-a"])
            #expect(store.groupMemberRevision == 3)
            #expect(store.canLoadMoreGroupMembers)
        } else {
            #expect(store.groupMembers.isEmpty)
            #expect(store.groupActorRole == nil)
            #expect(store.groupMemberRevision == nil)
            #expect(!store.canAddGroupMembers)
            #expect(!store.canLoadMoreGroupMembers)
        }
        #expect(!store.isLoadingGroupMembers)
        #expect(store.groupMemberFeedback != nil)
    }

    @Test func groupMemberRefreshDiscardsLateRoleAndKeepsOneRequestOwner() async {
        let reader = V2SuspendingGroupMemberDirectory(page: .init(membershipRevision: 3, actorRole: "管理员",
            members: [.init(id: "old-member", role: "管理员")], nextCursor: "old"),
            refreshedPage: .init(membershipRevision: 4, actorRole: "成员", members: [], nextCursor: nil))
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            sender: nil, userID: "current-user", roomID: "room-group", kind: .group, groupMemberDirectory: reader)
        let request = Task { await store.loadGroupMembers(reset: true) }
        await reader.waitUntilRequested()
        await store.loadGroupMembers(reset: true)
        #expect(await reader.requestedCursors() == [nil])
        #expect(!store.canAddGroupMembers)
        await reader.complete()
        await request.value
        #expect(await reader.requestedCursors() == [nil, nil])
        #expect(store.groupMembers.isEmpty)
        #expect(store.groupMemberRevision == 4)
        #expect(store.groupActorRole == "成员")
        #expect(!store.canAddGroupMembers)
        #expect(!store.isLoadingGroupMembers)
    }

    @Test func groupMemberDirectoryAdvancesAcrossHiddenMemberPage() async {
        let reader = V2ScriptedGroupMemberDirectory(results: [
            .success(.init(membershipRevision: 3, actorRole: "成员", members: [], nextCursor: "hidden-scanned")),
            .success(.init(membershipRevision: 3, actorRole: "成员", members: [
                .init(id: "member-b", role: "成员")], nextCursor: nil))
        ])
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            sender: nil, userID: "current-user", roomID: "room-group", kind: .group, groupMemberDirectory: reader)
        await store.loadGroupMembers(reset: true)
        #expect(store.groupMembers.isEmpty && store.canLoadMoreGroupMembers)
        #expect(store.groupMemberFeedback == nil)
        await store.loadGroupMembers()
        #expect(await reader.requestedCursors() == [nil, "hidden-scanned"])
        #expect(store.groupMembers.map(\.id) == ["member-b"])
        #expect(!store.canLoadMoreGroupMembers)
    }

    @Test(arguments: ["duplicate", "stalled"])
    func groupMemberInvalidPageDoesNotLeavePartialRoster(scenario: String) async {
        let member = V2GroupMemberItem(id: "member-a", role: "成员")
        let next = V2GroupMemberItem(id: "member-b", role: "成员")
        let reader = V2ScriptedGroupMemberDirectory(results: [
            .success(.init(membershipRevision: 3, actorRole: "管理员", members: [member], nextCursor: "first")),
            .success(.init(membershipRevision: 3, actorRole: "管理员",
                members: scenario == "duplicate" ? [member] : [next],
                nextCursor: scenario == "stalled" ? "first" : "second"))
        ])
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            sender: nil, userID: "current-user", roomID: "room-group", kind: .group, groupMemberDirectory: reader)
        await store.loadGroupMembers(reset: true)
        await store.loadGroupMembers()
        #expect(store.groupMembers.isEmpty)
        #expect(store.groupMemberRevision == nil)
        #expect(store.groupActorRole == nil)
        #expect(!store.canLoadMoreGroupMembers)
        #expect(store.groupMemberFeedback != nil)
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
        let store = makeConversationDetailStore(
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

    @Test(arguments: ["成员", "管理员", "群主"])
    func selfExitUsesAccountIdentityWithoutRequiringOwnPagedRow(role: String) async {
        let reader = V2GroupMemberDirectoryFake(pages: [nil: .init(membershipRevision: 8,
            actorRole: role, members: [.init(id: "member-a", role: "成员")], nextCursor: nil)])
        let changer = V2GroupMembershipChangerFake(result: .accepted)
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            sender: nil, userID: "current-user", roomID: "room-group", kind: .group,
            groupMemberDirectory: reader, groupMembershipChanger: changer)
        await store.loadGroupMembers(reset: true)
        #expect(store.canLeaveGroup == (role != "群主"))
        let saved = await store.leaveGroup()
        #expect(saved == (role != "群主"))
        let requests = await changer.requests()
        if role == "群主" { #expect(requests.isEmpty) }
        else {
            #expect(requests == [.init(roomID: "room-group", targetUserID: "current-user", action: .remove, expectedMembershipRevision: 8)])
            #expect(!store.canLeaveGroup)
            #expect(store.groupMemberFeedback == "已退出群聊。")
        }
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            kind: .group,
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
        #expect(store.groupMemberFeedback == "成员确认已保存；两分钟窗口内核对权限，超时需重新确认。")
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            kind: .group,
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            kind: .group,
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            kind: .group,
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            kind: .group,
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            kind: .group,
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-group",
            kind: .group,
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
        // A queued allow intent does not widen the authoritative privacy setting.
        #expect(!store.allowsStrangerMessages)
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
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-standard",
            kind: .group,
            activeHybridGroupSynchronizer: synchronizer
        )

        await store.pollVisibleHybridGroupEvents()

        #expect(await synchronizer.subscriptionRequests() == ["room-standard"])
    }

    @Test func visibleHybridGroupUsesATLSWakeBeforeTheNextCursorPullAndUnsubscribesOnExit() async {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let synchronizer = V2SubscribedHybridGroupSynchronizerFake()
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-hybrid",
            kind: .group,
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

    @Test func failedInitialRoomPullRetriesWithoutAnotherNotification() async throws {
        let synchronizer = V2SubscribedHybridGroupSynchronizerFake(failsFirstPull: true)
        let store = makeConversationDetailStore(
            dataSource: V2ConversationDataSourceFake(summaries: [], messages: []), sender: nil,
            userID: "current-user", roomID: "room-first-pull-retry", kind: .group,
            activeHybridGroupSynchronizer: synchronizer)
        let task = Task { await store.pollVisibleHybridGroupEvents() }
        let deadline = ContinuousClock.now + .seconds(4)
        while await synchronizer.synchronizations() < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await synchronizer.synchronizations() == 2)
        await synchronizer.waitForWakeCount(1)
        task.cancel()
        await task.value
        #expect(await synchronizer.unsubscribedRoomIDs() == ["room-first-pull-retry"])
    }

    @Test func metadataWakeDoesNotPullWhenAContiguousLiveBatchArrivesWithinGrace() async throws {
        let source = V2ConversationDataSourceFake(summaries: [], messages: [])
        let synchronizer = V2SubscribedHybridGroupSynchronizerFake(
            appliesLiveEvents: true
        )
        let store = makeConversationDetailStore(
            dataSource: source,
            sender: nil,
            userID: "current-user",
            roomID: "room-hybrid-grace",
            kind: .group,
            activeHybridGroupSynchronizer: synchronizer
        )
        let event = try V2ClientGroupEvent(
            sourceEventID: try .init("00000000-0000-0000-0000-000000000e81"),
            roomSequence: 8,
            projectionKind: "message",
            payload: Data([1])
        )

        let task = Task { await store.pollVisibleHybridGroupEvents() }
        await synchronizer.waitForSynchronizationCount(1)
        await synchronizer.waitForWakeCount(1)
        await synchronizer.emitWake(.init(
            roomID: "room-hybrid-grace",
            highWatermark: 8
        ))
        await synchronizer.waitForWakeCount(2)
        await synchronizer.emitWake(.init(
            roomID: "room-hybrid-grace",
            highWatermark: 8,
            liveEvents: [event]
        ))
        await synchronizer.waitForWakeCount(3)

        #expect(await synchronizer.synchronizations() == 1)
        task.cancel()
        await synchronizer.emitWake(.init(
            roomID: "room-hybrid-grace",
            highWatermark: 8
        ))
        await task.value
    }

    @Test(.timeLimit(.minutes(1))) func sharedRoomPageReceivesPayloadAfterGraceTimeoutAndReconnect() async throws {
        let wire = AppSubscriptionWire()
        let owner = makeAppSubscriptionOwner(wire)
        let room = try RoomID("page-reconnect-room")
        let synchronizer = V2SubscribedHybridGroupSynchronizerFake(appliesLiveEvents: true)
        let store = makeConversationDetailStore(
            dataSource: V2ConversationDataSourceFake(summaries: [], messages: []), sender: nil,
            userID: "current-user", roomID: room.rawValue, kind: .group,
            activeHybridGroupSynchronizer: synchronizer, roomSubscriptions: owner
        )
        let page = Task { await store.pollVisibleHybridGroupEvents() }
        let firstRun = Task { try await owner.run(connectionID: UUID()) }
        // Initial pull plus subscribe acknowledgement recovery expires its
        // 100 ms grace. The next wake must still reach the same page lease.
        await synchronizer.waitForSynchronizationCount(2)
        await wire.emitGroup(room: room, watermark: 8, events: [try appSubscriptionEvent(8)])
        try await waitForSubscriptionPage { await synchronizer.liveApplications() == 1 }
        #expect(await synchronizer.synchronizations() == 2)
        let secondRun = Task { try await owner.run(connectionID: UUID()) }
        _ = await firstRun.result
        await synchronizer.waitForSynchronizationCount(3)
        await wire.emitGroup(room: room, watermark: 9, events: [try appSubscriptionEvent(9)])
        try await waitForSubscriptionPage { await synchronizer.liveApplications() == 2 }
        #expect(await wire.count("subscribe-room") == 2)
        // The base adapter never owns a wire subscription in the new path.
        #expect(await synchronizer.subscribedRoomIDs().isEmpty)
        page.cancel()
        await page.value
        await wire.waitFor("unsubscribe-room", count: 1)
        secondRun.cancel()
        _ = await secondRun.result
    }

    @Test(.timeLimit(.minutes(1))) func sharedActivityRoutesRoomsAndSurvivesOneSceneClosing() async throws {
        let wire = AppSubscriptionWire()
        let owner = makeAppSubscriptionOwner(wire)
        let room = try RoomID("activity-room")
        func makeStore(_ id: String) -> V2ConversationDetailStore {
            makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
                                        sender: nil, userID: "current-user", roomID: id, roomSubscriptions: owner)
        }
        let first = makeStore(room.rawValue)
        let second = makeStore(room.rawValue)
        let other = makeStore("other-room")
        let firstPage = Task { await first.observeLiveActivity() }
        let secondPage = Task { await second.observeLiveActivity() }
        let otherPage = Task { await other.observeLiveActivity() }
        let firstRun = Task { try await owner.run(connectionID: UUID()) }
        try await waitForSubscriptionPage { first.peerPresence != nil && second.peerPresence != nil && other.peerPresence != nil }
        try await wire.emitTyping(room: room)
        try await waitForSubscriptionPage { !first.typingUserIDs.isEmpty && !second.typingUserIDs.isEmpty }
        #expect(other.typingUserIDs.isEmpty)
        #expect(await wire.count("subscribe-typing") == 2)
        firstPage.cancel()
        await firstPage.value
        #expect(await wire.count("unsubscribe-typing") == 0)
        second.draft = "typing before reconnect"
        second.updateTypingForDraft()
        await wire.waitFor("set-typing", count: 1)
        firstRun.cancel()
        _ = await firstRun.result
        try await waitForSubscriptionPage { second.typingUserIDs.isEmpty && second.peerPresence == nil && other.peerPresence == nil }
        let secondRun = Task { try await owner.run(connectionID: UUID()) }
        try await waitForSubscriptionPage { second.peerPresence != nil && other.peerPresence != nil }
        try await wire.emitTyping(room: room)
        try await waitForSubscriptionPage { !second.typingUserIDs.isEmpty }
        #expect(first.typingUserIDs.isEmpty && first.peerPresence == nil)
        #expect(await wire.count("subscribe-typing") == 4)
        #expect(await wire.count("set-typing") == 1)
        second.draft += " with a new keystroke"
        second.updateTypingForDraft()
        await wire.waitFor("set-typing", count: 2)
        secondPage.cancel()
        otherPage.cancel()
        await secondPage.value
        await otherPage.value
        await wire.waitFor("unsubscribe-typing", count: 2)
        secondRun.cancel()
        _ = await secondRun.result
    }

    private func waitForSubscriptionPage(_ predicate: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await predicate()), clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await predicate())
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
        let store = makeConversationDetailStore(
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
                .init(id: "inbox", title: "收件箱", preview: "消息", lastActivity: date, isOutgoing: false, kind: .unknown),
                .init(id: "archive", title: "归档", preview: "消息", lastActivity: date, isOutgoing: false, kind: .unknown, isArchived: true)
            ],
            messages: []
        )
        let store = makeConversationListStore(dataSource: source, userID: "current-user")

        await store.refresh()
        #expect(store.visibleItems.map(\.id) == ["inbox"])
        await store.toggleArchivedConversations()
        #expect(store.visibleItems.map(\.id) == ["archive"])
    }

    @Test func conversationListLoadsAdditionalKeysetPagesWithoutDuplicates() async {
        let summaries = (1 ... 51).map { index in
            V2ConversationListItem(
                id: String(format: "00000000-0000-0000-0000-%012d", index),
                title: "Room \(index)",
                preview: "Message",
                lastActivity: Date(timeIntervalSince1970: TimeInterval(1_750_000_000 + index)),
                isOutgoing: false,
                kind: .unknown
            )
        }
        let source = V2ConversationDataSourceFake(summaries: summaries, messages: [])
        let store = makeConversationListStore(dataSource: source, userID: "current-user")

        await store.refresh()
        #expect(store.items.count == 50)
        #expect(store.conversationNextCursor != nil)
        await store.loadMoreConversations()
        #expect(store.items.count == 51)
        #expect(Set(store.items.map(\.id)).count == 51)
        #expect(store.conversationNextCursor == nil)
        await store.refresh()
        #expect(store.items.count == 51)
        #expect(store.conversationNextCursor == nil)
    }

    @Test func conversationRefreshRetainsLoadedWindowAndListWhileReading() async {
        let summaries = (1...151).map { index in
            V2ConversationListItem(id: String(format: "00000000-0000-0000-0000-%012d", index), title: "Room \(index)", preview: "Message",
                lastActivity: Date(timeIntervalSince1970: Double(index)), isOutgoing: false, kind: .unknown)
        }
        let source = V2ConversationDataSourceFake(summaries: summaries, messages: [])
        let store = makeConversationListStore(dataSource: source, userID: "current-user")
        await store.refresh()
        await store.loadMoreConversations()
        await store.loadMoreConversations()
        let loadedIDs = store.items.map(\.id)
        #expect(loadedIDs.count == 150)
        await source.pauseNextSummaryRead()
        let refreshing = Task { await store.refresh() }
        await source.waitForPausedSummaryRead()
        #expect(store.state == .loaded)
        #expect(store.items.map(\.id) == loadedIDs)
        await store.loadMoreConversations()
        #expect(!store.isLoadingMoreConversations)
        await source.resumeSummaryRead()
        await refreshing.value
        #expect(store.items.map(\.id) == loadedIDs)
        await source.removeSummary(id: loadedIDs[75])
        await store.refresh()
        #expect(store.items.count == 150)
        #expect(!store.items.contains { $0.id == loadedIDs[75] })
        await store.refresh(resetWindow: true)
        #expect(store.items.count == 50)
    }

    @Test func oldConversationPageCannotReleaseReplacementPageOwnership() async {
        let summaries = (1...101).map { index in
            V2ConversationListItem(id: String(format: "00000000-0000-0000-0000-%012d", index), title: "Room \(index)", preview: "Message",
                lastActivity: Date(timeIntervalSince1970: Double(index)), isOutgoing: false, kind: .unknown)
        }
        let source = V2ConversationDataSourceFake(summaries: summaries, messages: [])
        let store = makeConversationListStore(dataSource: source, userID: "current-user")
        await store.refresh()
        await source.pauseNextSummaryRead()
        let oldPage = Task { await store.loadMoreConversations() }
        await source.waitForPausedSummaryRead()
        await store.refresh()
        await source.pauseNextSummaryRead()
        let newPage = Task { await store.loadMoreConversations() }
        await source.waitForPausedSummaryRead(1)
        await source.resumeSummaryRead()
        await oldPage.value
        #expect(store.items.count == 50 && store.isLoadingMoreConversations)
        await store.loadMoreConversations()
        await source.resumeSummaryRead(1)
        await newPage.value
        #expect(store.items.count == 100 && !store.isLoadingMoreConversations)
        #expect(Set(store.items.map(\.id)).count == 100)
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
        let detail = makeConversationDetailStore(
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

    @Test func forbiddenGroupSubscriptionPersistsRevokedAccessWithoutErasingCapacityClass() async throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000f21")
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "im-v2-group-access-\(UUID().uuidString).sqlite")
        let localStore = try await V2LocalStoreBootstrapper(
            bindingStore: V2RuntimeInstallationBindingStoreFake(),
            makeBinding: {
                .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000f22")!)
            }
        ).open(
            databaseURL: databaseURL
        )
        let profile = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000f23"),
            projectionKind: "membership",
            payload: JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed",
                "room_id": roomID.rawValue,
                "title": "已撤销事件权限的普通群",
                "owner_user_id": "00000000-0000-0000-0000-000000000f24",
                "target_user_id": "00000000-0000-0000-0000-000000000f25",
                "action": "remove",
                "membership_revision": 2,
                "capacity_class": "standard",

                "created_at_ms": 1_750_000_000_000,
                "server_created_at_ms": 1_750_000_001_000,
            ])
        )
        _ = try await localStore.apply(.init(
            generation: 1,
            records: [profile],
            nextSyncToken: .init("runtime-access-token"),
            receipt: .init("runtime-access-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let eventTransport = V2UnusedGroupEventTransportFake()
        let subscriptionTransport = V2ForbiddenGroupEventSubscriptionTransportFake()
        let synchronizer = V2RealtimeActiveHybridGroupSynchronizer(
            groupEventSync: .init(transport: eventTransport, store: localStore),
            localStore: localStore,
            subscriptionTransport: subscriptionTransport,
            wakeSource: V2UnusedGroupEventWakeSourceFake()
        )

        #expect(try await synchronizer.subscribe(roomID: roomID.rawValue) == .notHybridRoom)
        #expect(try await localStore.groupEventAccess(roomID: roomID) == .init(
            isAuthorized: false
        ))

        // A second foreground attempt observes durable local revocation and
        // never enters a FORBIDDEN network loop.
        #expect(try await synchronizer.subscribe(roomID: roomID.rawValue) == .notHybridRoom)
        #expect(await subscriptionTransport.requestCount() == 1)
    }

    @Test func contiguousHybridLiveBatchCommitsInOneDurableCursorStep() async throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000f31")
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "im-v2-live-batch-\(UUID().uuidString).sqlite")
        let localStore = try await V2LocalStoreBootstrapper(
            bindingStore: V2RuntimeInstallationBindingStoreFake(),
            makeBinding: {
                .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000f32")!)
            }
        ).open(databaseURL: databaseURL)
        let membership = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000f33"),
            projectionKind: "membership",
            payload: JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed",
                "room_id": roomID.rawValue,
                "title": "批量实时事件大群",
                "owner_user_id": "00000000-0000-0000-0000-000000000f34",
                "target_user_id": "00000000-0000-0000-0000-000000000f35",
                "action": "add",
                "membership_revision": 2,
                "capacity_class": "large",

                "created_at_ms": 1_750_000_000_000,
                "server_created_at_ms": 1_750_000_001_000,
            ])
        )
        _ = try await localStore.apply(.init(
            generation: 1,
            records: [membership],
            nextSyncToken: .init("live-batch-token"),
            receipt: .init("live-batch-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let events = try (UInt64(1) ... 2).map { sequence in
            try V2ClientGroupEvent(
                sourceEventID: try .init(
                    String(format: "00000000-0000-0000-0000-%012llu", 0xf40 + sequence)
                ),
                roomSequence: sequence,
                projectionKind: "message",
                payload: try JSONSerialization.data(withJSONObject: [
                    "event_type": "message.accepted",
                    "message_id": String(
                        format: "00000000-0000-0000-0000-%012llu",
                        0xf50 + sequence
                    ),
                    "room_id": roomID.rawValue,
                    "room_sequence": sequence,
                    "message_revision": 1,
                    "sender_user_id": "00000000-0000-0000-0000-000000000f36",
                    "text": "live-\(sequence)",
                    "mention_user_ids": [],
                    "mentions_everyone": false,
                    "server_created_at_ms": 1_750_000_002_000 + sequence,
                ])
            )
        }
        let eventTransport = V2UnusedGroupEventTransportFake()
        let synchronizer = V2RealtimeActiveHybridGroupSynchronizer(
            groupEventSync: .init(transport: eventTransport, store: localStore),
            localStore: localStore,
            subscriptionTransport: V2ForbiddenGroupEventSubscriptionTransportFake(),
            wakeSource: V2UnusedGroupEventWakeSourceFake()
        )

        #expect(try await synchronizer.applyLiveEvent(.init(
            roomID: roomID.rawValue,
            highWatermark: 2,
            liveEvents: events
        )))
        #expect(try await localStore.groupEventCursor(roomID: roomID) == 2)
        #expect(try await localStore.messages(in: roomID).map(\.text) == ["live-1", "live-2"])
    }
}

@MainActor
extension V2ConversationStoreTests {
    @Test("receipt reset waits for a cancelled transport and cannot publish the old page", arguments: [false, true])
    func readReceiptResetFencesOldPage(sameMessage: Bool) async throws {
        let room = RoomID(uuid: UUID()), gate = ReceiptPageTestGate()
        let reader = ReceiptPageTestReader(gate: gate)
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            sender: nil, groupReadReceiptReader: reader, userID: "current-user", roomID: room.rawValue, kind: .group)
        let firstMessage = receiptTestMessage(), secondMessage = sameMessage ? firstMessage : receiptTestMessage()
        let first = Task { await store.loadGroupReadReceipts(for: firstMessage, reset: true) }
        await gate.entered()
        let second = Task { await store.loadGroupReadReceipts(for: secondMessage, reset: true) }
        await gate.cancelled()
        #expect(store.groupReadReceiptPage == nil)
        #expect(await reader.calls == 1)
        #expect(store.isLoadingGroupReadReceipts)
        await gate.release()
        await first.value; await second.value
        #expect(await reader.calls == 2)
        #expect(store.groupReadReceiptPage?.messageID.rawValue == secondMessage.id)
        #expect(store.groupReadReceiptPage?.readers == [.init(userID: reader.currentUser)])
        #expect(!store.isLoadingGroupReadReceipts)
        #expect(store.groupReadReceiptFeedback == nil)
    }

    @Test("closing a receipt sheet drains its non-cooperative read and discards its result")
    func readReceiptCancellationDrains() async throws {
        let gate = ReceiptPageTestGate(), reader = ReceiptPageTestReader(gate: gate)
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            sender: nil, groupReadReceiptReader: reader, userID: "current-user", roomID: UUID().uuidString, kind: .group)
        let load = Task { await store.loadGroupReadReceipts(for: receiptTestMessage(), reset: true) }
        await gate.entered()
        load.cancel()
        await gate.cancelled()
        #expect(store.isLoadingGroupReadReceipts)
        await gate.release()
        await load.value
        #expect(!store.isLoadingGroupReadReceipts)
        #expect(store.groupReadReceiptPage == nil)
        #expect(store.groupReadReceiptFeedback == nil)
    }

    @Test("reader retention is bounded and returning to the first page resets the window")
    func readReceiptWindowIsBounded() async throws {
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
            sender: nil, groupReadReceiptReader: ReceiptWindowTestReader(), userID: "current-user",
            roomID: UUID().uuidString, kind: .group)
        let message = receiptTestMessage()
        for index in 0..<11 { await store.loadGroupReadReceipts(for: message, reset: index == 0) }
        #expect(store.groupReadReceiptPage?.readers.count == 1_000)
        #expect(store.hasEarlierGroupReadReceipts)
        #expect(store.groupReadReceiptPage?.readers.first?.userID.rawValue.hasSuffix("000000000101") == true)
        #expect(store.groupReadReceiptPage?.nextCursor == nil)
        await store.loadGroupReadReceipts(for: message, reset: true)
        #expect(store.groupReadReceiptPage?.readers.count == 100)
        #expect(!store.hasEarlierGroupReadReceipts)
        #expect(store.groupReadReceiptPage?.readers.first?.userID.rawValue.hasSuffix("000000000001") == true)
    }

    @Test("directory IDs produce only a group-scoped profile lookup")
    func groupDirectoryProfileKey() throws {
        let room = RoomID(uuid: UUID()), target = UserID(uuid: UUID())
        for kind in [V2ConversationKind.group, .direct(accountKind: .regular), .unknown] {
            let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []),
                sender: nil, userID: "current-user", roomID: room.rawValue, kind: kind)
            #expect(store.groupPresentationKey(for: target) == (kind == .group ? .init(userID: target, context: .room(room)) : nil))
        }
    }

    private func receiptTestMessage() -> V2ConversationMessageItem {
        .init(id: UUID().uuidString, revision: 1, text: "Message", createdAt: .now, isOutgoing: true, isWithdrawn: false)
    }
}

private actor ReceiptPageTestGate {
    private let starts = AsyncStream<Void>.makeStream(), cancellations = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0; starts.continuation.yield(()) }
        } onCancel: { cancellations.continuation.yield(()) }
    }
    func entered() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
    func cancelled() async { var iterator = cancellations.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { continuation?.resume(); continuation = nil }
}

private actor ReceiptPageTestReader: V2GroupReadReceiptReading {
    let currentUser = UserID(uuid: UUID()), oldUser = UserID(uuid: UUID())
    let gate: ReceiptPageTestGate
    private(set) var calls = 0
    init(gate: ReceiptPageTestGate) { self.gate = gate }
    func readers(roomID: String, messageID: String, cursor: String?) async throws -> V2ReadReceiptReadersPage {
        calls += 1
        let first = calls == 1
        if first { await gate.wait() }
        return try .init(roomID: .init(roomID), messageID: .init(messageID),
            readers: [.init(userID: first ? oldUser : currentUser)], nextCursor: nil)
    }
}

private struct ReceiptWindowTestReader: V2GroupReadReceiptReading {
    func readers(roomID: String, messageID: String, cursor: String?) throws -> V2ReadReceiptReadersPage {
        let offset = cursor.flatMap(Int.init) ?? 0
        return try .init(roomID: .init(roomID), messageID: .init(messageID), readers: (1...100).map { index in
            .init(userID: try .init(String(format: "00000000-0000-0000-0000-%012d", offset + index)))
        }, nextCursor: offset < 1_000 ? String(offset + 100) : nil)
    }
}

/// Test-only composition helpers keep individual tests focused on the one
/// capability they replace while production uses the grouped feature
/// environment directly.
@MainActor
private func makeConversationDetailStore(
    dataSource: any V2ConversationDataSource,
    messageSearcher: (any V2ConversationMessageSearching)? = nil,
    sender: (any V2ConversationSending)?,
    messageWithdrawer: (any V2MessageWithdrawing)? = nil,
    messageReactionChanger: (any V2MessageReactionChanging)? = nil,
    messageEditor: (any V2MessageEditing)? = nil,
    messageModerator: V2MessageModerationOperationService? = nil,
    readReceiptReporter: (any V2ConversationReadReporting)? = nil,
    messageFavoriter: (any V2MessageFavoriting)? = nil,
    groupMessagePinner: (any V2GroupMessagePinning)? = nil,
    messageForwarder: (any V2MessageForwarding)? = nil,
    forwardTargets: [V2ConversationForwardTarget] = [],
    groupAnnouncementReader: (any V2GroupAnnouncementReading)? = nil,
    groupAnnouncementManager: (any V2GroupAnnouncementManaging)? = nil,
    groupMemberRoleChanger: (any V2GroupMemberRoleChanging)? = nil,
    groupRolePolicyReader: (any V2GroupRolePolicyAccessing)? = nil,
    groupRolePolicyChanger: (any V2GroupRolePolicyChanging)? = nil,
    groupReadReceiptReader: (any V2GroupReadReceiptReading)? = nil,
    conversationLiveActivity: (any V2ConversationLiveActivityManaging)? = nil,
    userID: String,
    roomID: String,
    title: String = "会话",
    kind: V2ConversationKind = .direct(accountKind: .regular),
    groupMemberDirectory: (any V2GroupMemberDirectoryReading)? = nil,
    groupMembershipChanger: (any V2GroupMembershipChanging)? = nil,
    groupMemberMuter: (any V2GroupMemberMuting)? = nil,
    moderatedGroupMemberRemover: (any V2ModeratedGroupMemberRemoving)? = nil,
    publicIdentityResolver: (any V2ConversationPublicIdentityResolving)? = nil,
    attachmentStager: (any V2ConversationAttachmentStaging)? = nil,
    resourceSender: (any V2DurableConversationSending)? = nil,
    mediaDownloader: (any V2ConversationMediaDownloading)? = nil,
    mediaThumbnails: V2LocalMediaThumbnailCache? = nil,
    projectionChangeNotifier: V2ProjectionChangeNotifier? = nil,
    activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)? = nil,
    roomSubscriptions: V2RoomSubscriptionCoordinator? = nil,
    initialDraft: String? = nil,
    initialMentionHandles: String? = nil
) -> V2ConversationDetailStore {
    let environment = V2ConversationFeatureEnvironment(
        userID: userID,
        projections: .init(
            dataSource: dataSource,
            messageSearcher: messageSearcher,
            groupAnnouncementReader: groupAnnouncementReader,
            groupRolePolicyReader: groupRolePolicyReader
        ),
        messages: .init(
            sender: sender,
            withdrawer: messageWithdrawer,
            reactionChanger: messageReactionChanger,
            editor: messageEditor,
            readReceiptReporter: readReceiptReporter,
            favoriter: messageFavoriter,
            moderator: messageModerator,
            groupPinner: groupMessagePinner,
            forwarder: messageForwarder
        ),
        groups: .init(
            announcementManager: groupAnnouncementManager,
            memberRoleChanger: groupMemberRoleChanger,
            rolePolicyChanger: groupRolePolicyChanger,
            readReceiptReader: groupReadReceiptReader,
            memberDirectory: groupMemberDirectory,
            membershipChanger: groupMembershipChanger,
            memberMuter: groupMemberMuter,
            moderatedMemberRemover: moderatedGroupMemberRemover
        ),
        discovery: .init(publicIdentityResolver: publicIdentityResolver),
        media: .init(
            attachmentStager: attachmentStager,
            resourceSender: resourceSender,
            downloader: mediaDownloader,
            thumbnails: mediaThumbnails
        ),
        runtime: .init(
            liveActivity: conversationLiveActivity,
            projectionChangeNotifier: projectionChangeNotifier,
            activeHybridGroupSynchronizer: activeHybridGroupSynchronizer,
            roomSubscriptions: roomSubscriptions
        )
    )
    return .init(
        environment: environment,
        context: .init(
            roomID: roomID,
            title: title,
            kind: kind,
            forwardTargets: forwardTargets,
            initialDraft: initialDraft,
            initialMentionHandles: initialMentionHandles
        )
    )
}

@MainActor
private func makeConversationListStore(
    dataSource: any V2ConversationDataSource,
    messageSearcher: (any V2ConversationMessageSearching)? = nil,
    userID: String,
    sender: (any V2ConversationSending)? = nil,
    messageWithdrawer: (any V2MessageWithdrawing)? = nil,
    messageReactionChanger: (any V2MessageReactionChanging)? = nil,
    messageEditor: (any V2MessageEditing)? = nil,
    readReceiptReporter: (any V2ConversationReadReporting)? = nil,
    conversationStateChanger: (any V2ConversationStateChanging)? = nil,
    messageFavoriter: (any V2MessageFavoriting)? = nil,
    groupMessagePinner: (any V2GroupMessagePinning)? = nil,
    messageForwarder: (any V2MessageForwarding)? = nil,
    groupAnnouncementManager: (any V2GroupAnnouncementManaging)? = nil,
    groupMemberRoleChanger: (any V2GroupMemberRoleChanging)? = nil,
    groupRolePolicyChanger: (any V2GroupRolePolicyChanging)? = nil,
    groupReadReceiptReader: (any V2GroupReadReceiptReading)? = nil,
    conversationLiveActivity: (any V2ConversationLiveActivityManaging)? = nil,
    directConversationOpener: (any V2DirectConversationOpening)? = nil,
    publicIdentityResolver: (any V2ConversationPublicIdentityResolving)? = nil,
    groupConversationCreator: (any V2GroupConversationCreating)? = nil,
    groupMemberDirectory: (any V2GroupMemberDirectoryReading)? = nil,
    groupMembershipChanger: (any V2GroupMembershipChanging)? = nil,
    groupMemberMuter: (any V2GroupMemberMuting)? = nil,
    moderatedGroupMemberRemover: (any V2ModeratedGroupMemberRemoving)? = nil,
    attachmentStager: (any V2ConversationAttachmentStaging)? = nil,
    resourceSender: (any V2DurableConversationSending)? = nil,
    mediaDownloader: (any V2ConversationMediaDownloading)? = nil,
    projectionChangeNotifier: V2ProjectionChangeNotifier? = nil,
    activeHybridGroupSynchronizer: (any V2ActiveHybridGroupSynchronizing)? = nil
) -> V2ConversationListStore {
    .init(environment: .init(
        userID: userID,
        projections: .init(dataSource: dataSource, messageSearcher: messageSearcher),
        messages: .init(
            sender: sender,
            withdrawer: messageWithdrawer,
            reactionChanger: messageReactionChanger,
            editor: messageEditor,
            readReceiptReporter: readReceiptReporter,
            stateChanger: conversationStateChanger,
            favoriter: messageFavoriter,
            groupPinner: groupMessagePinner,
            forwarder: messageForwarder
        ),
        groups: .init(
            announcementManager: groupAnnouncementManager,
            memberRoleChanger: groupMemberRoleChanger,
            rolePolicyChanger: groupRolePolicyChanger,
            readReceiptReader: groupReadReceiptReader,
            conversationCreator: groupConversationCreator,
            memberDirectory: groupMemberDirectory,
            membershipChanger: groupMembershipChanger,
            memberMuter: groupMemberMuter,
            moderatedMemberRemover: moderatedGroupMemberRemover
        ),
        discovery: .init(
            directConversationOpener: directConversationOpener,
            publicIdentityResolver: publicIdentityResolver
        ),
        media: .init(
            attachmentStager: attachmentStager,
            resourceSender: resourceSender,
            downloader: mediaDownloader
        ),
        runtime: .init(
            liveActivity: conversationLiveActivity,
            projectionChangeNotifier: projectionChangeNotifier,
            activeHybridGroupSynchronizer: activeHybridGroupSynchronizer
        )
    ))
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
    func applyLiveEvent(_: V2ActiveHybridGroupWake) -> Bool { false }
    func nextWake() async throws -> V2ActiveHybridGroupWake { throw CancellationError() }
    func unsubscribe(roomID _: String) {}

    func requestedRoomIDs() -> [String] { roomIDs }
    func subscriptionRequests() -> [String] { subscriptionRoomIDs }
}

private actor V2SubscribedHybridGroupSynchronizerFake: V2ActiveHybridGroupSynchronizing {
    private let appliesLiveEvents: Bool
    private let failsFirstPull: Bool
    private var liveApplicationCount = 0
    private var synchronizationCount = 0
    private var wakeCount = 0
    private var synchronizationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var wakeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var wakeContinuation: CheckedContinuation<V2ActiveHybridGroupWake, Error>?
    private var subscribed: [String] = []
    private var unsubscribed: [String] = []

    init(appliesLiveEvents: Bool = false, failsFirstPull: Bool = false) {
        self.appliesLiveEvents = appliesLiveEvents
        self.failsFirstPull = failsFirstPull
    }

    func synchronizeOnePage(roomID _: String) throws -> V2ActiveHybridGroupSyncOutcome {
        synchronizationCount += 1
        resumeSynchronizationWaiters()
        if failsFirstPull && synchronizationCount == 1 {
            throw V2RealtimeTransportError.server(code: "UNAVAILABLE", retryable: true,
                retryAfterSeconds: 1, currentRevision: nil)
        }
        return .synchronized(appliedEventCount: 0, hasMore: false)
    }

    func subscribe(roomID: String) -> V2ActiveHybridGroupSubscriptionOutcome {
        subscribed.append(roomID)
        return .subscribed(highWatermark: 0)
    }

    func liveApplications() -> Int { liveApplicationCount }
    func applyLiveEvent(_ wake: V2ActiveHybridGroupWake) -> Bool {
        let applied = appliesLiveEvents && !wake.liveEvents.isEmpty
        if applied { liveApplicationCount += 1 }
        return applied
    }
    func nextWake() async throws -> V2ActiveHybridGroupWake {
        try Task.checkCancellation()
        wakeCount += 1
        resumeWakeWaiters()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    wakeContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelPendingWake() }
        }
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
    func synchronizations() -> Int { synchronizationCount }

    private func cancelPendingWake() {
        let continuation = wakeContinuation
        wakeContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }

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
    private var pausesHistory = false
    private var historyRead: CheckedContinuation<Void, Never>?
    private var historyWaiter: CheckedContinuation<Void, Never>?
    func pauseHistoryRead() { pausesHistory = true }
    func waitForHistoryRead() async {
        if historyRead != nil { return }
        await withCheckedContinuation { historyWaiter = $0 }
    }
    func resumeHistoryRead() { historyRead?.resume(); historyRead = nil }
    func roomLogHistoryIsIncomplete(roomID: String) async throws -> Bool {
        if pausesHistory {
            pausesHistory = false
            await withCheckedContinuation {
                historyRead = $0; historyWaiter?.resume(); historyWaiter = nil
            }
        }
        return false
    }
    private var summaries: [V2ConversationListItem]
    private let messages: [V2ConversationMessageItem]
    private var readCheckpoint: V2ConversationRoomReadCheckpoint = .unknown
    private var requestedMessageCount = 0
    private var failsSummaryRead = false
    func failNextSummaryRead() { failsSummaryRead = true }
    private var pausesSummaryRead = false
    private var pausedSummaryReadCount = 0
    private var summaryReads: [Int: CheckedContinuation<Void, Never>] = [:]
    private var summaryReadWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func pauseNextSummaryRead() { pausesSummaryRead = true }
    func waitForPausedSummaryRead(_ index: Int = 0) async {
        guard summaryReads[index] == nil else { return }
        await withCheckedContinuation { summaryReadWaiters[index] = $0 }
    }
    func resumeSummaryRead(_ index: Int = 0) { summaryReads.removeValue(forKey: index)?.resume() }
    func removeSummary(id: String) { summaries.removeAll { $0.id == id } }
    func setReadCheckpoint(_ checkpoint: V2ConversationRoomReadCheckpoint) { readCheckpoint = checkpoint }

    init(summaries: [V2ConversationListItem], messages: [V2ConversationMessageItem]) {
        self.summaries = summaries
        self.messages = messages
    }

    func roomReadCheckpoint(roomID _: String) async throws -> V2ConversationRoomReadCheckpoint {
        readCheckpoint
    }

    func conversationSummaryPage(
        for _: String,
        isArchived: Bool,
        before cursor: V2ClientConversationListCursor?,
        limit: Int
    ) async throws -> V2ConversationListPage {
        if failsSummaryRead { failsSummaryRead = false; throw V2SequencedStrangerMessagePreferenceReaderFailure.failed }
        if pausesSummaryRead {
            pausesSummaryRead = false
            let index = pausedSummaryReadCount
            pausedSummaryReadCount += 1
            await withCheckedContinuation {
                summaryReads[index] = $0
                summaryReadWaiters.removeValue(forKey: index)?.resume()
            }
        }
        let candidates = summaries
            .filter { $0.isArchived == isArchived }
            .filter { item in
                guard let cursor else { return true }
                if item.isPinned != cursor.isPinned { return !item.isPinned && cursor.isPinned }
                if item.lastActivity != cursor.lastActivity { return item.lastActivity < cursor.lastActivity }
                return item.id > cursor.roomID.rawValue
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                return lhs.id < rhs.id
            }
        let items = Array(candidates.prefix(limit))
        let nextCursor = candidates.count > limit ? try items.last.map {
            V2ClientConversationListCursor(
                isPinned: $0.isPinned,
                lastActivity: $0.lastActivity,
                roomID: try .init($0.id)
            )
        } : nil
        return .init(items: items, nextCursor: nextCursor)
    }

    func timelineWindow(in roomID: String, for userID: String, around messageID: String, before: Int, after: Int) async throws -> V2ConversationTimelineLocation {
        requestedMessageCount += 1
        let items = messages.sorted { $0.roomSequence < $1.roomSequence }
        guard let index = items.firstIndex(where: { $0.id == messageID }) else { return .unavailable }
        guard !items[index].isWithdrawn else { return .withdrawn }
        let lower = max(0, index - before), upper = min(items.count, index + after + 1)
        let selected = items[lower..<upper].map { V2ConversationTimelineItem.message($0, timelineSequence: $0.roomSequence) }
        let boundary = upper < items.count ? V2ConversationTimelineCursor(timelineSequence: items[upper].roomSequence, itemID: items[upper].id) : nil
        return .found(page: .init(items: selected, olderCursor: lower > 0 ? selected.first?.cursor : nil), newerBoundary: boundary)
    }

    func timelinePage(
        in roomID: String,
        for userID: String,
        before cursor: V2ConversationTimelineCursor?,
        limit: Int
    ) async throws -> V2ConversationTimelinePage {
        requestedMessageCount += 1
        return makeTimelinePage(messages: messages, before: cursor, limit: limit)
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
    private var summaryContinuations: [CheckedContinuation<V2ConversationListPage, Never>?] = []
    private var messageRequestCount = 0
    private var messageRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var messageContinuations: [CheckedContinuation<Result<[V2ConversationMessageItem], V2SequencedConversationDataSourceFailure>, Never>?] = []

    func conversationSummaryPage(
        for _: String,
        isArchived _: Bool,
        before _: V2ClientConversationListCursor?,
        limit _: Int
    ) async throws -> V2ConversationListPage {
        summaryRequestCount += 1
        let waiters = summaryRequestWaiters
        summaryRequestWaiters = []
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            summaryContinuations.append(continuation)
        }
    }

    func timelineWindow(in roomID: String, for userID: String, around messageID: String, before: Int, after: Int) async throws -> V2ConversationTimelineLocation {
        Issue.record("Refresh sequencing tests do not request timeline location")
        return .unavailable
    }

    func timelinePage(
        in _: String,
        for _: String,
        before cursor: V2ConversationTimelineCursor?,
        limit: Int
    ) async throws -> V2ConversationTimelinePage {
        messageRequestCount += 1
        let waiters = messageRequestWaiters
        messageRequestWaiters = []
        waiters.forEach { $0.resume() }
        let messages = try await withCheckedContinuation { continuation in
            messageContinuations.append(continuation)
        }.get()
        return makeTimelinePage(messages: messages, before: cursor, limit: limit)
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
        continuation.resume(returning: .init(items: items, nextCursor: nil))
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

private func makeTimelinePage(
    messages: [V2ConversationMessageItem],
    before cursor: V2ConversationTimelineCursor?,
    limit: Int
) -> V2ConversationTimelinePage {
    precondition(limit > 0)
    var candidates: [V2ConversationTimelineItem] = []
    candidates.reserveCapacity(messages.count)
    for message in messages {
        let item = V2ConversationTimelineItem.message(message, timelineSequence: message.roomSequence)
        if let cursor {
            let precedesSequence = item.timelineSequence < cursor.timelineSequence
            let precedesItem = item.timelineSequence == cursor.timelineSequence
                && item.storageItemID < cursor.itemID
            guard precedesSequence || precedesItem else { continue }
        }
        candidates.append(item)
    }
    candidates.sort { lhs, rhs in
        if lhs.timelineSequence != rhs.timelineSequence {
            return lhs.timelineSequence > rhs.timelineSequence
        }
        return lhs.storageItemID > rhs.storageItemID
    }
    let items = Array(candidates.prefix(limit).reversed())
    let olderCursor = candidates.count > limit ? items.first.map {
        V2ConversationTimelineCursor(timelineSequence: $0.timelineSequence, itemID: $0.storageItemID)
    } : nil
    return .init(items: items, olderCursor: olderCursor)
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

    func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], entities: [V2MessageEntity], replyTo: V2MessageReplyReference?, in roomID: String) async throws -> V2ConversationSendOutcome {
        messages.append(.init(text: text, media: media, roomID: roomID, mentions: mentions, entities: entities, replyTo: replyTo))
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

    func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], entities: [V2MessageEntity], replyTo: V2MessageReplyReference?, in roomID: String) async throws -> V2ConversationSendOutcome {
        messages.append(.init(text: text, media: media, roomID: roomID, mentions: mentions, entities: entities, replyTo: replyTo))
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
    let entities: [V2MessageEntity]
    let replyTo: V2MessageReplyReference?

    init(text: String, media: [V2MediaReference] = [], roomID: String, mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil) {
        self.text = text
        self.media = media
        self.roomID = roomID
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
    }
}

private actor V2ConversationAttachmentStagerFake: V2ConversationAttachmentStaging {
    private let result: Result<V2StagedConversationAttachment, Error>
    private var discarded: [V2StagedConversationAttachment] = []

    init(result: Result<V2StagedConversationAttachment, Error>) { self.result = result }

    func stageImportedFile(at _: URL, purpose: V2LocalResourceAssetPurpose) throws -> V2StagedConversationAttachment {
        try result.get()
    }

    func discard(_ attachment: V2StagedConversationAttachment) {
        discarded.append(attachment)
    }

    func discardedAttachments() -> [V2StagedConversationAttachment] { discarded }
}

private actor V2ConversationResourceSenderFake: V2DurableConversationSending {
    private let result: Result<Void, Error>
    private var attachments: [V2StagedConversationAttachment] = []
    private var rooms: [RoomID] = []
    init(result: Result<Void, Error>) { self.result = result }
    func freezeSend(text: String, mentions: [V2MentionTarget], replyTo: V2MessageReplyReference?,
                    roomID: RoomID, attachments: [V2StagedConversationAttachment]) throws {
        self.attachments += attachments
        rooms.append(roomID)
        try result.get()
    }
    func uploadedAttachments() -> [V2StagedConversationAttachment] { attachments }
    func frozenRooms() -> [RoomID] { rooms }
    func upload(_ attachment: V2StagedConversationAttachment, usage: V2ResourceUsage) throws -> V2MediaReference {
        Issue.record("chat attachments must use a room-bound send intent")
        throw V2AttachmentUploadFailure.failed
    }
    func copyAttachments(sources: [V2ResourceImportSource], to room: RoomID) throws { throw V2AttachmentUploadFailure.failed }
    func pending(in roomID: RoomID) -> [V2DurableConversationSendService.Pending] { [] }
    nonisolated func pendingPageUpdates(in roomID:RoomID,page:Int) -> AsyncThrowingStream<V2DurableConversationSendService.PendingPage,any Error> {
        AsyncThrowingStream { $0.yield(.init(items:[],hasNext:false));$0.finish() }
    }
    func retry(intentID: UUID) throws { throw V2AttachmentUploadFailure.failed }
    func cancel(intentID: UUID) throws { throw V2AttachmentUploadFailure.failed }
    func runRecovery() async throws {}
    func close() {}
}

private enum V2ConversationMediaDownloadFailure: Error, Sendable {
    case failed
}

private actor V2ConversationMediaDownloaderFake: V2ConversationMediaDownloading {
    private(set) var previewRequests = 0
    func imagePreview(_ media: V2MediaReference, message: V2MediaMessageLocation) throws -> V2DownloadedConversationMedia {
        previewRequests += 1
        guard let cached else { throw V2ConversationMediaDownloadFailure.failed }
        return cached
    }
    private(set) var cacheLookups = 0
    func cachedFile(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia? { cacheLookups += 1; return cached }
    func borrowCached(_ media: V2MediaReference, message: V2MediaMessageLocation?) throws -> V2ConversationMediaFileLease? { throw V2ConversationMediaDownloadFailure.failed }
    enum Result: Sendable {
        case success(V2DownloadedConversationMedia)
        case failure
    }

    private let result: Result
    private let cached: V2DownloadedConversationMedia?
    private let cachedPreview: V2DownloadedConversationMedia?
    func cachedImagePreview(_ media: V2MediaReference, message: V2MediaMessageLocation) -> V2DownloadedConversationMedia? { cachedPreview }
    private var requestsValue: [V2MediaReference] = []

    init(result: Result, cached: V2DownloadedConversationMedia? = nil, cachedPreview: V2DownloadedConversationMedia? = nil) {
        self.result = result
        self.cached = cached
        self.cachedPreview = cachedPreview
    }

    private(set) var lastMessageLocation: V2MediaMessageLocation?

    func download(_ media: V2MediaReference, message: V2MediaMessageLocation?) throws -> V2DownloadedConversationMedia {
        lastMessageLocation = message
        requestsValue.append(media)
        switch result {
        case .success(let downloaded): return downloaded
        case .failure: throw V2ConversationMediaDownloadFailure.failed
        }
    }

    func requests() -> [V2MediaReference] { requestsValue }
}

private actor V2ConversationMediaCacheDiscardingFake: V2ConversationMediaDownloading, V2ConversationMediaCacheDiscarding {
    func cachedFile(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia? { nil }
    func borrowCached(_ media: V2MediaReference, message: V2MediaMessageLocation?) throws -> V2ConversationMediaFileLease? { throw V2ConversationMediaDownloadFailure.failed }
    private var discarded: [V2MediaReference] = []

    func download(_: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia {
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

    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) -> V2ClientMediaTransferTarget {
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
        return try .init(userID: .init(userID), handle: .init(normalized), displayName: normalized, accountKind: .regular)
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
        return try .init(userID: .init("other-user"), handle: .init("other_user"), displayName: "Other", accountKind: .regular)
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
        return try .init(userID: .init("other-user"), handle: .init("other_user"), displayName: "Other", accountKind: .regular)
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
    private var restoredStatus: V2RestoredGroupConversationCreationStatus?
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
    func setRestoredStatus(_ value: V2RestoredGroupConversationCreationStatus) { restoredStatus = value }
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
    func restoredCreationStatus() async throws -> V2RestoredGroupConversationCreationStatus? { nil }

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
    private let refreshedPage: V2GroupMemberPage?
    private var cursors: [String?] = []
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    init(page: V2GroupMemberPage, refreshedPage: V2GroupMemberPage? = nil) {
        self.page = page
        self.refreshedPage = refreshedPage
    }

    func members(in _: String, cursor: String?) async throws -> V2GroupMemberPage {
        cursors.append(cursor)
        if cursors.count > 1 { return refreshedPage ?? page }
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

private actor V2ScriptedGroupMemberDirectory: V2GroupMemberDirectoryReading {
    private var results: [Result<V2GroupMemberPage, V2RealtimeTransportError>]
    private var cursors: [String?] = []

    init(results: [Result<V2GroupMemberPage, V2RealtimeTransportError>]) {
        self.results = results
    }

    func members(in _: String, cursor: String?) async throws -> V2GroupMemberPage {
        cursors.append(cursor)
        guard !results.isEmpty else { throw CancellationError() }
        return try results.removeFirst().get()
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

    nonisolated func membershipConfirmation(roomID:String,action:V2RoomMembershipAction,expectedMembershipRevision:UInt64) throws -> V2MembershipConfirmationWindow {
        // The UI fixture uses a named room; its transport boundary carries a real typed ID.
        let room = roomID == "room-group" ? RoomID(uuid:UUID(uuidString:"00000000-0000-0000-0000-000000000701")!) : try RoomID(roomID)
        return try .init(roomID:room,action:action,expectedMembershipRevision:expectedMembershipRevision,activationID:UUID())
    }
    func changeMembership(targetUserID:String,confirmation:V2MembershipConfirmationWindow) async throws -> V2GroupMembershipChangeOutcome {
        let roomID=confirmation.roomID.rawValue == "00000000-0000-0000-0000-000000000701" ? "room-group":confirmation.roomID.rawValue
        let action=confirmation.action,expectedMembershipRevision=confirmation.expectedMembershipRevision
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

    func muteMember(roomID: String, targetUserID: String, muteUntil: Date, reasonCode: V2ModerationReasonCode, expectedMembershipRevision: UInt64) async throws -> V2GroupModerationOutcome {
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

    func removeMemberByModerator(roomID: String, targetUserID: String, reasonCode: V2ModerationReasonCode, expectedMembershipRevision: UInt64) async throws -> V2GroupModerationOutcome {
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
        reasonCode _: V2ModerationReasonCode,
        expectedMembershipRevision _: UInt64
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

    nonisolated func membershipConfirmation(roomID:String,action:V2RoomMembershipAction,expectedMembershipRevision:UInt64) throws -> V2MembershipConfirmationWindow {
        // The UI fixture uses a named room; its transport boundary carries a real typed ID.
        let room = roomID == "room-group" ? RoomID(uuid:UUID(uuidString:"00000000-0000-0000-0000-000000000701")!) : try RoomID(roomID)
        return try .init(roomID:room,action:action,expectedMembershipRevision:expectedMembershipRevision,activationID:UUID())
    }
    func changeMembership(targetUserID:String,confirmation:V2MembershipConfirmationWindow) async throws -> V2GroupMembershipChangeOutcome {
        let roomID=confirmation.roomID.rawValue == "00000000-0000-0000-0000-000000000701" ? "room-group":confirmation.roomID.rawValue
        let action=confirmation.action,expectedMembershipRevision=confirmation.expectedMembershipRevision
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
        return try .init(userID: .init(userID), handle: .init(canonical), displayName: canonical, accountKind: .regular)
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

private struct V2UnusedGroupEventTransportFake: V2ClientGroupEventTransport {
    func pullGroupEvents(
        roomID _: RoomID,
        afterRoomSequence _: UInt64,
        pageSize _: Int
    ) async throws -> V2ClientGroupEventPage {
        throw V2RealtimeTransportError.unexpectedResponse
    }
}

private actor V2RuntimeInstallationBindingStoreFake: V2InstallationBindingStore {
    private var binding: V2LocalInstallationBinding?

    func load() -> V2LocalInstallationBinding? { binding }
    func save(_ binding: V2LocalInstallationBinding) { self.binding = binding }
    func delete() { binding = nil }
}

private actor V2ForbiddenGroupEventSubscriptionTransportFake: V2ClientGroupEventSubscriptionTransport {
    private var requests = 0

    func subscribeToGroupEvents(
        roomID _: RoomID,
        afterRoomSequence _: UInt64
    ) throws -> V2ClientGroupEventSubscription {
        requests += 1
        throw V2RealtimeTransportError.server(
            code: "FORBIDDEN",
            retryable: false,
            retryAfterSeconds: 0,
            currentRevision: nil
        )
    }

    func unsubscribeFromGroupEvents(roomID _: RoomID) {}

    func requestCount() -> Int { requests }
}

private struct V2UnusedGroupEventWakeSourceFake: V2GroupEventAvailabilityHintSource {
    func nextGroupEventAvailabilityHint() async throws -> V2GroupEventAvailabilityHint {
        throw CancellationError()
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

extension V2ConversationStoreTests {
    @Test func groupPolicyRefreshAcceptsRecoveryAndRejectsAnOlderExplicitRead() async throws {
        let room = try RoomID("00000000-0000-0000-0000-000000ABCDEF")
        let reader = SequencedRolePolicyReader()
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []), sender: nil, groupRolePolicyReader: reader, userID: "current-user", roomID: room.rawValue, kind: .group)
        let oldRead = Task { await store.loadGroupRolePolicies() }
        await reader.waitForCount(1)
        let refresh = Task { await store.refresh() }
        await reader.waitForCount(2)
        let recovered = V2ClientGroupRolePolicy(roomID: room, role: .member, permissions: [], revision: 8)
        await reader.complete(index: 1, policies: [recovered])
        await refresh.value
        #expect(store.groupRolePolicies == [recovered])
        await reader.complete(index: 0, policies: [.init(roomID: room, role: .member, permissions: [.sendMessages], revision: 2)])
        await oldRead.value
        #expect(store.groupRolePolicies == [recovered])
        #expect(store.isLoadingGroupRolePolicies == false)
    }
}

private actor SequencedRolePolicyReader: V2GroupRolePolicyAccessing {
    var requests: [CheckedContinuation<[V2ClientGroupRolePolicy], Never>] = []
    var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func groupRolePolicyState(in roomID: String) async throws -> V2ClientGroupRolePolicyState {
        let policies: [V2ClientGroupRolePolicy] = await withCheckedContinuation { continuation in
            requests.append(continuation)
            let ready = observers.filter { $0.0 <= requests.count }
            observers.removeAll { $0.0 <= requests.count }
            for item in ready { item.1.resume() }
        }
        return .init(policies: policies, recovery: .ready)
    }
    func retryGroupRolePolicyRecovery(in roomID: String) async throws -> V2ClientGroupRolePolicyState {
        throw V2RolePolicyRecoveryError.roomUnauthorized
    }
    func waitForCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func complete(index: Int, policies: [V2ClientGroupRolePolicy]) { requests[index].resume(returning: policies) }
}

extension V2ConversationStoreTests {
    @Test func pausedPolicyRecoveryRetriesOnceAndPreservesVisiblePolicies() async throws {
        let room = try RoomID("00000000-0000-0000-0000-000000ABCDEF")
        let policies = [V2ClientGroupRolePolicy(roomID: room, role: .member, permissions: [], revision: 8)]
        let access = PolicyRecoveryAccessFake(state: .init(policies: policies, recovery: .paused))
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []), sender: nil, groupRolePolicyReader: access, userID: "current-user", roomID: room.rawValue, kind: .group)
        await store.loadGroupRolePolicies()
        #expect(store.groupRolePolicyState.recovery == .paused)
        let retry = Task { await store.retryGroupRolePolicyRecovery() }
        await access.waitForRetry()
        #expect(store.policyRecoveryAction == .requesting)
        await store.retryGroupRolePolicyRecovery()
        #expect(await access.retryCount() == 1)
        let pending = V2ClientGroupRolePolicyState(policies: policies, recovery: .pending(nextAttemptAt: Date(timeIntervalSince1970: 0)))
        await access.finish(.success(pending))
        await retry.value
        #expect(store.groupRolePolicyState == pending)
        #expect(store.policyRecoveryAction == .idle)
        await store.retryGroupRolePolicyRecovery()
        #expect(await access.retryCount() == 1)
    }

    @Test func failedPolicyRecoveryRetryKeepsPausedStateAndAllowsAnotherAttempt() async throws {
        let room = try RoomID("00000000-0000-0000-0000-000000ABCDEF")
        let paused = V2ClientGroupRolePolicyState(policies: [], recovery: .paused)
        let access = PolicyRecoveryAccessFake(state: paused)
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []), sender: nil, groupRolePolicyReader: access, userID: "current-user", roomID: room.rawValue, kind: .group)
        await store.loadGroupRolePolicies()
        let first = Task { await store.retryGroupRolePolicyRecovery() }
        await access.waitForRetry()
        await access.finish(.failure(.accountUnavailable))
        await first.value
        #expect(store.policyRecoveryAction == .failed)
        #expect(store.groupRolePolicyState == paused)
        let second = Task { await store.retryGroupRolePolicyRecovery() }
        await access.waitForRetry(count: 2)
        let ready = V2ClientGroupRolePolicyState(policies: [], recovery: .ready)
        await access.finish(.success(ready))
        await second.value
        #expect(store.groupRolePolicyState == ready)
        #expect(store.policyRecoveryAction == .idle)
    }

    @Test func policyRecoveryDoesNotSubmitWithoutARecoverableState() async throws {
        let room = try RoomID("00000000-0000-0000-0000-000000ABCDEF")
        for recovery in [V2ClientRolePolicyRecoveryState.unavailable, .waitingForSynchronization, .ready, .pending(nextAttemptAt: Date(timeIntervalSince1970: 9_000))] {
            let access = PolicyRecoveryAccessFake(state: .init(policies: [], recovery: recovery))
            let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []), sender: nil, groupRolePolicyReader: access, userID: "current-user", roomID: room.rawValue, kind: .group)
            await store.loadGroupRolePolicies()
            await store.retryGroupRolePolicyRecovery()
            #expect(await access.retryCount() == 0)
        }
    }
}

private actor PolicyRecoveryAccessFake: V2GroupRolePolicyAccessing {
    var state: V2ClientGroupRolePolicyState
    var retries = 0
    var observer: (Int, CheckedContinuation<Void, Never>)?
    var completion: CheckedContinuation<V2ClientGroupRolePolicyState, any Error>?
    init(state: V2ClientGroupRolePolicyState) { self.state = state }
    func groupRolePolicyState(in roomID: String) async throws -> V2ClientGroupRolePolicyState { state }
    func retryGroupRolePolicyRecovery(in roomID: String) async throws -> V2ClientGroupRolePolicyState {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            retries += 1
            if let observer, retries >= observer.0 { observer.1.resume(); self.observer = nil }
        }
    }
    func waitForRetry(count: Int = 1) async {
        if retries >= count { return }
        await withCheckedContinuation { observer = (count, $0) }
    }
    func retryCount() -> Int { retries }
    func setState(_ value: V2ClientGroupRolePolicyState) { state = value }
    func finish(_ result: Result<V2ClientGroupRolePolicyState, V2RolePolicyRecoveryError>) {
        completion?.resume(with: result.mapError { $0 as any Error }); completion = nil
    }
}

extension V2ConversationStoreTests {
    @Test func missingPolicyCapabilityIsUnavailableInsteadOfOfferingAnIneffectiveRetry() async {
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []), sender: nil, userID: "current-user", roomID: "room-a", kind: .group)
        await store.loadGroupRolePolicies()
        #expect(store.groupRolePolicyState.recovery == .unavailable)
        await store.retryGroupRolePolicyRecovery()
        #expect(store.groupRolePolicyState.recovery == .unavailable)
        #expect(store.policyRecoveryAction == .idle)
    }
}

extension V2ConversationStoreTests {
    @Test func policyRetryFailureCannotReplaceANewerRecoveryStateOrPersistIntoAnotherPhase() async throws {
        let room = try RoomID("00000000-0000-0000-0000-000000ABCDEF")
        let paused = V2ClientGroupRolePolicyState(policies: [], recovery: .paused)
        let ready = V2ClientGroupRolePolicyState(policies: [.init(roomID: room, role: .admin, permissions: [], revision: 8), .init(roomID: room, role: .member, permissions: [], revision: 8)], recovery: .ready)
        let access = PolicyRecoveryAccessFake(state: paused)
        let store = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []), sender: nil, groupRolePolicyReader: access, userID: "current-user", roomID: room.rawValue, kind: .group)
        await store.loadGroupRolePolicies()
        let old = Task { await store.retryGroupRolePolicyRecovery() }
        await access.waitForRetry()
        await access.setState(ready)
        await store.refresh()
        await access.finish(.failure(.accountUnavailable))
        await old.value
        #expect(store.groupRolePolicyState == ready)
        #expect(store.policyRecoveryAction == .idle)
        await access.setState(paused)
        await store.loadGroupRolePolicies()
        let failed = Task { await store.retryGroupRolePolicyRecovery() }
        await access.waitForRetry(count: 2)
        await access.finish(.failure(.accountUnavailable))
        await failed.value
        #expect(store.policyRecoveryAction == .failed)
        let pending = V2ClientGroupRolePolicyState(policies: [], recovery: .pending(nextAttemptAt: Date(timeIntervalSince1970: 5_000)))
        await access.setState(pending)
        await store.refresh()
        #expect(store.groupRolePolicyState == pending)
        #expect(store.policyRecoveryAction == .idle)
    }
}

private struct V2GatedTimelineLocations: V2ConversationDataSource {
    let source: any V2ConversationDataSource
    let gate: V2ListWindowReadGate
    func conversationSummaryPage(for userID: String, isArchived: Bool, before cursor: V2ClientConversationListCursor?, limit: Int) async throws -> V2ConversationListPage {
        try await source.conversationSummaryPage(for: userID, isArchived: isArchived, before: cursor, limit: limit)
    }
    func timelinePage(in roomID: String, for userID: String, before cursor: V2ConversationTimelineCursor?, limit: Int) async throws -> V2ConversationTimelinePage {
        try await source.timelinePage(in: roomID, for: userID, before: cursor, limit: limit)
    }
    func timelineWindow(in roomID: String, for userID: String, around messageID: String, before: Int, after: Int) async throws -> V2ConversationTimelineLocation {
        let result = try await source.timelineWindow(in: roomID, for: userID, around: messageID, before: before, after: after)
        await gate.holdResult()
        return result
    }
}

private struct ReadSyncAttentionClient: V2ReadReceiptOperationClient {
    func submit(_ command:V2RecordReadReceiptCommand) throws -> V2ReadReceiptOperationReceipt { throw URLError(.networkConnectionLost) }
    func recover(_ request:V2ReadReceiptRecoveryRequest) -> V2ReadReceiptRecoveryResult { .currentUnavailable(.permissionDenied) }
}

extension V2ConversationStoreTests {
    @Test func administrationReconfirmationRequiresFreshManagementBaseline() async throws {
        let url=FileManager.default.temporaryDirectory.appending(path:"administration-ui-"+UUID().uuidString).appending(path:"state.sqlite")
        defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let account=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),target=UserID(uuid:UUID())
        let local=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:.init(value:UUID()),userID:account)
        let remote=AdministrationUIRemote()
        let original=V2MemberAdministrationOperationService(accountID:account,activationID:UUID(),store:local,client:remote)
        let id=try await original.enqueue(roomID:room,targetUserID:target,action:.remove,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:7)
        let restored=V2MemberAdministrationOperationService(accountID:account,activationID:UUID(),store:local,client:remote)
        #expect(try await restored.prepareNextIntent())
        let pending=try await local.memberAdministrationPending(id:id)
        let page=V2GroupMemberPage(membershipRevision:8,actorRole:"管理员",members:[.init(id:target.rawValue,role:"成员")],nextCursor:nil)
        let reader=V2ScriptedGroupMemberDirectory(results:[.success(page),.failure(.server(code:"UNAVAILABLE",retryable:true,retryAfterSeconds:0,currentRevision:nil)),.success(page)])
        let adapter=V2OperationGroupMemberAdministrator(service:restored)
        let detail=makeConversationDetailStore(dataSource:V2ConversationDataSourceFake(summaries:[],messages:[]),sender:nil,userID:account.rawValue,roomID:room.rawValue,kind:.group,groupMemberDirectory:reader,groupMemberMuter:adapter,moderatedGroupMemberRemover:adapter)
        await detail.loadGroupMembers(reset:true)
        await detail.loadGroupMembers(reset:true)
        await detail.continueMemberAdministration(pending)
        #expect(try await local.memberAdministrationPending(id:id).preparationState == .paused)
        #expect(detail.groupMemberFeedback == "请先刷新成员与管理权限，再重新确认。")
        await detail.loadGroupMembers(reset:true)
        await detail.continueMemberAdministration(pending)
        #expect(try await local.memberAdministrationPending(id:id).preparationState == .cancelled)
        var iterator=(await restored.updates(roomID:room)).makeAsyncIterator()
        let replacement=try #require(try await iterator.next()?.first)
        #expect(replacement.intent.expectedMembershipRevision==8)
        #expect(replacement.intent.operationID != pending.intent.operationID)
        #expect(await remote.admissions==0)
        try await local.close()
    }
    @Test func administrationUnknownContinuesOriginalProofWithoutFreshAdmission() async throws {
        let url=FileManager.default.temporaryDirectory.appending(path:"administration-unknown-ui-"+UUID().uuidString).appending(path:"state.sqlite")
        defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let account=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),target=UserID(uuid:UUID())
        let local=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:.init(value:UUID()),userID:account)
        let remote=AdministrationUIRemote(),service=V2MemberAdministrationOperationService(accountID:account,activationID:UUID(),store:local,client:AdministrationUIRemote())
        let id=try await service.enqueue(roomID:room,targetUserID:target,action:.remove,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:0)
        #expect(try await service.prepareNextIntent())
        let work=try #require(try await local.memberAdministrationPending(id:id).work)
        guard case .claimed(let claim)=try await local.claimOperationWork(id:work.id,ownerID:UUID(),action:.submit,now:work.nextActionAt) else { Issue.record("missing claim");return }
        try await local.deferOperationWork(claim,until:Date(),code:"UNAVAILABLE",scheduling:.needsAttention)
        let original=try await local.memberAdministrationCommand(workID:work.id)
        let restored=V2MemberAdministrationOperationService(accountID:account,activationID:UUID(),store:local,client:remote)
        let adapter=V2OperationGroupMemberAdministrator(service:restored)
        let detail=makeConversationDetailStore(dataSource:V2ConversationDataSourceFake(summaries:[],messages:[]),sender:nil,userID:account.rawValue,roomID:room.rawValue,kind:.group,groupMemberMuter:adapter,moderatedGroupMemberRemover:adapter)
        await detail.continueMemberAdministration(try await local.memberAdministrationPending(id:id))
        #expect(try await local.operationWork(id:work.id)?.scheduling == .ready)
        #expect(try await local.memberAdministrationCommand(workID:work.id)==original)
        #expect(await remote.admissions==0)
        try await local.close()
    }
}
private actor AdministrationUIRemote:V2MemberAdministrationOperationClient {
    var admissions=0
    func admit(_ intent:V2MemberAdministrationIntent) async throws -> V2MemberAdministrationAdmissionResult {
        admissions += 1
        return .admitted(try .init(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,membershipRevision:intent.expectedMembershipRevision,targetJoinedRevision:0,issuedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1000),expiresAtMilliseconds:intent.confirmedUntilMilliseconds))
    }
    func submit(_ command:V2MemberAdministrationCommand) async throws -> V2MemberAdministrationRecoveryResult { .unresolved }
    func recover(_ command:V2MemberAdministrationCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2MemberAdministrationRecoveryResult { .unresolved }
}

private actor V2PageModerationClient: V2MessageModerationOperationClient {
    var calls = 0
    func baseline(roomID: RoomID, messageID: MessageID) throws -> V2MessageModerationBaseline { calls += 1; throw URLError(.notConnectedToInternet) }
    func admit(_ intent: V2MessageModerationIntent) throws -> V2MessageModerationAdmissionResult { calls += 1; throw URLError(.notConnectedToInternet) }
    func submit(_ command: V2MessageModerationCommand) throws -> V2MessageModerationRecoveryResult { calls += 1; throw URLError(.notConnectedToInternet) }
    func recover(_ intent: V2MessageModerationIntent, action: V2OperationRecoveryRequest.Action) throws -> V2MessageModerationRecoveryResult { calls += 1; throw URLError(.notConnectedToInternet) }
}

extension V2ConversationStoreTests {
    @Test func managementRemovalLoadsSavedWorkWithoutOnlineAuthorityAndClosePreservesIt() async throws {
        let f = try V2AppMessageWorkFixture(); defer { f.remove() }
        let remote = V2PageModerationClient()
        let service = V2MessageModerationOperationService(accountID: f.account, activationID: UUID(), store: f.store, client: remote)
        let baseline = try V2MessageModerationBaseline(roomID: f.room, messageID: .init(uuid: UUID()), messageRevision: 1, membershipRevision: 1, isRedacted: false)
        let id = try await service.enqueue(baseline: baseline, reason: .init("moderation_removal"))
        let detail = makeConversationDetailStore(dataSource: V2ConversationDataSourceFake(summaries: [], messages: []), sender: nil, messageModerator: service, userID: f.account.rawValue, roomID: f.room.rawValue, kind: .group)
        let observer = Task { await detail.observeMessageRemoval() }
        let deadline = ContinuousClock.now + .seconds(3)
        while detail.messageRemovalPending.isEmpty { try #require(ContinuousClock.now < deadline); await Task.yield() }
        #expect(detail.messageRemovalPending.first?.work.id == id)
        #expect(!detail.canManageMessages)
        detail.endMessageRemovalPage()
        let proposal = V2ConversationDetailStore.MessageRemovalProposal(id: UUID(), baseline: baseline, generation: UUID(), expires: .now + .seconds(120), confirmedUntil: Date().addingTimeInterval(120), policies: [], membershipRevision: 1)
        await detail.confirmMessageRemoval(proposal)
        await detail.confirmMessageRemoval(proposal)
        #expect(detail.messageActionFeedback == nil)
        observer.cancel(); await observer.value
        #expect(try await f.store.messageModerationPending(id: id).intent.messageID == baseline.messageID)
        #expect(await remote.calls == 0)
        try await f.store.close()
    }
}

private actor V2PreviewDemandGate: V2ConversationMediaDownloading {
    private(set) var calls = 0
    private var first: CheckedContinuation<Void, Never>?
    func releaseFirst() { first?.resume(); first = nil }
    func imagePreview(_ media: V2MediaReference, message: V2MediaMessageLocation) async throws -> V2DownloadedConversationMedia {
        calls += 1
        if calls == 1 { await withCheckedContinuation { first = $0 }; try Task.checkCancellation() }
        throw V2MediaFileAccessError.unavailable
    }
    func cachedFile(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia? { nil }
    func borrowCached(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2ConversationMediaFileLease? { nil }
    func download(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia { throw V2MediaFileAccessError.unavailable }
}

private actor FirstPreviewDecodeCount {
    private(set) var value = 0
    func record() { value += 1 }
}
