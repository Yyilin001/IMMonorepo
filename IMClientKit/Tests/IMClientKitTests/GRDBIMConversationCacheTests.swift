import Foundation
import GRDB
@testable import IMClientKit
import Testing

struct GRDBIMConversationCacheTests {
    @Test func snapshotRoundTripPreservesMessagesMetadataAndTransfers() async throws {
        let ownerUserID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let cache = try makeCache()
        let conversationID = "conversation-1"
        let transferTaskID = TransferTaskID(sessionIdentifier: "background.session", taskIdentifier: 42)
        let snapshot = IMConversationCacheSnapshot(
            metadata: IMCacheMetadataState(
                selectedConversationID: conversationID,
                lastSummaryRefreshAt: Date(timeIntervalSince1970: 1_700_300_100),
                summarySyncToken: "sync-token",
                summaryNextCursor: "next-cursor",
                hasMoreConversationSummaries: true
            ),
            conversations: [
                IMCachedConversationState(
                    id: conversationID,
                    title: "Cache Target",
                    kind: .direct,
                    directMessagingState: .frozenAfterUnfriend,
                    directPeer: IMDirectPeer(
                        id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                        email: "peer@example.com"
                    ),
                    memberCount: 2,
                    memberUserIDs: [
                        ownerUserID,
                        UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                    ],
                    messages: [
                        try! IMCachedMessageState(
                            id: "message-2",
                            conversationID: conversationID,
                            clientMessageID: nil,
                            serverMessageID: "message-2",
                            senderUserID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                            serverSequence: 2,
                            timelineSequence: 2,
                            content: .richText(.plain("second")),
                            direction: .incoming,
                            createdAt: Date(timeIntervalSince1970: 1_700_300_002),
                            deliveryState: .received
                        ),
                        try! IMCachedMessageState(
                            id: "message-1",
                            conversationID: conversationID,
                            clientMessageID: "client-1",
                            serverMessageID: "message-1",
                            senderUserID: ownerUserID,
                            serverSequence: 1,
                            timelineSequence: 1,
                            content: .richText(.plain("first")),
                            direction: .outgoing,
                            createdAt: Date(timeIntervalSince1970: 1_700_300_001),
                            deliveryState: .sent,
                            transferTaskID: transferTaskID
                        ),
                    ],
                    hasLoadedMessages: true,
                    lastMessagePreviewText: "second",
                    hasMoreHistory: true,
                    latestLoadedTimelineSequence: 2,
                    oldestLoadedTimelineSequence: 1,
                    serverLastReadSequence: 1,
                    serverUnreadCount: 1,
                    isPinned: true,
                    pinnedAt: Date(timeIntervalSince1970: 1_700_300_050),
                    isMuted: true,
                    draftText: "draft",
                    draftUpdatedAt: Date(timeIntervalSince1970: 1_700_300_060),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_070)
                )
            ],
            cursors: [
                IMSyncCursorState(
                    conversationID: conversationID,
                    hasLoadedMessages: true,
                    latestLoadedTimelineSequence: 2,
                    oldestLoadedTimelineSequence: 1
                )
            ],
            transferSnapshots: [
                IMTransferSnapshot(
                    taskID: transferTaskID,
                    kind: .upload,
                    intent: .messageMediaUpload,
                    state: .running(progress: nil),
                    destinationURL: nil,
                    sourceFilePath: "/tmp/image.png",
                    uploadID: "upload-1"
                )
            ]
        )

        try await cache.saveSnapshot(snapshot, for: ownerUserID)
        let restored = try await cache.loadSnapshot(for: ownerUserID)

        #expect(restored.metadata == snapshot.metadata)
        #expect(restored.conversations.count == 1)
        #expect(restored.conversations.first?.messages.map(\.id) == ["message-1", "message-2"])
        #expect(restored.conversations.first?.directMessagingState == .frozenAfterUnfriend)
        #expect(restored.conversations.first?.isPinned == true)
        #expect(restored.conversations.first?.isMuted == true)
        #expect(restored.cursors == snapshot.cursors)
        #expect(restored.transferSnapshots == snapshot.transferSnapshots)
    }

    @Test func clearSnapshotOnlyRemovesTargetOwner() async throws {
        let firstOwner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondOwner = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let cache = try makeCache()

        try await cache.saveSnapshot(sampleSnapshot(ownerUserID: firstOwner), for: firstOwner)
        try await cache.saveSnapshot(sampleSnapshot(ownerUserID: secondOwner), for: secondOwner)

        try await cache.clearSnapshot(for: firstOwner)

        #expect(try await cache.loadSnapshot(for: firstOwner) == .empty)
        #expect(try await cache.loadSnapshot(for: secondOwner) == sampleSnapshot(ownerUserID: secondOwner))
    }

    @Test func duplicateSaveReplacesRows() async throws {
        let ownerUserID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let cache = try makeCache()

        try await cache.saveSnapshot(sampleSnapshot(ownerUserID: ownerUserID), for: ownerUserID)
        try await cache.saveSnapshot(sampleSnapshot(ownerUserID: ownerUserID), for: ownerUserID)

        let restored = try await cache.loadSnapshot(for: ownerUserID)
        #expect(restored.conversations.count == 1)
        #expect(restored.conversations.first?.messages.count == 1)
    }

    @Test func corruptMessageJSONFallsBackToPreviewWithoutDroppingSnapshot() async throws {
        let ownerUserID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let databaseURL = try temporaryDatabaseURL()
        let cache = try GRDBIMConversationCache(databaseURL: databaseURL)
        try await cache.saveSnapshot(sampleSnapshot(ownerUserID: ownerUserID), for: ownerUserID)

        let pool = try DatabasePool(path: databaseURL.path)
        try await pool.write { db in
            try db.execute(
                sql: """
                UPDATE cached_messages
                SET content_json = '{broken-json'
                WHERE owner_user_id = ?
                """,
                arguments: [ownerUserID.uuidString]
            )
        }

        let restored = try await cache.loadSnapshot(for: ownerUserID)

        #expect(restored.conversations.first?.messages.first?.text == "hello")
    }

    @Test func invalidTimelineNoticeStateIsRejectedAndReported() async throws {
        #expect(throws: IMTimelineNoticeValidationError.invalidTimelineSequence(0)) {
            try IMTimelineNotice(
                id: "notice-1",
                conversationID: "conversation-1",
                timelineSequence: 0,
                eventType: "member.added",
                actorUserID: nil,
                targetUserIDs: [],
                noticeKind: "member_added",
                fallbackText: "member added",
                createdAt: Date(timeIntervalSince1970: 1_700_300_001)
            )
        }
        #expect(throws: IMTimelineNoticeValidationError.missingNoticeKind) {
            try IMCachedTimelineNoticeState(
                id: "notice-1",
                conversationID: "conversation-1",
                timelineSequence: 1,
                eventType: "member.added",
                actorUserID: nil,
                targetUserIDs: [],
                noticeKind: "",
                fallbackText: "member added",
                createdAt: Date(timeIntervalSince1970: 1_700_300_001)
            )
        }
    }

    @Test func corruptTimelineNoticeJSONProducesDiagnostics() async throws {
        let ownerUserID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let databaseURL = try temporaryDatabaseURL()
        let cache = try GRDBIMConversationCache(databaseURL: databaseURL)
        try await cache.saveSnapshot(sampleSnapshot(ownerUserID: ownerUserID), for: ownerUserID)

        let pool = try DatabasePool(path: databaseURL.path)
        try await pool.write { db in
            try db.execute(
                sql: """
                UPDATE cached_conversations
                SET notices_json = '{broken-json'
                WHERE owner_user_id = ?
                """,
                arguments: [ownerUserID.uuidString]
            )
        }

        let restored = try await cache.loadSnapshot(for: ownerUserID)

        #expect(restored.conversations.first?.notices.isEmpty == true)
        #expect(restored.diagnostics.droppedTimelineNoticeCount == 1)
        #expect(restored.diagnostics.droppedTimelineNotices.first?.conversationID == "conversation-\(ownerUserID.uuidString)")
    }

    private func makeCache() throws -> GRDBIMConversationCache {
        try GRDBIMConversationCache(databaseURL: temporaryDatabaseURL())
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "IMClientKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "cache.sqlite", directoryHint: .notDirectory)
    }

    private func sampleSnapshot(ownerUserID: UUID) -> IMConversationCacheSnapshot {
        let conversationID = "conversation-\(ownerUserID.uuidString)"
        return IMConversationCacheSnapshot(
            metadata: IMCacheMetadataState(
                selectedConversationID: conversationID,
                lastSummaryRefreshAt: nil,
                summarySyncToken: nil,
                summaryNextCursor: nil,
                hasMoreConversationSummaries: false
            ),
            conversations: [
                IMCachedConversationState(
                    id: conversationID,
                    title: "Sample",
                    kind: .group,
                    memberCount: 1,
                    memberUserIDs: [ownerUserID],
                    messages: [
                        try! IMCachedMessageState(
                            id: "message-\(ownerUserID.uuidString)",
                            conversationID: conversationID,
                            clientMessageID: nil,
                            serverMessageID: "message-\(ownerUserID.uuidString)",
                            senderUserID: ownerUserID,
                            serverSequence: 1,
                            timelineSequence: 1,
                            content: .richText(.plain("hello")),
                            direction: .incoming,
                            createdAt: Date(timeIntervalSince1970: 1_700_300_001),
                            deliveryState: .received
                        )
                    ],
                    hasLoadedMessages: true,
                    lastMessagePreviewText: "hello",
                    hasMoreHistory: false,
                    latestLoadedTimelineSequence: 1,
                    oldestLoadedTimelineSequence: 1,
                    serverLastReadSequence: 0,
                    serverUnreadCount: 0,
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                )
            ],
            cursors: [
                IMSyncCursorState(
                    conversationID: conversationID,
                    hasLoadedMessages: true,
                    latestLoadedTimelineSequence: 1,
                    oldestLoadedTimelineSequence: 1
                )
            ]
        )
    }
}

struct ClientPersistenceFactoryTests {
    @Test func defaultFactoryBuildsGRDBBackedHandlersWithoutExposingGRDBTypes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "IMClientKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appending(path: "cache.sqlite", directoryHint: .notDirectory)
        let factory = ClientPersistenceFactory(databaseURLProvider: { databaseURL })

        let imHandler: IMConversationCacheHandler = factory.makeIMConversationCacheHandler()
        let contactHandler: ContactStateCacheHandler = factory.makeContactStateCacheHandler()
        let ownerUserID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

        #expect(try await imHandler.loadSnapshot(for: ownerUserID) == .empty)
        #expect(try await contactHandler.loadSnapshot(for: ownerUserID) == .empty)
    }
}
