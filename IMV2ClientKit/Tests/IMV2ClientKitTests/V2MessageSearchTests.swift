import Foundation
import GRDB
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 message character search")
struct V2MessageSearchTests {
    @Test("search rejects REAL metadata and source revisions before consuming work",
          arguments: ["state-generation", "state-version", "document-sequence", "document-revision", "primary-revision", "primary-sequence", "job-revision"],
          [1.5, Double(Int64.max)])
    func searchStorageTypes(location: String, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-search-storage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID()), sender = UserID(uuid: UUID())
        do {
            try await apply(store, records: [acceptedRecord(sequence: 1, sourceEvent: UUID().uuidString,
                roomID: room, senderID: sender, messageID: message, roomSequence: 1,
                text: "boundary search", createdAtMilliseconds: 1_750_000_000_000)], token: "storage")
            try await store.rebuildMessageSearchIndex()
            let primary = await store.databasePool
            let pool = location.hasPrefix("document-") ? await store.messageSearchDatabasePool : primary
            let table: String, column: String
            switch location {
            case "state-generation": table = "v2_message_search_state"; column = "generation"
            case "state-version": table = "v2_message_search_state"; column = "index_version"
            case "document-sequence": table = "v2_search_documents"; column = "room_sequence"
            case "document-revision": table = "v2_search_documents"; column = "message_revision"
            case "primary-sequence": table = "v2_message_projections"; column = "room_sequence"
            case "primary-revision": table = "v2_message_projections"; column = "message_revision"
            default: table = "v2_message_search_jobs"; column = "expected_message_revision"
            }
            if location.hasPrefix("primary-") || location == "job-revision" {
                try await primary.write { db in try GRDBV2LocalSyncStore.enqueueMessageSearchIndexJob(messageID: message, db: db) }
            }
            let original = try await pool.write { db in
                let old = try #require(try Int64.fetchOne(db, sql: "SELECT \(column) FROM \(table) LIMIT 1"))
                try db.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [value])
                return old
            }
            if location.hasPrefix("primary-") || location == "job-revision" {
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try await store.processPendingMessageSearchIndexJobs() }
                #expect(try await primary.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_message_search_jobs") } == 1)
                if location == "primary-revision" {
                    await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
                        try await primary.write { db in try GRDBV2LocalSyncStore.enqueueMessageSearchIndexJob(messageID: message, db: db) }
                    }
                }
            }
            if location.hasPrefix("state-") {
                var updates = store.messageSearchIndexUpdates().makeAsyncIterator()
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try await updates.next() }
            }
            if location != "primary-sequence" && location != "job-revision" {
                for scope: V2MessageSearchScope in [.room(room), .allMessages, .sender(sender)] {
                    await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try await store.searchMessages(.init(query: "boundary", scope: scope)) }
                }
            }
            try await pool.read { db in
                let type = try String.fetchOne(db, sql: "SELECT typeof(\(column)) FROM \(table) LIMIT 1")
                let stored = try Double.fetchOne(db, sql: "SELECT \(column) FROM \(table) LIMIT 1")
                #expect(type == "real" && stored == value)
            }
            if location.hasPrefix("document-") {
                // Only the derived index is replaced by a normal rebuild.
                try await store.rebuildMessageSearchIndex()
            } else {
                try await pool.write { db in try db.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [original]) }
                if location.hasPrefix("primary-") || location == "job-revision" {
                    #expect(try await store.processPendingMessageSearchIndexJobs() == 1)
                }
            }
            #expect(try await store.searchMessages(.init(query: "boundary", scope: .room(room))).hits.map(\.messageID) == [message])
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    @Test("search preserves the largest persistent room sequence and rejects invalid source positions", arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func roomSequencePersistenceBounds(sequence: UInt64) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-search-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID()), sender = UserID(uuid: UUID())
        // Keep the integer decimal exact; an intermediate JSON number must
        // not round Int64.max into the first rejected value.
        let payload = Data("""
            {"event_type":"message.accepted","message_id":"\(message.rawValue)","room_id":"\(room.rawValue)","room_sequence":\(sequence),"message_revision":1,"sender_user_id":"\(sender.rawValue)","text":"boundary search","server_created_at_ms":1750000000000}
            """.utf8)
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(uuid: UUID()), projectionKind: "message", payload: payload)
        do {
            if sequence == 0 || sequence > UInt64(Int64.max) {
                if sequence == 0 {
                    await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await apply(store, records: [record], token: "bounds") }
                } else {
                    await #expect(throws: V2ClientSyncError.storageRangeExceeded) { try await apply(store, records: [record], token: "bounds") }
                }
                #expect(try await store.cursor() == nil)
                #expect(try await store.events().isEmpty)
                try await store.rebuildMessageSearchIndex()
                #expect(try await store.searchMessages(.init(query: "boundary", scope: .allMessages)).hits.isEmpty)
            } else {
                try await apply(store, records: [record], token: "bounds")
                try await store.rebuildMessageSearchIndex()
                for scope: V2MessageSearchScope in [.room(room), .allMessages, .sender(sender)] {
                    let result = try await store.searchMessages(.init(query: "boundary", scope: scope))
                    #expect(result.hits.map(\.messageID) == [message])
                    #expect(result.hits.map(\.roomSequence) == [sequence])
                }
            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("a corrupt derived search sequence fails safely and rebuilding restores search", arguments: [Int64.min, -1, 0])
    func corruptSearchSequenceRecovers(sequence: Int64) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-search-corrupt-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID()), sender = UserID(uuid: UUID())
        do {
            try await apply(store, records: [acceptedRecord(sequence: 1, sourceEvent: UUID().uuidString,
                roomID: room, senderID: sender, messageID: message, roomSequence: 1,
                text: "boundary search", createdAtMilliseconds: 1_750_000_000_000)], token: "corrupt-index")
            try await store.rebuildMessageSearchIndex()
            let pool = await store.messageSearchDatabasePool
            try await pool.write { db in
                // Model a damaged derived file; normal writes keep CHECK constraints enabled.
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                try db.execute(sql: "UPDATE v2_search_documents SET room_sequence = ? WHERE message_id = ?", arguments: [sequence, message.rawValue])
            }
            for scope: V2MessageSearchScope in [.room(room), .allMessages, .sender(sender)] {
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
                    try await store.searchMessages(.init(query: "boundary", scope: scope))
                }
            }
            try await store.rebuildMessageSearchIndex()
            let recovered = try await store.searchMessages(.init(query: "boundary", scope: .room(room)))
            #expect(recovered.hits.map(\.messageID) == [message])
            #expect(recovered.hits.map(\.roomSequence) == [1])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("search generation boundaries reject corrupt state before reading or rebuilding", arguments: [Int64.min, -1, 0, 1, Int64.max - 1, Int64.max])
    func searchGenerationBounds(generation: Int64) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-search-generation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID()), sender = UserID(uuid: UUID())
        do {
            try await apply(store, records: [acceptedRecord(sequence: 1, sourceEvent: UUID().uuidString,
                roomID: room, senderID: sender, messageID: message, roomSequence: 1,
                text: "boundary search", createdAtMilliseconds: 1_750_000_000_000)], token: "generation-index")
            try await store.rebuildMessageSearchIndex()
            let pool = await store.databasePool
            let original = try await pool.read { try GRDBV2LocalSyncStore.messageSearchIndexGeneration(db: $0) }
            try await pool.write { db in
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                try db.execute(sql: "UPDATE v2_message_search_state SET generation = ?", arguments: [generation])
            }
            if generation <= 0 {
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
                    try await store.searchMessages(.init(query: "boundary", scope: .room(room)))
                }
                var updates = store.messageSearchIndexUpdates().makeAsyncIterator()
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await updates.next() }
            } else {
                #expect(try await pool.read { try GRDBV2LocalSyncStore.messageSearchIndexGeneration(db: $0) } == generation)
                var updates = store.messageSearchIndexUpdates().makeAsyncIterator()
                #expect(try await updates.next()?.generation == UInt64(generation))
            }
            if generation <= 0 || generation == Int64.max {
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.rebuildMessageSearchIndex() }
                #expect(try await pool.read { try Int64.fetchOne($0, sql: "SELECT generation FROM v2_message_search_state") } == generation)
            } else {
                try await store.rebuildMessageSearchIndex()
                #expect(try await pool.read { try GRDBV2LocalSyncStore.messageSearchIndexGeneration(db: $0) } == generation + 1)
                #expect(try await store.searchMessages(.init(query: "boundary", scope: .room(room))).hits.map(\.messageID) == [message])
            }
            try await pool.write { db in
                try db.execute(sql: "UPDATE v2_message_search_state SET generation = ?", arguments: [original])
            }
            try await store.rebuildMessageSearchIndex()
            #expect(try await store.searchMessages(.init(query: "boundary", scope: .room(room))).hits.map(\.messageID) == [message])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("index observation includes current state and the completed rebuild generation")
    func indexObservationTracksRebuild() async throws {
        let store = try makeStore()
        var updates = store.messageSearchIndexUpdates().makeAsyncIterator()
        let initial = try #require(try await updates.next())
        #expect(initial.state == .building)
        try await store.rebuildMessageSearchIndex()
        var latest = try #require(try await updates.next())
        if latest.state == .building { latest = try #require(try await updates.next()) }
        #expect(latest.state == .ready)
        #expect(latest.generation > initial.generation)
        var alreadyReady = store.messageSearchIndexUpdates().makeAsyncIterator()
        #expect(try await alreadyReady.next()?.state == .ready)
    }

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
        await #expect(throws: V2MessageSearchError.cursorDoesNotMatchScope) {
            try await store.searchMessages(.init(query: "好啊", scope: .room(roomA), limit: 1, cursor: cursor))
        }
        try await store.rebuildMessageSearchIndex()
        await #expect(throws: V2MessageSearchError.cursorDoesNotMatchScope) {
            try await store.searchMessages(.init(query: "你好", scope: .room(roomA), limit: 1, cursor: cursor))
        }
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
        let payload = try JSONSerialization.data(withJSONObject: [
            "event_type": "message.accepted",
            "message_id": snapshotMessageID.rawValue,
            "room_id": snapshotRoomID.rawValue,
            "room_sequence": 7,
            "timeline_sequence": 7,
            "message_revision": 1,
            "sender_user_id": snapshotSenderID.rawValue,
            "text": "快照后文本",
            "media_ids": [],
            "media_presentations": [],
            "mention_user_ids": [],
            "mentions_everyone": false,
            "entities": [],
            "server_created_at_ms": 1_750_000_100_000,
            "is_withdrawn": false,
            "reactions": [],
        ], options: [.sortedKeys])
        let reset = try V2ClientResetRequired(
            snapshotID: .init("message-search-snapshot"),
            generation: 2,
            baseSequence: 1,
            expiresAt: .distantFuture
        )
        let page = try V2SnapshotProjectionV3Page(items: [
            .init(
                key: .init(projectionKind: "message", entityKey: snapshotMessageID.rawValue),
                sourceEventID: .init("00000000-0000-0000-0000-000000000c14"),
                sequence: 1,
                payload: payload
            )
        ])
        let encodedPage = try V2SnapshotProjectionV3Codec.encode(page)
        let pageDigest = V2SnapshotV3Digest.page(encodedPage)
        let initialDigest = V2SnapshotV3Digest.initial(baseSequence: 1, capabilityProfile: "base")
        let rootDigest = V2SnapshotV3Digest.next(
            previous: initialDigest,
            pageIndex: 0,
            pageDigest: pageDigest,
            firstKey: page.firstKey,
            lastKey: page.lastKey,
            itemCount: 1
        )
        let manifest = try V2ClientSnapshotManifest(
            reset: reset,
            rootDigest: rootDigest,
            pageCount: 1,
            totalItems: 1,
            totalBytes: UInt64(encodedPage.count),
            nextSyncToken: .init("message-search-snapshot-token"),
            receipt: .init("message-search-snapshot-receipt"),
            capabilityProfile: "base"
        )
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(manifest, initialDigest: initialDigest)
        try await store.applySnapshotPage(.init(
            index: 0,
            digest: pageDigest,
            firstKey: page.firstKey,
            lastKey: page.lastKey,
            itemCount: 1,
            payload: encodedPage
        ), for: manifest)
        try await store.prepareSnapshotActivation(manifest)
        try await store.activateAcknowledgedSnapshot(manifest)

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
                "media_presentations": [try resourcePresentationWireFixture(room: roomID.rawValue, media: mediaID, contentType: kind == "image" ? "image/jpeg" : "application/octet-stream", bytes: 1).merging(["kind": kind], uniquingKeysWith: { _, new in new })],
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
