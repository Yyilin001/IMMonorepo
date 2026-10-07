import Foundation
import FluentKit
import SQLKit
import Testing
import IMV2ActorContracts
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure

@Suite("Authoritative user floors and durable gateway responsibility", .serialized)
struct PostgresV2RealtimeJournalConsumerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func userSnapshotIsCompleteAndDeviceFloorDoesNotFollowOtherDevicesOrMembership() async throws {
        try await withConsumerDatabase { database, sql, schema in
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let user = UUID(), first = UUID(), second = UUID(), missing = UUID(), room = UUID()
            let expiry = Date().addingTimeInterval(90)
            for device in [first,second] {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).auth_devices(user_id,device_id,created_at,last_active_at,session_expires_at)
                    VALUES(\(bind: user),\(bind: device),clock_timestamp(),clock_timestamp(),\(bind: expiry))
                    """).run()
            }
            let partition = V2RealtimeTopicKey(kind: .userSync, id: user.uuidString.lowercased()).partitionID()
            let keys = [first,second,missing].map { V2RealtimeJournalDeviceKey(userID: user, deviceID: $0) }
            let before = try await store.userSnapshot(userIDs: [user],deviceIDs: keys,partitionIDs: [partition],minimumPublishedThrough: [:])
            #expect(before.requestedDeviceKeys.count==3 && before.devices.count==3 && before.users.count==1)
            #expect(before.devices.first { $0.deviceID==missing }?.latestChangeVersion==0)
            let secondFloor = try #require(before.devices.first { $0.deviceID==second }).latestChangeVersion
            try await sql.raw("UPDATE \(unsafeRaw: schema).auth_devices SET revoked_at=clock_timestamp() WHERE user_id=\(bind: user) AND device_id=\(bind: first)").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,membership_revision) VALUES(\(bind: room),'source','standard',1)").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision) VALUES(\(bind: room),\(bind: user),1)").run()
            let after = try await store.userSnapshot(userIDs: [user],deviceIDs: keys,partitionIDs: [partition],minimumPublishedThrough: [:])
            let changed = try #require(after.devices.first { $0.deviceID==first })
            let unchanged = try #require(after.devices.first { $0.deviceID==second })
            #expect(changed.latestChangeVersion>secondFloor)
            #expect(unchanged.latestChangeVersion==secondFloor)
            #expect(after.users.first?.membershipDiscoveryVersion==after.users.first?.controlVersion)
            #expect((after.users.first?.sessionControlVersion ?? 0)<(after.users.first?.controlVersion ?? 0))
            #expect(after.cuts.first?.publishedThrough==0) // State can lead pending publication without inventing grants.
            // Make both credential relation names unavailable. A control baseline
            // must still work using the committed version feed alone.
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).auth_devices RENAME TO unavailable_auth_devices").run()
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).device_refresh_sessions RENAME TO unavailable_refresh_sessions").run()
            let controlsOnly = try await store.userSnapshot(userIDs: [user], deviceIDs: keys,
                partitionIDs: [partition], minimumPublishedThrough: [:])
            #expect(controlsOnly.devices == after.devices && controlsOnly.users == after.users)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func handoffSurvivesRestartAndOldConsumerACKCannotDeleteNewerCoalescedH() async throws {
        try await withConsumerDatabase { database, sql, schema in
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let (room,partition,lease) = try await consumerRoom(store,sql: sql,schema: schema)
            let registration = consumerRegistration(partition: partition,room: room)
            try await store.registerConsumer(lease: lease,registration: registration)
            let control = try await store.publishPending(lease: lease,limit: 128)
            try await consumerHead(sql,schema: schema,room: room,h: 1)
            let firstHeads = try await store.pendingRoomHeads(lease: lease,limit: 128)
            try await store.handoffToConsumers(lease: lease,throughControlSequence: control.publishedThrough,heads: firstHeads)
            #expect(try await store.pendingRoomHeads(lease: lease,limit: 128).isEmpty)
            #expect(try await store.pendingConsumerPartitions(partitionIDs: [partition],limit: 256)==[partition])
            let restarted = try PostgresV2RealtimeChangeJournalStore(database: database,schema: schema)
            let first = try await restarted.consumerBatch(lease: lease,consumer: registration.key,limit: 128)
            #expect(first.controlCursor==0 && first.journal.entries.count==1 && first.heads.first?.roomSequence==1)
            #expect(try await restarted.acknowledgeConsumer(lease: lease,consumer: registration.key,
                expectedControlCursor: 0,appliedThrough: control.publishedThrough,heads: []))
            try await consumerHead(sql,schema: schema,room: room,h: 2)
            let secondHeads = try await store.pendingRoomHeads(lease: lease,limit: 128)
            try await store.handoffToConsumers(lease: lease,throughControlSequence: control.publishedThrough,heads: secondHeads)
            #expect(try await restarted.acknowledgeConsumer(lease: lease,consumer: registration.key,
                expectedControlCursor: control.publishedThrough,appliedThrough: control.publishedThrough,heads: first.heads))
            let newer = try await restarted.consumerBatch(lease: lease,consumer: registration.key,limit: 128)
            #expect(newer.heads.first?.roomSequence==2)
            #expect(try await restarted.acknowledgeConsumer(lease: lease,consumer: registration.key,
                expectedControlCursor: control.publishedThrough,appliedThrough: control.publishedThrough,heads: newer.heads))
            // Renewing an exact registration must not re-seed already ACKed H.
            try await store.registerConsumer(lease: lease,registration: registration)
            #expect(try await store.consumerBatch(lease: lease,consumer: registration.key,limit: 128).heads.isEmpty)
            #expect(try await store.pendingConsumerPartitions(partitionIDs: [partition],limit: 256).isEmpty)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func trimWaitsForEveryConsumerAndOnlyExactExpiredCoverageMayRetire() async throws {
        try await withConsumerDatabase { database, sql, schema in
            let store = try PostgresV2RealtimeChangeJournalStore(database: database,schema: schema)
            let (room,partition,lease) = try await consumerRoom(store,sql: sql,schema: schema)
            let first = consumerRegistration(partition: partition,room: room)
            let second = consumerRegistration(partition: partition,room: room)
            try await store.registerConsumer(lease: lease,registration: first)
            try await store.registerConsumer(lease: lease,registration: second)
            let control = try await store.publishPending(lease: lease,limit: 128)
            try await store.handoffToConsumers(lease: lease,throughControlSequence: control.publishedThrough,heads: [])
            #expect(try await store.acknowledgeConsumer(lease: lease,consumer: first.key,expectedControlCursor: 0,
                appliedThrough: control.publishedThrough,heads: []))
            await #expect(throws: V2RealtimeJournalError.invalidInput) { try await store.trim(lease: lease,through: 1) }
            #expect(try await store.retireExpiredConsumer(lease: lease,consumer: second.key,
                expectedRoutingEpoch: second.routingEpoch,expectedRoutingToken: second.routingToken,
                expectedCoverageExpiresAt: second.coverageExpiresAt)==false)
            let expired = Date().addingTimeInterval(-1)
            try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_journal_consumers SET coverage_expires_at=\(bind: expired) WHERE partition_id=\(bind: partition) AND gateway_incarnation=\(bind: second.key.gateway.incarnationID)").run()
            // Expiry alone still cannot remove its trimming responsibility.
            await #expect(throws: V2RealtimeJournalError.invalidInput) { try await store.trim(lease: lease,through: 1) }
            #expect(try await store.retireExpiredConsumer(lease: lease,consumer: second.key,
                expectedRoutingEpoch: second.routingEpoch,expectedRoutingToken: UUID(),expectedCoverageExpiresAt: expired)==false)
            #expect(try await store.retireExpiredConsumer(lease: lease,consumer: second.key,
                expectedRoutingEpoch: second.routingEpoch,expectedRoutingToken: second.routingToken,expectedCoverageExpiresAt: expired))
            try await store.trim(lease: lease,through: 1)
            let replacementKey = V2RealtimeJournalConsumerKey(gateway: first.key.gateway,sessionID: UUID(),sessionRevision: 1)
            let replacement = V2RealtimeJournalConsumerRegistration(key: replacementKey,sessionGeneration: 2,
                partitionID: partition,roomIDs: [room],userIDs: [],routingEpoch: 2,routingToken: UUID(),
                coverageExpiresAt: Date().addingTimeInterval(60))
            try await store.registerConsumer(lease: lease,registration: replacement)
            #expect(try await store.acknowledgeConsumer(lease: lease,consumer: first.key,
                expectedControlCursor: 1,appliedThrough: 1,heads: [])==false)
            let fresh = try await store.consumerBatch(lease: lease,consumer: replacementKey,limit: 128)
            #expect(fresh.controlCursor==0 && fresh.journal.requiresSnapshot)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func failedHandoffRollsBackOfferAndSourceDirtyACK() async throws {
        try await withConsumerDatabase { database, sql, schema in
            let store = try PostgresV2RealtimeChangeJournalStore(database: database,schema: schema)
            let (room,partition,lease) = try await consumerRoom(store,sql: sql,schema: schema)
            let registration = consumerRegistration(partition: partition,room: room)
            try await store.registerConsumer(lease: lease,registration: registration)
            // Registration may seed an existing room head. Rollback must
            // preserve that exact baseline rather than assume an empty inbox.
            let baseline = try await store.consumerBatch(lease: lease,consumer: registration.key,limit: 128)
            let control = try await store.publishPending(lease: lease,limit: 128)
            try await consumerHead(sql,schema: schema,room: room,h: 1)
            let heads = try await store.pendingRoomHeads(lease: lease,limit: 128)
            try await sql.raw("CREATE FUNCTION \(unsafeRaw: schema).fail_consumer_test_handoff() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test consumer handoff failure'; END $$").run()
            try await sql.raw("CREATE TRIGGER fail_consumer_test_handoff BEFORE INSERT ON \(unsafeRaw: schema).realtime_journal_consumer_heads FOR EACH ROW EXECUTE FUNCTION \(unsafeRaw: schema).fail_consumer_test_handoff()").run()
            await #expect(throws: (any Error).self) {
                try await store.handoffToConsumers(lease: lease,throughControlSequence: control.publishedThrough,heads: heads)
            }
            #expect(try await store.pendingRoomHeads(lease: lease,limit: 128)==heads)
            let retained = try await store.consumerBatch(lease: lease,consumer: registration.key,limit: 128)
            #expect(retained.offeredThrough == baseline.offeredThrough)
            #expect(retained.heads == baseline.heads)
        }
    }
}

private func consumerRegistration(partition: Int,room: UUID) -> V2RealtimeJournalConsumerRegistration {
    .init(key: .init(gateway: .init(nodeID: "gateway-test",serviceID: "gateway",incarnationID: UUID()),
                    sessionID: UUID(),sessionRevision: 7),sessionGeneration: 1,partitionID: partition,
          roomIDs: [room],userIDs: [],routingEpoch: 1,routingToken: UUID(),coverageExpiresAt: Date().addingTimeInterval(60))
}
private func consumerRoom(_ store: PostgresV2RealtimeChangeJournalStore,sql: any SQLDatabase,schema: String)
    async throws -> (UUID,Int,V2RealtimePartitionLease) {
    let room = UUID(), partition = V2RealtimeTopicKey(kind: .roomEvents,id: room.uuidString.lowercased()).partitionID()
    try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES(\(bind: room),'source','standard')").run()
    let identity = V2GatewayRealtimeIdentity(nodeID: "source-test",serviceID: "publisher",incarnationID: UUID())
    let lease = try #require(try await store.claim(partitionIDs: [partition],identity: identity,token: UUID(),leaseDuration: 30).first)
    return (room,partition,lease)
}
private func consumerHead(_ sql: any SQLDatabase,schema: String,room: UUID,h: Int64) async throws {
    try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence=\(bind: h) WHERE room_id=\(bind: room)").run()
    try await sql.raw("""
        INSERT INTO \(unsafeRaw: schema).room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
        VALUES(\(bind: UUID()),\(bind: room),\(bind: h),'test.consumer-head','{}'::jsonb,0,clock_timestamp())
        """).run()
}
private func withConsumerDatabase(_ operation: (any Database,any SQLDatabase,String) async throws -> Void) async throws {
    try await withUserEventDatabase { database,sql,schema in
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "IMV2/sql/realtime-change-journal.sql"),encoding: .utf8)
            .replacingOccurrences(of: "im_v2",with: schema)
        for statement in postgresStatements(in: source) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
            try await sql.raw("\(unsafeRaw: statement)").run()
        }
        try await operation(database,sql,schema)
    }
}
