import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 message character search")
struct V2MessageSearchTests {
    @Test("character grams preserve exact contiguous-substring semantics")
    func characterGrams() {
        let tokens = V2CharacterGramTokenizer().tokenize("你好啊")

        #expect(tokens.unigrams.count == 3)
        #expect(tokens.bigrams.count == 2)
        #expect(tokens.normalized == "你好啊")
        #expect(V2CharacterGramTokenizer.normalize("ＡＢＣ") == "abc")
    }

    @Test("single, multi-character, scoped, and paged searches are exact")
    func exactScopedSearchAndPaging() async throws {
        let store = try makeStore()
        let roomA = try RoomID("00000000-0000-0000-0000-000000000a01")
        let roomB = try RoomID("00000000-0000-0000-0000-000000000a02")
        let senderA = try UserID("00000000-0000-0000-0000-000000000a03")
        let senderB = try UserID("00000000-0000-0000-0000-000000000a04")
        let first = try MessageID("00000000-0000-0000-0000-000000000a11")
        let second = try MessageID("00000000-0000-0000-0000-000000000a12")
        let third = try MessageID("00000000-0000-0000-0000-000000000a13")

        try await apply(
            store,
            records: [
                acceptedRecord(sequence: 1, sourceEvent: "00000000-0000-0000-0000-000000000a21", roomID: roomA, senderID: senderA, messageID: first, roomSequence: 1, text: "你好啊", createdAtMilliseconds: 1_750_000_000_000),
                acceptedRecord(sequence: 2, sourceEvent: "00000000-0000-0000-0000-000000000a22", roomID: roomA, senderID: senderA, messageID: second, roomSequence: 2, text: "再说你好啊", createdAtMilliseconds: 1_750_000_001_000),
                acceptedRecord(sequence: 3, sourceEvent: "00000000-0000-0000-0000-000000000a23", roomID: roomB, senderID: senderB, messageID: third, roomSequence: 1, text: "你好吗", createdAtMilliseconds: 1_750_000_002_000)
            ],
            token: "search-token-1"
        )
        #expect(try await store.messageSearchIndexState() == .building)
        try await store.rebuildMessageSearchIndex()
        #expect(try await store.messageSearchIndexState() == .ready)

        let single = try await store.searchMessages(.init(query: "好", scope: .room(roomA)))
        #expect(single.hits.map(\.messageID) == [second, first])

        let phrase = try await store.searchMessages(.init(query: "好啊", scope: .room(roomA)))
        #expect(phrase.hits.map(\.messageID) == [second, first])

        let nonContiguous = try await store.searchMessages(.init(query: "你啊", scope: .allMessages))
        #expect(nonContiguous.hits.isEmpty)

        let senderOnly = try await store.searchMessages(.init(query: "你好", scope: .sender(senderA)))
        #expect(senderOnly.hits.map(\.messageID) == [second, first])

        let firstPage = try await store.searchMessages(.init(query: "你好", scope: .room(roomA), limit: 1))
        #expect(firstPage.hits.map(\.messageID) == [second])
        let cursor = try #require(firstPage.nextCursor)
        let secondPage = try await store.searchMessages(.init(query: "你好", scope: .room(roomA), limit: 1, cursor: cursor))
        #expect(secondPage.hits.map(\.messageID) == [first])
        #expect(secondPage.nextCursor == nil)
    }

    @Test("edits replace indexed text and withdrawals remove it")
    func editsAndWithdrawalsMaintainTheIndex() async throws {
        let store = try makeStore()
        let roomID = try RoomID("00000000-0000-0000-0000-000000000b01")
        let senderID = try UserID("00000000-0000-0000-0000-000000000b02")
        let messageID = try MessageID("00000000-0000-0000-0000-000000000b03")
        try await apply(store, records: [
            acceptedRecord(sequence: 1, sourceEvent: "00000000-0000-0000-0000-000000000b11", roomID: roomID, senderID: senderID, messageID: messageID, roomSequence: 1, text: "旧文本", createdAtMilliseconds: 1_750_000_000_000)
        ], token: "search-token-2")
        try await store.rebuildMessageSearchIndex()

        try await apply(store, records: [
            editedRecord(sequence: 2, sourceEvent: "00000000-0000-0000-0000-000000000b12", roomID: roomID, messageID: messageID, revision: 2, text: "新文本")
        ], token: "search-token-3")
        #expect(try await store.messageSearchIndexProgress().isCatchingUp)
        // The old document may still be physically present in V2Search, but
        // revision validation against V2.sqlite must hide it immediately.
        #expect(try await store.searchMessages(.init(query: "旧文", scope: .room(roomID))).hits.isEmpty)
        _ = try await store.processPendingMessageSearchIndexJobs()
        #expect(try await store.searchMessages(.init(query: "旧文", scope: .room(roomID))).hits.isEmpty)
        #expect(try await store.searchMessages(.init(query: "新文", scope: .room(roomID))).hits.map(\.messageID) == [messageID])

        try await apply(store, records: [
            tombstoneRecord(sequence: 3, sourceEvent: "00000000-0000-0000-0000-000000000b13", roomID: roomID, messageID: messageID, revision: 3)
        ], token: "search-token-4")
        _ = try await store.processPendingMessageSearchIndexJobs()
        #expect(try await store.searchMessages(.init(query: "新文", scope: .room(roomID))).hits.isEmpty)
        let persistedMessages = try await store.messages(in: roomID)
        let localTombstone = try #require(persistedMessages.first)
        #expect(localTombstone.isWithdrawn)
        #expect(localTombstone.text == "[removed]")
        #expect(localTombstone.media.isEmpty)
        #expect(localTombstone.mentions.isEmpty)
        #expect(localTombstone.entities.isEmpty)
    }

    @Test("media and sender filters can be combined without a text query")
    func mediaAndMemberFilters() async throws {
        let store = try makeStore()
        let roomID = try RoomID("00000000-0000-0000-0000-000000000d01")
        let imageSender = try UserID("00000000-0000-0000-0000-000000000d02")
        let fileSender = try UserID("00000000-0000-0000-0000-000000000d03")
        let imageMessage = try MessageID("00000000-0000-0000-0000-000000000d11")
        let fileMessage = try MessageID("00000000-0000-0000-0000-000000000d12")
        try await apply(store, records: [
            mediaRecord(sequence: 1, sourceEvent: "00000000-0000-0000-0000-000000000d21", roomID: roomID, senderID: imageSender, messageID: imageMessage, roomSequence: 1, mediaID: "00000000-0000-0000-0000-000000000d31", kind: "image"),
            mediaRecord(sequence: 2, sourceEvent: "00000000-0000-0000-0000-000000000d22", roomID: roomID, senderID: fileSender, messageID: fileMessage, roomSequence: 2, mediaID: "00000000-0000-0000-0000-000000000d32", kind: "file")
        ], token: "search-token-media")
        try await store.rebuildMessageSearchIndex()

        let images = try await store.searchMessages(.init(query: "", scope: .room(roomID), contentFilter: .image))
        #expect(images.hits.map(\.messageID) == [imageMessage])
        let senderFiles = try await store.searchMessages(.init(query: "", scope: .room(roomID), contentFilter: .media, senderUserID: fileSender))
        #expect(senderFiles.hits.map(\.messageID) == [fileMessage])
    }

    @Test("snapshot commit atomically replaces the FTS projection")
    func snapshotCommitReplacesTheSearchIndex() async throws {
        let store = try makeStore()
        let oldRoomID = try RoomID("00000000-0000-0000-0000-000000000c01")
        let oldSenderID = try UserID("00000000-0000-0000-0000-000000000c02")
        let oldMessageID = try MessageID("00000000-0000-0000-0000-000000000c03")
        try await apply(store, records: [
            acceptedRecord(sequence: 1, sourceEvent: "00000000-0000-0000-0000-000000000c04", roomID: oldRoomID, senderID: oldSenderID, messageID: oldMessageID, roomSequence: 1, text: "快照前文本", createdAtMilliseconds: 1_750_000_000_000)
        ], token: "search-token-snapshot-1")
        try await store.rebuildMessageSearchIndex()

        let snapshotRoomID = try RoomID("00000000-0000-0000-0000-000000000c11")
        let snapshotSenderID = try UserID("00000000-0000-0000-0000-000000000c12")
        let snapshotMessageID = try MessageID("00000000-0000-0000-0000-000000000c13")
        let snapshotMessage = try V2SnapshotMessageProjection(
            sourceEventID: .init("00000000-0000-0000-0000-000000000c14"),
            messageID: snapshotMessageID,
            roomID: snapshotRoomID,
            roomSequence: 7,
            senderUserID: snapshotSenderID,
            text: "快照后文本",
            createdAt: Date(timeIntervalSince1970: 1_750_000_100)
        )
        let payload = try V2SnapshotProjectionCodec.encode(messages: [snapshotMessage])
        let reset = try V2ClientResetRequired(
            snapshotID: .init("message-search-snapshot"),
            generation: 2,
            baseSequence: 1,
            manifestDigest: "message-search-manifest",
            expiresAt: .distantFuture
        )
        let pageDigest = "message-search-page"
        let manifest = try V2ClientSnapshotManifest(
            reset: reset,
            pageDigests: [pageDigest],
            nextSyncToken: .init("message-search-snapshot-token"),
            receipt: .init("message-search-snapshot-receipt"),
            capabilityProfile: "base"
        )
        try await store.beginReset(reset)
        try await store.beginSnapshotStaging(manifest)
        try await store.stageSnapshotPage(.init(index: 0, digest: pageDigest, payload: payload), for: manifest)
        try await store.commitStagedSnapshot(manifest)

        #expect(try await store.messageSearchIndexState() == .building)
        try await store.rebuildMessageSearchIndex()
        #expect(try await store.messageSearchIndexState() == .ready)
        #expect(try await store.searchMessages(.init(query: "快照前", scope: .allMessages)).hits.isEmpty)
        #expect(try await store.searchMessages(.init(query: "快照后", scope: .room(snapshotRoomID))).hits.map(\.messageID) == [snapshotMessageID])
    }

    @Test("an unacknowledged search job survives restart and replaces stale text")
    func searchJobResumesAfterRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-message-search-restart-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let roomID = try RoomID("00000000-0000-0000-0000-000000000e01")
        let senderID = try UserID("00000000-0000-0000-0000-000000000e02")
        let messageID = try MessageID("00000000-0000-0000-0000-000000000e03")
        let first = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await apply(first, records: [
            acceptedRecord(sequence: 1, sourceEvent: "00000000-0000-0000-0000-000000000e11", roomID: roomID, senderID: senderID, messageID: messageID, roomSequence: 1, text: "初始文本", createdAtMilliseconds: 1_750_000_000_000)
        ], token: "search-restart-1")
        try await first.rebuildMessageSearchIndex()
        try await apply(first, records: [
            editedRecord(sequence: 2, sourceEvent: "00000000-0000-0000-0000-000000000e12", roomID: roomID, messageID: messageID, revision: 2, text: "恢复后的文本")
        ], token: "search-restart-2")

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        #expect(try await restarted.messageSearchIndexProgress().isCatchingUp)
        _ = try await restarted.processPendingMessageSearchIndexJobs()
        #expect(try await restarted.searchMessages(.init(query: "恢复后", scope: .room(roomID))).hits.map(\.messageID) == [messageID])
        #expect(try await restarted.searchMessages(.init(query: "初始文", scope: .room(roomID))).hits.isEmpty)
    }

    private func makeStore() throws -> GRDBV2LocalSyncStore {
        try .init(
            databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-message-search-\(UUID().uuidString).sqlite"),
            installationBinding: .init(value: UUID())
        )
    }

    private func apply(_ store: GRDBV2LocalSyncStore, records: [V2ClientSyncRecord], token: String) async throws {
        _ = try await store.apply(.init(
            generation: 1,
            records: records,
            nextSyncToken: try .init(token),
            receipt: try .init("receipt-" + token),
            hasMore: false,
            capabilityProfile: "base"
        ))
    }

    private func acceptedRecord(sequence: UInt64, sourceEvent: String, roomID: RoomID, senderID: UserID, messageID: MessageID, roomSequence: UInt64, text: String, createdAtMilliseconds: Int64) throws -> V2ClientSyncRecord {
        try .init(
            sequence: sequence,
            sourceEventID: .init(sourceEvent),
            projectionKind: "message",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "message.accepted",
                "message_id": messageID.rawValue,
                "room_id": roomID.rawValue,
                "room_sequence": roomSequence,
                "message_revision": 1,
                "sender_user_id": senderID.rawValue,
                "text": text,
                "server_created_at_ms": createdAtMilliseconds
            ])
        )
    }

    private func editedRecord(sequence: UInt64, sourceEvent: String, roomID: RoomID, messageID: MessageID, revision: UInt64, text: String) throws -> V2ClientSyncRecord {
        try .init(
            sequence: sequence,
            sourceEventID: .init(sourceEvent),
            projectionKind: "message",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "message.edited",
                "room_id": roomID.rawValue,
                "message_id": messageID.rawValue,
                "message_revision": revision,
                "text": text
            ])
        )
    }

    private func mediaRecord(sequence: UInt64, sourceEvent: String, roomID: RoomID, senderID: UserID, messageID: MessageID, roomSequence: UInt64, mediaID: String, kind: String) throws -> V2ClientSyncRecord {
        try .init(
            sequence: sequence,
            sourceEventID: .init(sourceEvent),
            projectionKind: "message",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "message.accepted",
                "message_id": messageID.rawValue,
                "room_id": roomID.rawValue,
                "room_sequence": roomSequence,
                "message_revision": 1,
                "sender_user_id": senderID.rawValue,
                "text": "",
                "media_ids": [mediaID],
                "media_presentations": [["media_id": mediaID, "kind": kind, "content_type": "application/octet-stream", "byte_count": 1]],
                "server_created_at_ms": Int64(1_750_000_000_000 + Int64(sequence))
            ])
        )
    }

    private func tombstoneRecord(sequence: UInt64, sourceEvent: String, roomID: RoomID, messageID: MessageID, revision: UInt64) throws -> V2ClientSyncRecord {
        try .init(
            sequence: sequence,
            sourceEventID: .init(sourceEvent),
            projectionKind: "message",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "message.withdrawn",
                "room_id": roomID.rawValue,
                "message_id": messageID.rawValue,
                "message_revision": revision
            ])
        )
    }
}
