import Foundation
import SQLKit
import FluentKit
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication
@testable import IMV2ServerInfrastructure

@Suite("Committed room subscription source", .serialized)
struct PostgresV2RoomSubscriptionSourceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func largeGroupSnapshotIncludesEveryTrackedOnlineMember() async throws {
        try await withSubscriptionSourceDatabase { database, sql, schema in
            let room = RoomID(uuid: UUID())
            let users = (0..<V2GroupCapacityPolicy.largeMaximumMembers).map { _ in UUID() }
            let tracked = Set(users.map { UserID(uuid: $0) })
            let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,room_kind,capacity_class) VALUES(\(bind: room.uuidValue!),'source','standard','group','large')").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision) SELECT \(bind: room.uuidValue!),user_id,0 FROM unnest(\(bind: users)::uuid[]) members(user_id)").run()
            try await insertSubscriptionLease(sql: sql, schema: schema, activation: activation)
            let source = try PostgresV2RoomSubscriptionSource(database: database, activation: activation, schema: schema)
            let snapshot = try await source.snapshot(roomID: room, owner: activation.owner, trackedUserIDs: tracked)
            #expect(snapshot.members.count == users.count)
            #expect(Set(snapshot.members.map(\.userID)) == tracked)
            #expect(snapshot.members.allSatisfy { $0.authorized && $0.memberRevision == 0 })
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func retirementDuringReadCutIsRejectedByFreshProof() async throws {
        try await withSubscriptionSourceDatabase { database, sql, schema in
            let room = RoomID(uuid: UUID())
            let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES(\(bind: room.uuidValue!),'source','standard')").run()
            try await insertSubscriptionLease(sql: sql, schema: schema, activation: activation)
            let source = try PostgresV2RoomSubscriptionSource(database: database, activation: activation, schema: schema)
            let cut = SubscriptionReadGate(), resume = SubscriptionReadGate()
            let reader = Task {
                try await source.withLease { tx in
                    await cut.signal(); await resume.wait()
                    // The RR cut still sees the predecessor, but that cannot
                    // establish fresh authority after a committed retirement.
                    let rows = try await tx.raw("SELECT host_id FROM \(unsafeRaw: schema).room_activation_leases WHERE room_id=\(bind: room.uuidValue!)").all()
                    return rows.count
                }
            }
            await cut.wait()
            do {
                try await sql.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET host_id=NULL,host_incarnation_id=NULL,expires_at=NULL WHERE room_id=\(bind: room.uuidValue!)").run()
                await resume.signal()
                await #expect(throws: V2RoomActivationLeaseError.activationChanged) { try await reader.value }
            } catch {
                await resume.signal(); _ = try? await reader.value; throw error
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func snapshotAndPageDoNotWaitForRoomWriteFence() async throws {
        try await withSubscriptionSourceDatabase { database, sql, schema in
            let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
            let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES(\(bind: room.uuidValue!),'source','standard')").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision) VALUES(\(bind: room.uuidValue!),\(bind: user.uuidValue!),0)").run()
            try await insertSubscriptionLease(sql: sql, schema: schema, activation: activation)
            let source = try PostgresV2RoomSubscriptionSource(database: database, activation: activation, schema: schema)
            let locked = SubscriptionReadGate(), release = SubscriptionReadGate()
            let writer = Task {
                try await database.transaction { transaction in
                    let tx = try #require(transaction as? any SQLDatabase)
                    try await v2RequireRoomActivation(token: activation, sql: tx, schema: schema)
                    // Change both authorization and head while retaining the
                    // write fence: readers must see both old committed values.
                    try await tx.raw("UPDATE \(unsafeRaw: schema).room_memberships SET left_revision=1 WHERE room_id=\(bind: room.uuidValue!)").run()
                    try await tx.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence=1,membership_revision=1 WHERE room_id=\(bind: room.uuidValue!)").run()
                    await locked.signal(); await release.wait()
                }
            }
            await locked.wait()
            do {
                let snapshot = try await source.snapshot(roomID: room, owner: activation.owner, trackedUserIDs: [user])
                #expect(snapshot.highWatermark == 0 && snapshot.membershipRevision == 0)
                #expect(snapshot.members.first?.authorized == true)
                let page = try await source.read(roomID: room, owner: activation.owner, afterRoomSequence: 0, trackedUserIDs: [user], limit: 64)
                #expect(page.highWatermark == 0 && page.records.isEmpty)

                await release.signal(); try await writer.value
            } catch {
                await release.signal(); _ = try? await writer.value; throw error
            }
            let updated = try await source.snapshot(roomID: room, owner: activation.owner, trackedUserIDs: [user])
            #expect(updated.highWatermark == 1 && updated.membershipRevision == 1)
            #expect(updated.members.first?.authorized == false)
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET activation_epoch=activation_epoch+1 WHERE room_id=\(bind: room.uuidValue!)").run()

            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                try await source.read(roomID: room, owner: activation.owner, afterRoomSequence: 1, trackedUserIDs: [user], limit: 64)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func ordinaryMessageQueryDoesNotExecutePerViewerMembershipJoins() async throws {
        try await withSubscriptionSourceDatabase { database, sql, schema in
            let room = UUID(), users = (0..<32).map { _ in UUID() }
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,room_sequence) VALUES(\(bind: room),'source','standard',32)").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision) SELECT \(bind: room),user_id,0 FROM unnest(\(bind: users)::uuid[]) users(user_id)").run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                SELECT gen_random_uuid(),\(bind: room),sequence,'message.accepted',
                    jsonb_build_object('event_type','message.accepted','room_id',\(bind: room.uuidString),'room_sequence',sequence),0,now()
                FROM generate_series(1,32) sequence
                """).run()
            let activation = try roomSubscriptionFixtureActivation(roomID: RoomID(uuid: room), ownerEpoch: 0)
            let source = try PostgresV2RoomSubscriptionSource(database: database, activation: activation, schema: schema)
            let query = source.readQuery(room: room, users: users, after: 0, limit: 64)
            let plan = try await sql.raw("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) \(query)").all()
                .map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
            let membershipScans = plan.split(separator: "\n").filter {
                $0.contains(" on room_memberships ") || $0.contains(" on \(schema).room_memberships ")
            }
            #expect(plan.contains("actual time"))
            // The production query contains control-only/historical branches,
            // but PostgreSQL must never execute their table scans for an
            // ordinary-message page, regardless of the 32 tracked viewers.
            #expect(membershipScans.allSatisfy { $0.contains("never executed") })
            try await insertSubscriptionLease(sql: sql, schema: schema, activation: activation)
            let page = try await source.read(roomID: RoomID(uuid: room), owner: try .init(shardID: "source", epoch: 0),
                afterRoomSequence: 0, trackedUserIDs: Set(users.map { UserID(uuid: $0) }), limit: 64)
            #expect(page.records.count == 32)
            #expect(page.records.allSatisfy { $0.membershipControl == nil && $0.recipientPolicy == .currentAuthorized })
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func historicalControlsCompactMessagesAndOwnerFence() async throws {
        try await withSubscriptionSourceDatabase { database, sql, schema in
            let room = UUID(), user = UUID(), other = UUID()
            let roomID = RoomID(uuid: room), userID = UserID(uuid: user), otherID = UserID(uuid: other)
            let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
            let activation = try roomSubscriptionFixtureActivation(roomID: RoomID(uuid: room), ownerEpoch: 0)
            let source = try PostgresV2RoomSubscriptionSource(database: database, activation: activation, schema: schema)
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES(\(bind: room),'source','standard')").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision) VALUES(\(bind: room),\(bind: user),0),(\(bind: room),\(bind: other),0)").run()
            try await insertSubscriptionLease(sql: sql, schema: schema, activation: activation)
            let tracked: Set<UserID> = [userID, otherID]
            let snapshot = try await source.snapshot(roomID: roomID, owner: owner, trackedUserIDs: tracked)
            #expect(snapshot.highWatermark == 0)

            #expect(snapshot.members.allSatisfy { $0.authorized && $0.memberRevision == 0 })
            // Commit remove/re-add/role change and their room-sequence facts
            // atomically. Reading the final memberships cannot replace these
            // intervening historical controls.
            try await database.transaction { transaction in
                let tx = try #require(transaction as? any SQLDatabase)
                try await tx.raw("UPDATE \(unsafeRaw: schema).room_memberships SET left_revision=1 WHERE room_id=\(bind: room) AND user_id=\(bind: user)").run()
                try await tx.raw("INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision,left_revision) VALUES(\(bind: room),\(bind: user),2,3),(\(bind: room),\(bind: user),3,NULL)").run()
                try await tx.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                    VALUES
                      (\(bind: UUID()),\(bind: room),1,'member.muted',jsonb_build_object('event_type','member.muted'),0,now()),
                      (\(bind: UUID()),\(bind: room),2,'membership_changed',jsonb_build_object('event_type','membership_changed','room_id',\(bind: room.uuidString),'target_user_id',\(bind: user.uuidString),'action','remove','membership_revision',1),1,now()),
                      (\(bind: UUID()),\(bind: room),3,'membership_changed',jsonb_build_object('event_type','membership_changed','room_id',\(bind: room.uuidString),'target_user_id',\(bind: user.uuidString),'action','add','membership_revision',2),2,now()),
                      (\(bind: UUID()),\(bind: room),4,'group.member_role_changed',jsonb_build_object('event_type','group.member_role_changed','room_id',\(bind: room.uuidString),'target_user_id',\(bind: user.uuidString),'membership_revision',3),2,now())
                    """).run()
                try await tx.raw("""
                    INSERT INTO \(unsafeRaw: schema).messages(message_id,room_id,room_sequence,timeline_sequence,sender_user_id,client_message_id,text_body,created_at,accepted_event_id,accepted_event_storage,accepted_membership_revision)
                    VALUES(\(bind: UUID()),\(bind: room),5,5,\(bind: other),\(bind: UUID()),'compact body',now(),\(bind: UUID()),'message_row',3)
                    """).run()
                try await tx.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence=5,timeline_sequence=5,membership_revision=3 WHERE room_id=\(bind: room)").run()
            }
            let page = try await source.read(roomID: roomID, owner: owner, afterRoomSequence: 0, trackedUserIDs: tracked, limit: 64)
            #expect(page.records.map { $0.event.roomSequence } == [1,2,3,4,5])
            #expect(page.records[0].membershipControl == nil && page.records[0].recipientPolicy == .currentAuthorized)
            #expect(page.records[1].membershipControl?.members.first { $0.userID == userID }?.authorized == false)
            let userStates = page.records.compactMap { $0.membershipControl?.members.first { $0.userID == userID } }
            #expect(userStates.map(\.memberRevision) == [1,2,3])
            #expect(userStates.map(\.authorized) == [false,true,true])
            #expect(!page.records[4].hasOnlineBody && page.records[4].event.payload.isEmpty)
            let relay = try V2RoomSubscriptionRelay.restored(from: snapshot, activation: activation)
            let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
            let subscriptionID = UUID()
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1,
                operation: .subscribe(gateway: gateway, userID: userID, memberRevision: 0,
                    subscriptionID: subscriptionID, generation: 1)))
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: 2,
                operation: .subscribe(gateway: gateway, userID: otherID, memberRevision: 0,
                    subscriptionID: subscriptionID, generation: 1)))
            try await relay.ingest(page)
            #expect(await relay.committedSequence() == 5)
            let deliveries = await relay.pending(for: gateway)
            #expect(deliveries.contains { $0.payload == .revoke(userID: userID, memberRevision: 1) })
            #expect(deliveries.last?.payload == .head(highWatermark: 5))
            for delivery in deliveries {
                if case .event(let event, let members) = delivery.payload, event.roomSequence >= 2 {
                    #expect(!members.contains { $0.userID == userID })
                }
                if case .broadcast(let event) = delivery.payload {
                    #expect(delivery.deliverySequence > 1 && event.recipientUserIDs.isEmpty)
                }
            }
            let headOnly = try PostgresV2RoomSubscriptionSource(database: database, activation: activation, schema: schema, maximumOnlineBodyBytes: 1)
            let boundedPage = try await headOnly.read(roomID: roomID, owner: owner,
                afterRoomSequence: 0, trackedUserIDs: tracked, limit: 64)
            #expect(boundedPage.records.count == 5 && boundedPage.records.allSatisfy { !$0.hasOnlineBody })
            #expect(boundedPage.records[1].membershipControl?.members.first { $0.userID == userID }?.authorized == false)
            await #expect(throws: V2RoomSubscriptionSourceError.wrongOwner) {
                try await source.snapshot(roomID: roomID, owner: try .init(shardID: "other", epoch: 0), trackedUserIDs: tracked)
            }
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET log_trimmed_through_room_sequence=2 WHERE room_id=\(bind: room)").run()
            await #expect(throws: V2RoomSubscriptionSourceError.snapshotRequired) {
                try await source.read(roomID: roomID, owner: owner, afterRoomSequence: 0, trackedUserIDs: tracked, limit: 64)
            }
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at) VALUES(\(bind: UUID()),\(bind: room),6,'unknown.control','{}'::jsonb,3,now())").run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence=6 WHERE room_id=\(bind: room)").run()
            await #expect(throws: V2RoomSubscriptionSourceError.corruptPersistence) {
                try await source.read(roomID: roomID, owner: owner, afterRoomSequence: 5, trackedUserIDs: tracked, limit: 64)
            }
            // No row at sequence 7: never advance the consumed cursor to the
            // observed room high-water when committed facts are incomplete.
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence=7 WHERE room_id=\(bind: room)").run()
            await #expect(throws: V2RoomSubscriptionSourceError.snapshotRequired) {
                try await source.read(roomID: roomID, owner: owner, afterRoomSequence: 6, trackedUserIDs: tracked, limit: 64)
            }
            #expect(snapshot.remainingLeaseMilliseconds > 0 && snapshot.remainingLeaseMilliseconds <= 60_000)
            let wrongActivation = try roomSubscriptionFixtureActivation(roomID: roomID, ownerEpoch: 0)
            let fenced = try PostgresV2RoomSubscriptionSource(database: database, activation: wrongActivation, schema: schema)
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                try await fenced.snapshot(roomID: roomID, owner: owner, trackedUserIDs: tracked)
            }
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE room_id=\(bind: room)").run()

            await #expect(throws: V2RoomActivationLeaseError.leaseExpired) {
                try await source.snapshot(roomID: roomID, owner: owner, trackedUserIDs: tracked)
            }

        }
    }
}

private func insertSubscriptionLease(sql: any SQLDatabase, schema: String, activation: V2RoomActivationToken) async throws {
    try await sql.raw("""
        INSERT INTO \(unsafeRaw: schema).room_activation_leases
        (room_id,activation_epoch,owner_shard_id,owner_epoch,host_id,host_incarnation_id,expires_at)
        VALUES(\(bind: activation.roomID.uuidValue!),\(bind: activation.activationEpoch.rawValue),
        \(bind: activation.owner.shardID),\(bind: activation.owner.epoch),\(bind: activation.host.hostID.rawValue),
        \(bind: activation.host.incarnationID),clock_timestamp()+interval '60 seconds')
        """).run()
}

private actor SubscriptionReadGate {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signaled = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private func withSubscriptionSourceDatabase(_ body: (any Database, any SQLDatabase, String) async throws -> Void) async throws {
    try await withUserEventDatabase { database, sql, schema in
        try await sql.raw("CREATE TABLE \(unsafeRaw: schema).realtime_control_versions(topic_kind text NOT NULL,topic_id text NOT NULL,version bigint NOT NULL,membership_discovery_version bigint NOT NULL DEFAULT 0,session_control_version bigint NOT NULL DEFAULT 0,PRIMARY KEY(topic_kind,topic_id))").run()
        try await body(database, sql, schema)
    }
}
