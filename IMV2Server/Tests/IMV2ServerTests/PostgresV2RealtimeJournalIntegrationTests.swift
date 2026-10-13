import Foundation
import IMV2Core
import FluentKit
import SQLKit
import PostgresNIO
import NIOCore
import Testing
import IMV2ActorContracts
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure

@Suite("Durable partition journal behavior", .serialized)
struct PostgresV2RealtimeJournalIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func rolledBackMembershipDoesNotPublishTargetOrAdvanceDiscovery() async throws {
        try await withJournalDatabase { database, sql, schema in
            let room = UUID(), user = UUID()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES(\(bind: room),'source','standard')").run()
            enum Rollback: Error { case requested }
            await #expect(throws: Rollback.requested) {
                try await database.transaction { db in
                    let transaction = try #require(db as? any SQLDatabase)
                    try await transaction.raw("INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,role,joined_revision) VALUES(\(bind: room),\(bind: user),'member',1)").run()
                    throw Rollback.requested
                }
            }
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let partition = V2RealtimeTopicKey(kind: .userSync, id: user.uuidString.lowercased()).partitionID()
            let snapshot = try await store.userSnapshot(userIDs: [user], deviceIDs: [], partitionIDs: [partition])
            #expect(snapshot.users.first?.membershipDiscoveryVersion == 0)
            let lease = try await journalLease(store, partitionID: partition)
            let batch = try await store.publishPending(lease: lease, limit: 128)
            #expect(!batch.entries.contains { $0.topicKind == "userSync" && $0.topicID == user.uuidString.lowercased() })
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,role,joined_revision) VALUES(\(bind: room),\(bind: user),'member',1)").run()
            let committed = try await store.publishPending(lease: lease, limit: 128)
            let member = try #require(committed.entries.first { $0.topicKind == "userSync" && $0.topicID == user.uuidString.lowercased() })
            #expect(member.userControlVersion == 1 && member.membershipRoomID == room)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func membershipTargetColumnsAreRequiredForSourceReadiness() async throws {
        try await withJournalDatabase { database, sql, schema in
            try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
            for table in ["realtime_change_outbox", "realtime_change_journal"] {
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).\(unsafeRaw: table) DROP COLUMN membership_room_id").run()
                await #expect(throws: V2RealtimeJournalSchemaReadinessError.unavailableContract) {
                    try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
                }
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).\(unsafeRaw: table) ADD COLUMN membership_room_id uuid").run()
                try await V2RealtimeJournalSchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func copyAndMultipleStatementsKeepCoalescedHeadsAndIndependentControlRows() async throws {
        try await withJournalDatabase { database, sql, schema in
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let room = UUID(), user = UUID()
            let partition = V2RealtimeTopicKey(kind: .roomEvents, id: room.uuidString.lowercased()).partitionID()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES(\(bind: room),'source','standard')").run()
            let lease = try await journalLease(store, partitionID: partition)
            _ = try await store.publishPending(lease: lease, limit: 128)
            let initialHead = try #require(try await store.pendingRoomHeads(lease: lease, limit: 128).first)
            #expect(initialHead.roomSequence == 0)
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence=10 WHERE room_id=\(bind: room)").run()
            let postgres = try #require(database as? any PostgresDatabase)
            let rows = (1...10).map { "\(UUID().uuidString)\t\(room.uuidString)\t\($0)\ttest.copy\t{}\t0\t2026-01-01 00:00:00+00\n" }.joined()
            try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    try await connection.withTransaction(logger: sql.logger) { transaction in
                        // PostgresNIO quotes table as one identifier, so use a
                        // transaction-local search path for this owned schema.
                        _ = try await transaction.query("SET LOCAL search_path TO \(unescaped: schema)", logger: sql.logger)
                        try await transaction.copyFrom(table: "room_events",
                        columns: ["event_id","room_id","room_sequence","event_type","payload","committed_membership_revision","created_at"],
                        logger: sql.logger) { writer in try await writer.write(ByteBuffer(string: rows)) }
                    }
                }
            }.get()
            let copied = try #require(try await store.pendingRoomHeads(lease: lease, limit: 128).first)
            #expect(copied.roomSequence == 10 && copied.revision == initialHead.revision + 1)
            // Two distinct INSERT statements in one transaction each invalidate
            // once; transaction-level aggregation must never hide a writer.
            try await database.transaction { db in
                let tx = try #require(db as? any SQLDatabase)
                try await insertHeadEvent(tx, schema: schema, room: room, sequence: 11)
                try await insertHeadEvent(tx, schema: schema, room: room, sequence: 12)
            }
            let inserted = try #require(try await store.pendingRoomHeads(lease: lease, limit: 128).first)
            #expect(inserted.roomSequence == 12 && inserted.revision == copied.revision + 2)
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,role,joined_revision)
                VALUES(\(bind: room),\(bind: user),'member',1)
                """).run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_memberships SET left_revision=2 WHERE room_id=\(bind: room) AND user_id=\(bind: user)").run()
            struct Versions: Decodable { let version: Int64; let membership_discovery_version: Int64 }
            let versions = try #require(try await sql.raw("""
                SELECT version,membership_discovery_version FROM \(unsafeRaw: schema).realtime_control_versions
                WHERE topic_kind='userSync' AND topic_id=\(bind: user.uuidString.lowercased())
                """).first(decoding: Versions.self))
            #expect(versions.version == 2 && versions.membership_discovery_version == 2)
            struct Count: Decodable { let count: Int }
            let count = try #require(try await sql.raw("SELECT count(*)::integer AS count FROM \(unsafeRaw: schema).realtime_change_outbox WHERE topic_kind='userSync' AND topic_id=\(bind: user.uuidString.lowercased())").first(decoding: Count.self))
            #expect(count.count == 2)
            let userPartition = V2RealtimeTopicKey(kind: .userSync, id: user.uuidString.lowercased()).partitionID()
            let userLease = userPartition == partition ? lease : try await journalLease(store, partitionID: userPartition)
            let publishedMembers = try await store.publishPending(lease: userLease, limit: 128)
            let memberEntries = publishedMembers.entries.filter { $0.topicKind == "userSync" && $0.topicID == user.uuidString.lowercased() }
            #expect(memberEntries.count == 2)
            #expect(memberEntries.allSatisfy { $0.membershipRoomID == room && $0.changeKind == "membership.changed" })
            let replayedMembers = try await store.replay(partitionID: userPartition, after: 0, limit: 128)
            #expect(replayedMembers.entries.filter { $0.topicID == user.uuidString.lowercased() }.map(\.membershipRoomID) == [room, room])
            let updated = try #require(try await store.pendingRoomHeads(lease: lease, limit: 128).first)
            #expect(updated.roomControlVersion > inserted.roomControlVersion && updated.roomSequence == 12)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func physicalSourcesHaveIndependentLeasesIdentityAndMembershipUserFloors() async throws {
        try await withJournalDatabase { roomDB, roomSQL, roomSchema in
            try await withJournalDatabase { authDB, _, authSchema in
                let roomStore = try PostgresV2RealtimeChangeJournalStore(database: roomDB, schema: roomSchema)
                let authStore = try PostgresV2RealtimeChangeJournalStore(database: authDB, schema: authSchema)
                let room = UUID(), user = UUID()
                let partition = V2RealtimeTopicKey(kind: .userSync, id: user.uuidString.lowercased()).partitionID()
                let roomLease = try await journalLease(roomStore, partitionID: partition)
                #expect(try await authStore.currentPublisherLease(partitionID: partition) == nil)
                #expect(try await authStore.confirm([roomLease]).isEmpty)
                let authLease = try await journalLease(authStore, partitionID: partition)
                #expect(authLease.token != roomLease.token)
                #expect(try await roomStore.confirm([authLease]).isEmpty)
                #expect(try await roomStore.sourceIdentity() != (try await authStore.sourceIdentity()))
                try await roomSQL.raw("INSERT INTO \(unsafeRaw: roomSchema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES(\(bind: room),'source','standard')").run()
                try await roomSQL.raw("INSERT INTO \(unsafeRaw: roomSchema).room_memberships(room_id,user_id,role,joined_revision) VALUES(\(bind: room),\(bind: user),'member',1)").run()
                let membership = try await roomStore.userSnapshot(userIDs: [user], deviceIDs: [], partitionIDs: [partition])
                let authentication = try await authStore.userSnapshot(userIDs: [user], deviceIDs: [], partitionIDs: [partition])
                #expect(membership.users.first?.membershipDiscoveryVersion == 1)
                #expect(authentication.users.first?.membershipDiscoveryVersion == 0)
                let controls = try await roomStore.publishPending(lease: roomLease, limit: 128)
                #expect(controls.entries.contains { $0.topicKind == "userSync" && $0.topicID == user.uuidString.lowercased() })
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func statementBatchCoalescesOnceAndAntiEntropyReadsACKedAuthoritativeHead() async throws {
        try await withJournalDatabase { database, sql, schema in
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let room = UUID()
            let partition = V2RealtimeTopicKey(kind: .roomEvents, id: room.uuidString.lowercased()).partitionID()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES(\(bind: room),'source','standard')").run()
            let lease = try await journalLease(store, partitionID: partition)
            _ = try await store.publishPending(lease: lease, limit: 128)
            let initialHead = try #require(try await store.pendingRoomHeads(lease: lease, limit: 128).first)
            #expect(initialHead.roomSequence == 0)
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence=20 WHERE room_id=\(bind: room)").run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                SELECT gen_random_uuid(),\(bind: room),h,'test.batch','{}'::jsonb,0,clock_timestamp()
                FROM generate_series(1,20) h
                """).run()
            let head = try #require(try await store.pendingRoomHeads(lease: lease, limit: 128).first)
            #expect(head.roomSequence == 20 && head.revision == initialHead.revision + 1)
            try await store.acknowledgeRoomHeads(lease: lease, heads: [head])
            #expect(try await store.pendingRoomHeadPartitions(partitionIDs: [partition], limit: 256).isEmpty)
            let snapshot = try await store.roomHeadSnapshot(roomIDs: [room], partitionID: partition)
            let authoritative = try #require(snapshot.rooms.first)
            #expect(authoritative.exists && authoritative.roomSequence == 20)
            #expect(authoritative.ownerEpoch == head.ownerEpoch && authoritative.roomControlVersion == head.roomControlVersion)
            #expect(snapshot.identity == (try await store.sourceIdentity()))
            #expect(snapshot.cut.publishedThrough == 1)
            #expect(try await journalCount(sql, schema: schema, table: "realtime_change_journal") == 1)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func missingControlVersionOrGapFailsClosedWithoutAdvancingJournal() async throws {
        try await withJournalDatabase { database, sql, schema in
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let lease = try await journalLease(store, partitionID: 6)
            let source = UUID()
            try await enqueueJournalSource(sql, schema: schema, partition: 6, source: source, roomSequence: 1)
            try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_change_outbox SET room_control_version=NULL WHERE source_event_id=\(bind: source)").run()
            await #expect(throws: V2RealtimeJournalError.corruptPersistenceState) {
                _ = try await store.publishPending(lease: lease, limit: 128)
            }
            try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_change_outbox SET room_control_version=2 WHERE source_event_id=\(bind: source)").run()
            await #expect(throws: V2RealtimeJournalError.corruptPersistenceState) {
                _ = try await store.publishPending(lease: lease, limit: 128)
            }
            let replay = try await store.replay(partitionID: 6, after: 0, limit: 128)
            #expect(replay.publishedThrough == 0 && replay.entries.isEmpty)
            #expect(try await journalCount(sql, schema: schema, table: "realtime_change_outbox") == 1)
            #expect(try await journalCount(sql, schema: schema, table: "realtime_control_publication_floors") == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func roomHeadsCoalesceWithoutJournalCopiesAndStaleACKCannotClearNewDirtyHead() async throws {
        try await withJournalDatabase { database, sql, schema in
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let room = UUID()
            let partition = V2RealtimeTopicKey(kind: .roomEvents, id: room.uuidString.lowercased()).partitionID()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES(\(bind: room),'source','standard')").run()
            let lease = try await journalLease(store, partitionID: partition)
            let control = try await store.publishPending(lease: lease, limit: 128)
            #expect(control.entries.count == 1)
            let initialHead = try #require(try await store.pendingRoomHeads(lease: lease, limit: 128).first)
            #expect(initialHead.roomSequence == 0)
            for h in 1...3 {
                try await insertHeadEvent(sql, schema: schema, room: room, sequence: Int64(h))
            }
            #expect(try await store.pendingPartitions(partitionIDs: [partition], limit: 256).isEmpty)
            #expect(try await store.pendingRoomHeadPartitions(partitionIDs: [partition], limit: 256) == [partition])
            let older = try #require(try await store.pendingRoomHeads(lease: lease, limit: 128).first)
            #expect(older.roomSequence == 3 && older.revision == initialHead.revision + 3)
            #expect(try await journalCount(sql, schema: schema, table: "realtime_change_journal") == 1)
            #expect(try await journalCount(sql, schema: schema, table: "realtime_control_publication_floors") == 1)
            try await insertHeadEvent(sql, schema: schema, room: room, sequence: 4)
            try await store.acknowledgeRoomHeads(lease: lease, heads: [older])
            let newer = try #require(try await store.pendingRoomHeads(lease: lease, limit: 128).first)
            #expect(newer.roomSequence == 4 && newer.revision > older.revision)
            try await store.acknowledgeRoomHeads(lease: lease, heads: [newer])
            #expect(try await store.pendingRoomHeads(lease: lease, limit: 128).isEmpty)
            // A later transaction with an older business H remains observable,
            // but cannot move the authoritative high watermark backwards.
            try await insertHeadEvent(sql, schema: schema, room: room, sequence: 2, kind: "test.late-head")
            let late = try #require(try await store.pendingRoomHeads(lease: lease, limit: 128).first)
            #expect(late.roomSequence == 4 && late.revision > newer.revision)
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET owner_epoch=2 WHERE room_id=\(bind: room)").run()
            let changed = try #require(try await store.pendingRoomHeads(lease: lease, limit: 128).first)
            #expect(changed.ownerEpoch == 2 && changed.roomControlVersion > late.roomControlVersion)
            let nextControl = try await store.publishPending(lease: lease, limit: 128)
            #expect(nextControl.entries.map(\.sequence) == [2])
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func sourceIdentitySurvivesReinstallAndSnapshotProvesPendingControlVersionFloor() async throws {
        try await withJournalDatabase { database, sql, schema in
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let identity = try await store.sourceIdentity()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).realtime_journal_source_identity(singleton) VALUES(true) ON CONFLICT DO NOTHING").run()
            #expect(try await store.sourceIdentity() == identity)
            let room = UUID(), user = UUID(), missing = UUID()
            let partition = V2RealtimeTopicKey(kind: .roomEvents, id: room.uuidString.lowercased()).partitionID()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,membership_revision,room_sequence,owner_epoch)
                VALUES(\(bind: room),'source','standard',400,15,7)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision)
                VALUES(\(bind: room),\(bind: user),400)
                """).run()
            let keys = [V2RealtimeJournalViewerKey(roomID: room, userID: user)]
            let joined = try await store.projectionSnapshot(roomIDs: [room, missing], viewerKeys: keys,
                partitionIDs: [partition], minimumPublishedThrough: [:])
            #expect(joined.identity == identity && joined.cuts.first?.publishedThrough == 0)
            let joinedRoom = try #require(joined.rooms.first { $0.roomID == room })
            #expect(joinedRoom.exists && joinedRoom.ownerEpoch == 7 && joinedRoom.roomSequence == 15)
            #expect(joinedRoom.roomControlVersion > 0 && joinedRoom.roomControlVersion != 400)
            #expect(joined.rooms.first { $0.roomID == missing }?.exists == false)
            #expect(joined.viewers.first?.active == true && joined.viewers.first?.joinedRevision == 400)
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_memberships SET left_revision=400 WHERE room_id=\(bind: room) AND user_id=\(bind: user)").run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                VALUES(\(bind: UUID()),\(bind: room),15,'test.head','{}'::jsonb,400,clock_timestamp())
                """).run()
            let revoked = try await store.projectionSnapshot(roomIDs: [room], viewerKeys: keys,
                partitionIDs: [partition], minimumPublishedThrough: [:])
            let floor = try #require(revoked.rooms.first).roomControlVersion
            #expect(revoked.cuts.first?.publishedThrough == 0 && revoked.viewers.first?.active == false)
            #expect(floor > joinedRoom.roomControlVersion)
            let lease = try await journalLease(store, partitionID: partition)
            let published = try await store.publishPending(lease: lease, limit: 128)
            let heads = try await store.pendingRoomHeads(lease: lease, limit: 128)
            let head = try #require(heads.first)
            #expect(head.ownerEpoch == 7 && head.roomControlVersion == floor && head.roomSequence == 15)
            #expect(published.entries.allSatisfy { $0.changeKind != "test.head" })
            // All earlier controls are at/below the installed floor. Replaying
            // them after this current-state snapshot cannot resurrect the grant.
            #expect(published.entries.filter { $0.topicKind == "roomEvents" }.allSatisfy {
                ($0.roomControlVersion ?? Int64.max) <= floor
            })
            let after = try await store.projectionSnapshot(roomIDs: [room], viewerKeys: keys,
                partitionIDs: [partition], minimumPublishedThrough: [partition: published.publishedThrough])
            #expect(after.cuts.first?.publishedThrough == published.publishedThrough && after.viewers.first?.active == false)
            await #expect(throws: V2RealtimeJournalError.corruptPersistenceState) {
                _ = try await store.projectionSnapshot(roomIDs: [room], viewerKeys: keys,
                    partitionIDs: [partition], minimumPublishedThrough: [partition: published.publishedThrough + 1])
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func batchesAreAtomicContinuousAndReplayDetectsTrimmedCheckpoints() async throws {
        try await withJournalDatabase { database, sql, schema in
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let lease = try await journalLease(store, partitionID: 9)
            let sourceIDs = [UUID(), UUID(), UUID()]
            for (index, source) in sourceIDs.enumerated() {
                try await enqueueJournalSource(sql, schema: schema, partition: 9, source: source,
                    roomSequence: Int64(index + 10), controlVersion: Int64(index + 1), createdAt: Date(timeIntervalSince1970: Double(index)))
            }
            #expect(try await store.pendingPartitions(partitionIDs: [9, 10], limit: 256) == [9])
            let first = try await store.publishPending(lease: lease, limit: 2)
            #expect(first.entries.map(\.sequence) == [1, 2])
            #expect(first.entries.map(\.sourceEventID) == Array(sourceIDs.prefix(2)))
            #expect(first.publishedThrough == 2 && first.trimmedThrough == 0)
            #expect(try await journalCount(sql, schema: schema, table: "realtime_change_outbox") == 1)
            #expect(try await journalCount(sql, schema: schema, table: "realtime_control_publication_floors") == 1)
            let second = try await store.publishPending(lease: lease, limit: 2)
            #expect(second.entries.map(\.sequence) == [3])
            #expect(second.publishedThrough == 3)
            let page = try await store.replay(partitionID: 9, after: 0, limit: 1)
            #expect(page.entries.map(\.sequence) == [1] && page.publishedThrough == 3)
            let next = try await store.replay(partitionID: 9, after: 1, limit: 2)
            #expect(next.entries.map(\.sequence) == [2, 3])
            try await store.trim(lease: lease, through: 2)
            let gap = try await store.replay(partitionID: 9, after: 1, limit: 128)
            #expect(gap.requiresSnapshot && gap.entries.isEmpty && gap.trimmedThrough == 2)
            let retained = try await store.replay(partitionID: 9, after: 2, limit: 128)
            #expect(!retained.requiresSnapshot && retained.entries.map(\.sequence) == [3])
            let future = try await store.replay(partitionID: 9, after: 4, limit: 128)
            #expect(future.requiresSnapshot && future.entries.isEmpty)
            // A retired journal payload must not retire source deduplication.
            try await enqueueJournalSource(sql, schema: schema, partition: 9, source: sourceIDs[0], roomSequence: 10, controlVersion: 1)
            let duplicate = try await store.publishPending(lease: lease, limit: 128)
            #expect(duplicate.entries.isEmpty && duplicate.publishedThrough == 3)
            #expect(try await journalCount(sql, schema: schema, table: "realtime_change_outbox") == 0)
            #expect(try await journalCount(sql, schema: schema, table: "realtime_control_publication_floors") == 1)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func appendFailureRollsBackCounterSourceMarkingAndReceipts() async throws {
        try await withJournalDatabase { database, sql, schema in
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let lease = try await journalLease(store, partitionID: 7)
            try await enqueueJournalSource(sql, schema: schema, partition: 7, source: UUID(), roomSequence: 1)
            try await enqueueJournalSource(sql, schema: schema, partition: 7, source: UUID(), roomSequence: 999, controlVersion: 2)
            try await sql.raw("""
                CREATE FUNCTION \(unsafeRaw: schema).reject_journal_test_append() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN IF NEW.room_sequence=999 THEN RAISE EXCEPTION 'journal test append failure'; END IF; RETURN NEW; END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER reject_journal_test_append BEFORE INSERT ON \(unsafeRaw: schema).realtime_change_journal
                FOR EACH ROW EXECUTE FUNCTION \(unsafeRaw: schema).reject_journal_test_append()
                """).run()
            await #expect(throws: (any Error).self) { _ = try await store.publishPending(lease: lease, limit: 128) }
            let before = try await store.replay(partitionID: 7, after: 0, limit: 128)
            #expect(before.publishedThrough == 0 && before.entries.isEmpty)
            #expect(try await journalCount(sql, schema: schema, table: "realtime_change_outbox") == 2)
            #expect(try await journalCount(sql, schema: schema, table: "realtime_control_publication_floors") == 0)
            try await sql.raw("DROP TRIGGER reject_journal_test_append ON \(unsafeRaw: schema).realtime_change_journal").run()
            let committed = try await store.publishPending(lease: lease, limit: 128)
            #expect(committed.entries.map(\.sequence) == [1, 2] && committed.publishedThrough == 2)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func earlierAllocatedSourceCommittedLaterIsPublishedAfterVisibleSource() async throws {
        try await withJournalDatabase { database, sql, schema in
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let lease = try await journalLease(store, partitionID: 3)
            let lateCommit = UUID(), earlyCommit = UUID()
            // Keep the earlier source transaction open. Other pool connections
            // commit and publish another source while this source is invisible.
            let first = try await database.transaction { transaction in
                let transactionSQL = try #require(transaction as? any SQLDatabase)
                try await enqueueJournalSource(transactionSQL, schema: schema, partition: 3,
                    source: lateCommit, roomSequence: 1, createdAt: Date(timeIntervalSince1970: 1))
                try await enqueueJournalSource(sql, schema: schema, partition: 3,
                    source: earlyCommit, roomSequence: 2, topicID: "other-control-topic", createdAt: Date(timeIntervalSince1970: 2))
                return try await store.publishPending(lease: lease, limit: 128)
            }
            #expect(first.entries.map(\.sourceEventID) == [earlyCommit])
            #expect(first.entries.map(\.sequence) == [1])
            let second = try await store.publishPending(lease: lease, limit: 128)
            #expect(second.entries.map(\.sourceEventID) == [lateCommit])
            #expect(second.entries.map(\.sequence) == [2] && second.publishedThrough == 2)
            let complete = try await store.replay(partitionID: 3, after: 0, limit: 128)
            #expect(complete.entries.map(\.sourceEventID) == [earlyCommit, lateCommit])
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func sqlPartitionHashMatchesWireHashForEveryTopicKindAndLengthEncoding() async throws {
        try await withJournalDatabase { _, sql, schema in
            for kind in V2RealtimeTopicKind.allCases {
                for id in ["00000000-0000-0000-0000-000000000001", "room:42", "用户/房间", String(repeating: "x", count: 300)] {
                    let row = try #require(try await sql.raw("SELECT \(unsafeRaw: schema).realtime_topic_partition(\(bind: kind.rawValue),\(bind: id))::bigint AS value")
                        .first(decoding: JournalScalar.self))
                    #expect(row.value == Int64(V2RealtimeTopicKey(kind: kind, id: id).partitionID()))
                }
            }
        }
    }
}

private struct JournalScalar: Decodable { let value: Int64 }
private func journalCount(_ sql: any SQLDatabase, schema: String, table: String) async throws -> Int64 {
    try #require(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).\(unsafeRaw: table)")
        .first(decoding: JournalScalar.self)).value
}
private func journalLease(_ store: PostgresV2RealtimeChangeJournalStore, partitionID: Int) async throws -> V2RealtimePartitionLease {
    let identity = V2GatewayRealtimeIdentity(nodeID: "journal-test", serviceID: "publisher", incarnationID: UUID())
    return try #require(try await store.claim(partitionIDs: [partitionID], identity: identity,
        token: UUID(), leaseDuration: 30).first)
}
private func enqueueJournalSource(_ sql: any SQLDatabase, schema: String, partition: Int, source: UUID,
                                  roomSequence: Int64, controlVersion: Int64 = 1, topicID: String = "journal-test-room", createdAt: Date = Date()) async throws {
    try await sql.raw("""
        INSERT INTO \(unsafeRaw: schema).realtime_change_outbox
        (source_event_id,partition_id,topic_kind,topic_id,change_kind,room_sequence,room_control_version,created_at)
        VALUES(\(bind: source),\(bind: partition),'roomEvents',\(bind: topicID),'room.authorization.changed',\(bind: roomSequence),\(bind: controlVersion),\(bind: createdAt))
        """).run()
}
private func withJournalDatabase(_ operation: (any Database, any SQLDatabase, String) async throws -> Void) async throws {
    try await withUserEventDatabase { database, sql, schema in
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "IMV2/sql/realtime-change-journal.sql"), encoding: .utf8)
            .replacingOccurrences(of: "im_v2", with: schema)
        for statement in postgresStatements(in: source) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
            try await sql.raw("\(unsafeRaw: statement)").run()
        }
        try await operation(database, sql, schema)
    }
}

private func insertHeadEvent(_ sql: any SQLDatabase, schema: String, room: UUID, sequence: Int64,
                             kind: String = "test.head") async throws {
    try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence=greatest(room_sequence,\(bind: sequence)) WHERE room_id=\(bind: room)").run()
    try await sql.raw("""
        INSERT INTO \(unsafeRaw: schema).room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
        VALUES(\(bind: UUID()),\(bind: room),\(bind: sequence),\(bind: kind),'{}'::jsonb,0,clock_timestamp())
        """).run()
}
