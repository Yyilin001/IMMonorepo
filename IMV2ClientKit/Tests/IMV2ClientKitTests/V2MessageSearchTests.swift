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
            try await applyRoomEvents(store, records: [acceptedRoomEvent(sourceEvent: UUID().uuidString,
                roomID: room, senderID: sender, messageID: message, roomSequence: 1,
                text: "boundary search", createdAtMilliseconds: 1_750_000_000_000)])
            try await store.messageSearch.rebuildMessageSearchIndex()
            let primary = await store.databasePool
            let pool = location.hasPrefix("document-") ? try #require(await store.messageSearchDatabasePool) : primary
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
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try await store.messageSearch.processPendingMessageSearchIndexJobs() }
                #expect(try await primary.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_message_search_jobs") } == 1)
                if location == "primary-revision" {
                    await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
                        try await primary.write { db in try GRDBV2LocalSyncStore.enqueueMessageSearchIndexJob(messageID: message, db: db) }
                    }
                }
            }
            if location.hasPrefix("state-") {
                var updates = await store.messageSearch.messageSearchIndexUpdates().makeAsyncIterator()
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try await updates.next() }
            }
            if location != "primary-sequence" && location != "job-revision" {
                for scope: V2MessageSearchScope in [.room(room), .allMessages, .sender(sender)] {
                    await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try await store.messageSearch.searchMessages(.init(query: "boundary", scope: scope)) }
                }
            }
            try await pool.read { db in
                let type = try String.fetchOne(db, sql: "SELECT typeof(\(column)) FROM \(table) LIMIT 1")
                let stored = try Double.fetchOne(db, sql: "SELECT \(column) FROM \(table) LIMIT 1")
                #expect(type == "real" && stored == value)
            }
            if location.hasPrefix("document-") {
                // Only the derived index is replaced by a normal rebuild.
                try await store.messageSearch.rebuildMessageSearchIndex()
            } else {
                try await pool.write { db in try db.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [original]) }
                if location.hasPrefix("primary-") || location == "job-revision" {
                    #expect(try await store.messageSearch.processPendingMessageSearchIndexJobs() == 1)
                }
            }
            #expect(try await store.messageSearch.searchMessages(.init(query: "boundary", scope: .room(room))).hits.map(\.messageID) == [message])
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
        let envelopeSequence = (1...UInt64(Int64.max)).contains(sequence) ? sequence : 1
        let record = try V2ClientSyncRecord(sequence: envelopeSequence, sourceEventID: .init(uuid: UUID()), projectionKind: "message", payload: payload)
        do {
            if sequence == 0 || sequence > UInt64(Int64.max) {
                // The bounded envelope deliberately cannot endorse this source
                // position. Reject its payload before it can reach SQLite.
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await applyRoomEvents(store, records: [record]) }
                #expect(try await store.cursor() == nil)
                #expect(try await store.events().isEmpty)
                try await store.messageSearch.rebuildMessageSearchIndex()
                #expect(try await store.messageSearch.searchMessages(.init(query: "boundary", scope: .allMessages)).hits.isEmpty)
            } else {
                try await applyRoomEvents(store, records: [record])
                try await store.messageSearch.rebuildMessageSearchIndex()
                for scope: V2MessageSearchScope in [.room(room), .allMessages, .sender(sender)] {
                    let result = try await store.messageSearch.searchMessages(.init(query: "boundary", scope: scope))
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
            try await applyRoomEvents(store, records: [acceptedRoomEvent(sourceEvent: UUID().uuidString,
                roomID: room, senderID: sender, messageID: message, roomSequence: 1,
                text: "boundary search", createdAtMilliseconds: 1_750_000_000_000)])
            try await store.messageSearch.rebuildMessageSearchIndex()
            let pool = try #require(await store.messageSearchDatabasePool)
            try await pool.write { db in
                // Model a damaged derived file; normal writes keep CHECK constraints enabled.
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                try db.execute(sql: "UPDATE v2_search_documents SET room_sequence = ? WHERE message_id = ?", arguments: [sequence, message.rawValue])
            }
            for scope: V2MessageSearchScope in [.room(room), .allMessages, .sender(sender)] {
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
                    try await store.messageSearch.searchMessages(.init(query: "boundary", scope: scope))
                }
            }
            try await store.messageSearch.rebuildMessageSearchIndex()
            let recovered = try await store.messageSearch.searchMessages(.init(query: "boundary", scope: .room(room)))
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
            try await applyRoomEvents(store, records: [acceptedRoomEvent(sourceEvent: UUID().uuidString,
                roomID: room, senderID: sender, messageID: message, roomSequence: 1,
                text: "boundary search", createdAtMilliseconds: 1_750_000_000_000)])
            try await store.messageSearch.rebuildMessageSearchIndex()
            let pool = await store.databasePool
            let original = try await pool.read { try GRDBV2LocalSyncStore.messageSearchIndexGeneration(db: $0) }
            try await pool.write { db in
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                try db.execute(sql: "UPDATE v2_message_search_state SET generation = ?", arguments: [generation])
            }
            if generation <= 0 {
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
                    try await store.messageSearch.searchMessages(.init(query: "boundary", scope: .room(room)))
                }
                var updates = await store.messageSearch.messageSearchIndexUpdates().makeAsyncIterator()
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await updates.next() }
            } else {
                #expect(try await pool.read { try GRDBV2LocalSyncStore.messageSearchIndexGeneration(db: $0) } == generation)
                var updates = await store.messageSearch.messageSearchIndexUpdates().makeAsyncIterator()
                #expect(try await updates.next()?.generation == UInt64(generation))
            }
            if generation <= 0 || generation == Int64.max {
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.messageSearch.rebuildMessageSearchIndex() }
                #expect(try await pool.read { try Int64.fetchOne($0, sql: "SELECT generation FROM v2_message_search_state") } == generation)
            } else {
                try await store.messageSearch.rebuildMessageSearchIndex()
                #expect(try await pool.read { try GRDBV2LocalSyncStore.messageSearchIndexGeneration(db: $0) } == generation + 1)
                #expect(try await store.messageSearch.searchMessages(.init(query: "boundary", scope: .room(room))).hits.map(\.messageID) == [message])
            }
            try await pool.write { db in
                try db.execute(sql: "UPDATE v2_message_search_state SET generation = ?", arguments: [original])
            }
            try await store.messageSearch.rebuildMessageSearchIndex()
            #expect(try await store.messageSearch.searchMessages(.init(query: "boundary", scope: .room(room))).hits.map(\.messageID) == [message])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("index observation includes current state and the completed rebuild generation")
    func indexObservationTracksRebuild() async throws {
        let store = try makeStore()
        var updates = await store.messageSearch.messageSearchIndexUpdates().makeAsyncIterator()
        let initial = try #require(try await updates.next())
        #expect(initial.state == .building)
        try await store.messageSearch.rebuildMessageSearchIndex()
        var latest = try #require(try await updates.next())
        if latest.state == .building { latest = try #require(try await updates.next()) }
        #expect(latest.state == .ready)
        #expect(latest.generation > initial.generation)
        var alreadyReady = await store.messageSearch.messageSearchIndexUpdates().makeAsyncIterator()
        #expect(try await alreadyReady.next()?.state == .ready)
    }

    @Test("character grams preserve exact contiguous-substring semantics")
    func characterGrams() {
        let tokens = V2ContactSearchTokenizer().tokenize("你好啊")

        #expect(tokens.unigrams.count == 3)
        #expect(tokens.bigrams.count == 2)
        #expect(tokens.normalized == "你好啊")
        #expect(V2ContactSearchTokenizer.normalize("ＡＢＣ") == "abc")
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

        try await applyRoomEvents(
            store,
            records: [
                acceptedRoomEvent(sourceEvent: "00000000-0000-0000-0000-000000000a21", roomID: roomA, senderID: senderA, messageID: first, roomSequence: 1, text: "你好啊", createdAtMilliseconds: 1_750_000_000_000),
                acceptedRoomEvent(sourceEvent: "00000000-0000-0000-0000-000000000a22", roomID: roomA, senderID: senderA, messageID: second, roomSequence: 2, text: "再说你好啊", createdAtMilliseconds: 1_750_000_001_000),
                acceptedRoomEvent(sourceEvent: "00000000-0000-0000-0000-000000000a23", roomID: roomB, senderID: senderB, messageID: third, roomSequence: 1, text: "你好吗", createdAtMilliseconds: 1_750_000_002_000)
            ]
        )
        #expect(try await store.messageSearch.messageSearchIndexState() == .building)
        try await store.messageSearch.rebuildMessageSearchIndex()
        #expect(try await store.messageSearch.messageSearchIndexState() == .ready)

        let single = try await store.messageSearch.searchMessages(.init(query: "好", scope: .room(roomA)))
        #expect(single.hits.map(\.messageID) == [second, first])

        let phrase = try await store.messageSearch.searchMessages(.init(query: "好啊", scope: .room(roomA)))
        #expect(phrase.hits.map(\.messageID) == [second, first])

        let nonContiguous = try await store.messageSearch.searchMessages(.init(query: "你啊", scope: .allMessages))
        #expect(nonContiguous.hits.isEmpty)

        let senderOnly = try await store.messageSearch.searchMessages(.init(query: "你好", scope: .sender(senderA)))
        #expect(senderOnly.hits.map(\.messageID) == [second, first])

        let firstPage = try await store.messageSearch.searchMessages(.init(query: "你好", scope: .room(roomA), limit: 1))
        #expect(firstPage.hits.map(\.messageID) == [second])
        let cursor = try #require(firstPage.nextCursor)
        let secondPage = try await store.messageSearch.searchMessages(.init(query: "你好", scope: .room(roomA), limit: 1, cursor: cursor))
        #expect(secondPage.hits.map(\.messageID) == [first])
        #expect(secondPage.nextCursor == nil)
        await #expect(throws: V2MessageSearchError.cursorDoesNotMatchScope) {
            try await store.messageSearch.searchMessages(.init(query: "好啊", scope: .room(roomA), limit: 1, cursor: cursor))
        }
        try await store.messageSearch.rebuildMessageSearchIndex()
        await #expect(throws: V2MessageSearchError.cursorDoesNotMatchScope) {
            try await store.messageSearch.searchMessages(.init(query: "你好", scope: .room(roomA), limit: 1, cursor: cursor))
        }
    }

    @Test("edits replace indexed text and withdrawals remove it")
    func editsAndWithdrawalsMaintainTheIndex() async throws {
        let store = try makeStore()
        let roomID = try RoomID("00000000-0000-0000-0000-000000000b01")
        let senderID = try UserID("00000000-0000-0000-0000-000000000b02")
        let messageID = try MessageID("00000000-0000-0000-0000-000000000b03")
        try await applyRoomEvents(store, records: [
            acceptedRoomEvent(sourceEvent: "00000000-0000-0000-0000-000000000b11", roomID: roomID, senderID: senderID, messageID: messageID, roomSequence: 1, text: "旧文本", createdAtMilliseconds: 1_750_000_000_000)
        ])
        try await store.messageSearch.rebuildMessageSearchIndex()

        try await applyRoomEvents(store, records: [
            editedRecord(sequence: 2, sourceEvent: "00000000-0000-0000-0000-000000000b12", roomID: roomID, messageID: messageID, revision: 2, text: "新文本")
        ])
        #expect(try await store.messageSearch.messageSearchIndexProgress().isCatchingUp)
        // The old document may still be physically present in V2Search, but
        // revision validation against V2.sqlite must hide it immediately.
        #expect(try await store.messageSearch.searchMessages(.init(query: "旧文", scope: .room(roomID))).hits.isEmpty)
        _ = try await store.messageSearch.processPendingMessageSearchIndexJobs()
        #expect(try await store.messageSearch.searchMessages(.init(query: "旧文", scope: .room(roomID))).hits.isEmpty)
        #expect(try await store.messageSearch.searchMessages(.init(query: "新文", scope: .room(roomID))).hits.map(\.messageID) == [messageID])

        try await applyRoomEvents(store, records: [
            tombstoneRecord(sequence: 3, sourceEvent: "00000000-0000-0000-0000-000000000b13", roomID: roomID, messageID: messageID, revision: 3)
        ])
        #expect(try await store.messageSearch.searchMessages(.init(query: "新文", scope: .room(roomID))).hits.isEmpty)
        _ = try await store.messageSearch.processPendingMessageSearchIndexJobs()
        #expect(try await store.messageSearch.searchMessages(.init(query: "新文", scope: .room(roomID))).hits.isEmpty)
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
        try await applyRoomEvents(store, records: [
            mediaRoomEvent(sourceEvent: "00000000-0000-0000-0000-000000000d21", roomID: roomID, senderID: imageSender, messageID: imageMessage, roomSequence: 1, mediaID: "00000000-0000-0000-0000-000000000d31", kind: "image"),
            mediaRoomEvent(sourceEvent: "00000000-0000-0000-0000-000000000d22", roomID: roomID, senderID: fileSender, messageID: fileMessage, roomSequence: 2, mediaID: "00000000-0000-0000-0000-000000000d32", kind: "file")
        ])
        try await store.messageSearch.rebuildMessageSearchIndex()

        let images = try await store.messageSearch.searchMessages(.init(query: "", scope: .room(roomID), contentFilter: .image))
        #expect(images.hits.map(\.messageID) == [imageMessage])
        let senderFiles = try await store.messageSearch.searchMessages(.init(query: "", scope: .room(roomID), contentFilter: .media, senderUserID: fileSender))
        #expect(senderFiles.hits.map(\.messageID) == [fileMessage])
    }

    @Test("sender-only search preserves room scope, media results and cursor ownership")
    func senderOnlySearch() async throws {
        let store = try makeStore()
        let room = RoomID(uuid: UUID()), otherRoom = RoomID(uuid: UUID())
        let sender = UserID(uuid: UUID()), otherSender = UserID(uuid: UUID())
        let text = MessageID(uuid: UUID()), media = MessageID(uuid: UUID())
        let elsewhere = MessageID(uuid: UUID())
        try await applyRoomEvents(store, records: [
            acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: room, senderID: sender,
                messageID: text, roomSequence: 1, text: "hello", createdAtMilliseconds: 1_750_000_000_000),
            mediaRoomEvent(sourceEvent: UUID().uuidString, roomID: room, senderID: sender,
                messageID: media, roomSequence: 2, mediaID: UUID().uuidString, kind: "image"),
            acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: room, senderID: otherSender,
                messageID: .init(uuid: UUID()), roomSequence: 3, text: "other member", createdAtMilliseconds: 1_750_000_002_000),
            acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: otherRoom, senderID: sender,
                messageID: elsewhere, roomSequence: 1, text: "another room", createdAtMilliseconds: 1_750_000_003_000)
        ])
        try await store.messageSearch.rebuildMessageSearchIndex()
        let first = try await store.messageSearch.searchMessages(.init(query: "", scope: .room(room), senderUserID: sender, limit: 1))
        #expect(first.hits.map(\.messageID) == [media])
        let cursor = try #require(first.nextCursor)
        let second = try await store.messageSearch.searchMessages(.init(query: "", scope: .room(room), senderUserID: sender, limit: 1, cursor: cursor))
        #expect(second.hits.map(\.messageID) == [text])
        #expect(second.nextCursor == nil)
        await #expect(throws: V2MessageSearchError.cursorDoesNotMatchScope) {
            try await store.messageSearch.searchMessages(.init(query: "", scope: .room(room), senderUserID: otherSender, cursor: cursor))
        }
        let all = try await store.messageSearch.searchMessages(.init(query: "", scope: .sender(sender)))
        #expect(Set(all.hits.map(\.messageID)) == [text, media, elsewhere])
        await #expect(throws: V2MessageSearchError.emptyQuery) {
            try await store.messageSearch.searchMessages(.init(query: "", scope: .room(room)))
        }
    }

    @Test("personal snapshot rebuilds search from retained room-log messages and removes absent rooms")
    func snapshotCommitReplacesTheSearchIndex() async throws {
        let store = try makeStore()
        let oldRoomID = try RoomID("00000000-0000-0000-0000-000000000c01")
        let oldSenderID = try UserID("00000000-0000-0000-0000-000000000c02")
        let oldMessageID = try MessageID("00000000-0000-0000-0000-000000000c03")
        try await applyRoomEvents(store, records: [
            acceptedRoomEvent(sourceEvent: "00000000-0000-0000-0000-000000000c04", roomID: oldRoomID, senderID: oldSenderID, messageID: oldMessageID, roomSequence: 1, text: "快照前文本", createdAtMilliseconds: 1_750_000_000_000)
        ])
        try await store.messageSearch.rebuildMessageSearchIndex()

        let snapshotRoomID = try RoomID("00000000-0000-0000-0000-000000000c11")
        let snapshotSenderID = try UserID("00000000-0000-0000-0000-000000000c12")
        let snapshotMessageID = try MessageID("00000000-0000-0000-0000-000000000c13")
        try await applyRoomEvents(store, records: [
            acceptedRoomEvent(sourceEvent: "00000000-0000-0000-0000-000000000c14", roomID: snapshotRoomID,
                senderID: snapshotSenderID, messageID: snapshotMessageID, roomSequence: 7,
                text: "保留房间文本", createdAtMilliseconds: 1_750_000_100_000)
        ])
        try await store.messageSearch.rebuildMessageSearchIndex()
        #expect(try await store.messageSearch.searchMessages(.init(query: "文本", scope: .allMessages)).hits.count == 2)
        let reset = try V2ClientResetRequired(snapshotID: .init("message-search-snapshot"), generation: 2,
            baseSequence: 1, expiresAt: .distantFuture)
        let page = try V2SnapshotProjectionV3Page(items: [.init(
            key: .init(projectionKind: "room", entityKey: snapshotRoomID.rawValue),
            sourceEventID: .init(uuid: UUID()), sequence: 1,
            payload: JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed", "room_id": snapshotRoomID.rawValue, "title": "Search",
                "owner_user_id": snapshotSenderID.rawValue, "target_user_id": snapshotSenderID.rawValue,
                "action": "add", "membership_revision": 1, "capacity_class": "standard",
                "created_at_ms": 1_750_000_000_000, "server_created_at_ms": 1_750_000_000_000]))])
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
        #expect(try await store.messageSearch.searchMessages(.init(query: "快照前", scope: .allMessages)).hits.map(\.messageID) == [oldMessageID])
        try await store.activateAcknowledgedSnapshot(manifest)

        #expect(try await store.messageSearch.messageSearchIndexState() == .building)
        try await store.messageSearch.rebuildMessageSearchIndex()
        #expect(try await store.messageSearch.messageSearchIndexState() == .ready)
        #expect(try await store.messageSearch.searchMessages(.init(query: "快照前", scope: .allMessages)).hits.isEmpty)
        #expect(try await store.messageSearch.searchMessages(.init(query: "保留房间", scope: .room(snapshotRoomID))).hits.map(\.messageID) == [snapshotMessageID])
    }

    @Test("an unacknowledged search job survives restart and replaces stale text")
    func searchJobResumesAfterRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-message-search-restart-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let roomID = try RoomID("00000000-0000-0000-0000-000000000e01")
        let senderID = try UserID("00000000-0000-0000-0000-000000000e02")
        let messageID = try MessageID("00000000-0000-0000-0000-000000000e03")
        let first = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await applyRoomEvents(first, records: [
            acceptedRoomEvent(sourceEvent: "00000000-0000-0000-0000-000000000e11", roomID: roomID, senderID: senderID, messageID: messageID, roomSequence: 1, text: "初始文本", createdAtMilliseconds: 1_750_000_000_000)
        ])
        try await first.messageSearch.rebuildMessageSearchIndex()
        try await applyRoomEvents(first, records: [
            editedRecord(sequence: 2, sourceEvent: "00000000-0000-0000-0000-000000000e12", roomID: roomID, messageID: messageID, revision: 2, text: "恢复后的文本")
        ])

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        #expect(try await restarted.messageSearch.messageSearchIndexProgress().isCatchingUp)
        _ = try await restarted.messageSearch.processPendingMessageSearchIndexJobs()
        #expect(try await restarted.messageSearch.searchMessages(.init(query: "恢复后", scope: .room(roomID))).hits.map(\.messageID) == [messageID])
        #expect(try await restarted.messageSearch.searchMessages(.init(query: "初始文", scope: .room(roomID))).hits.isEmpty)
    }

    private func makeStore() throws -> GRDBV2LocalSyncStore {
        try .init(
            databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-message-search-\(UUID().uuidString).sqlite"),
            installationBinding: .init(value: UUID())
        )
    }

    func applyRoomEvents(_ store: GRDBV2LocalSyncStore, records: [V2ClientSyncRecord]) async throws {
        struct Scope: Decodable { let room_id: String }
        for record in records {
            let room = try RoomID(JSONDecoder().decode(Scope.self, from: record.payload).room_id)
            let event = try V2ClientGroupEvent(sourceEventID: record.sourceEventID, roomSequence: record.sequence,
                projectionKind: record.projectionKind, payload: record.payload)
            _ = try await store.applyGroupEventPage(.init(roomID: room, events: [event],
                nextRoomSequence: record.sequence, hasMore: false))
        }
    }

    func acceptedRoomEvent(sourceEvent: String, roomID: RoomID, senderID: UserID, messageID: MessageID, roomSequence: UInt64, text: String, createdAtMilliseconds: Int64) throws -> V2ClientSyncRecord {
        try .init(
            sequence: roomSequence,
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

    func editedRecord(sequence: UInt64, sourceEvent: String, roomID: RoomID, messageID: MessageID, revision: UInt64, text: String) throws -> V2ClientSyncRecord {
        try .init(
            sequence: sequence,
            sourceEventID: .init(sourceEvent),
            projectionKind: "message",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "message.edited",
                "room_sequence": sequence,
                "room_id": roomID.rawValue,
                "message_id": messageID.rawValue,
                "message_revision": revision,
                "text": text
            ])
        )
    }

    private func mediaRoomEvent(sourceEvent: String, roomID: RoomID, senderID: UserID, messageID: MessageID, roomSequence: UInt64, mediaID: String, kind: String) throws -> V2ClientSyncRecord {
        try .init(
            sequence: roomSequence,
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
                "server_created_at_ms": Int64(1_750_000_000_000 + Int64(roomSequence))
            ])
        )
    }

    func tombstoneRecord(sequence: UInt64, sourceEvent: String, roomID: RoomID, messageID: MessageID, revision: UInt64) throws -> V2ClientSyncRecord {
        try .init(
            sequence: sequence,
            sourceEventID: .init(sourceEvent),
            projectionKind: "message",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "message.withdrawn",
                "room_sequence": sequence,
                "room_id": roomID.rawValue,
                "message_id": messageID.rawValue,
                "message_revision": revision
            ])
        )
    }
}

extension V2MessageSearchTests {
    @Test("切换文本索引格式后按新代次重建，并将兼容字符命中映射回原文", arguments: [1, 2])
    func rebuildForSubstringFormat(previousVersion: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "V2.sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let room = RoomID(uuid: UUID())
        let legacy = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await applyRoomEvents(legacy, records: [acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: room,
            senderID: .init(uuid: UUID()), messageID: .init(uuid: UUID()), roomSequence: 1,
            text: "👩🏽‍💻 ＡＢＣ ﬃ", createdAtMilliseconds: 1_750_000_000_000)])
        let primary = await legacy.databasePool
        try await primary.write { db in
            try db.execute(sql: "UPDATE v2_message_search_state SET index_version = ?, state = 'ready'", arguments: [previousVersion])
        }
        let search = try #require(await legacy.messageSearchDatabasePool)
        try await search.write { db in
            try db.execute(sql: "DROP TABLE v2_message_char_fts")
            try db.execute(sql: "CREATE VIRTUAL TABLE v2_message_char_fts USING fts5(room_scope,sender_scope,unigrams,bigrams)")
        }
        try await legacy.close()

        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        #expect(try await store.messageSearch.messageSearchIndexState() == .building)
        await #expect(throws: V2MessageSearchError.indexUnavailable(.building)) {
            try await store.messageSearch.processPendingMessageSearchIndexJobs()
        }
        try await store.messageSearch.prepareMessageSearchIndex()
        for (query, original) in [("abc", "ＡＢＣ"), ("fi", "ﬃ"), ("👩🏽‍💻", "👩🏽‍💻")] {
            let page = try await store.messageSearch.searchMessages(.init(query: query, scope: .room(room)))
            let hit = try #require(page.hits.first)
            #expect(hit.matchRanges == [(hit.text as NSString).range(of: original)])
        }
        #expect(try await store.messageSearch.searchMessages(.init(query: "👩")).hits.isEmpty)
        try await store.close()
    }
}

extension V2MessageSearchTests {
    @Test("索引器排空启动积压，随后处理空闲时提交的消息并返回预览高亮")
    func committedWorkWakesIdleIndexer() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), sender = UserID(uuid: UUID())
        let body = "ＡＢＣ" + String(repeating: "间", count: 256) + "abc"
        func submit(_ sequence: UInt64) async throws {
            let record = try acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: room, senderID: sender,
                messageID: .init(uuid: UUID()), roomSequence: sequence, text: body, createdAtMilliseconds: 1_750_000_000_000)
            try await applyRoomEvents(store, records: [record])
        }
        try await store.messageSearch.prepareMessageSearchIndex()
        try await submit(1)
        await store.messageSearch.startIndexing()
        for expected in 1...2 {
            if expected == 2 {
                try await Task.sleep(for: .milliseconds(30))
                try await submit(2)
            }
            let deadline = ContinuousClock.now + .seconds(3)
            var page = try await store.messageSearch.searchMessages(.init(query: "abc", scope: .room(room), previewHighlights: true))
            while page.hits.count < expected && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
                page = try await store.messageSearch.searchMessages(.init(query: "abc", scope: .room(room), previewHighlights: true))
            }
            try #require(page.hits.count == expected)
            #expect(page.hits.allSatisfy { $0.matchRanges == [NSRange(location: 0, length: 3)] })
        }
        let full = try await store.messageSearch.searchMessages(.init(query: "abc", scope: .room(room)))
        #expect(full.hits.allSatisfy { $0.matchRanges.count == 2 })
        await store.messageSearch.stopIndexing()
        try await store.close()
    }
}
