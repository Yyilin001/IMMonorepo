@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import HTTPTypes
#if os(macOS)
import Darwin
#endif
import IMV2ActorContracts
import IMV2Core
import IMV2ServerHTTP
import PostgresNIO
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing
import Vapor
import VaporTesting

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("group capabilities fence the selected owner before writes and operation replay", arguments: [V2GroupCapacityClass.standard, .large], ["pin", "announcement", "permissions", "role"])
    func routedGroupCapabilityOwnerEpochFence(_ mode: V2GroupCapacityClass, _ kind: String) async throws {
        try await withForwardOwnerDatabases(mode: mode) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
            try await ownerSQL.raw("UPDATE im_v2.rooms SET membership_revision=1, group_permission_revision=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            let profile = try forwardImportTestProfile()
            let send = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(
                database: owner, controlDatabase: control,
                store: PostgresV2RoomWriteStore(database: owner), shardID: "room-b", epoch: 0), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: room, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "original")) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: room.uuidValue!), 'room-b', 1, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
            let router = V2PostgresRoomShardRouter(database: control)
            let operation = UUID()
            @Sendable func run(_ route: any V2RoomShardRouting, on database: any Database, operationID: UUID, colocated: Bool = false, local: Bool = false) async throws -> String {
                let client = V2RoomRefAdministrationClient(caller: V2RoomRefUserCaller(timeout: .seconds(10)) { wire, _, _ in
                    let selected = try await route.route(for: room)
                    guard selected.shardID == "room-b" else { throw V2RoomShardStorageRegistryError.unknownShardID }
                    return try await withRoomActivation(database: database, roomID: room, shardID: selected.shardID, epoch: selected.epoch) { token in
                        let store = PostgresV2GroupCapabilityOperationStore(database: database, clock: { now })
                        switch wire {
                        case .administration(.groupCapabilityAdmit(let intent)):
                            return .administration(.groupCapabilityAdmission(try await store.admit(intent, token: token)))
                        case .administration(.groupCapabilitySubmit(let command)):
                            return .administration(.groupCapabilityRecovery(try await store.submit(command, token: token, capacityProfile: profile, eventID: .init(uuid: UUID()))))
                        default: throw V2RoomCallFailure.outcomeUnknown
                        }
                    }
                })
                let action: V2GroupCapabilityAction
                let reference: V2OperationReference
                let scope: V2OperationScope
                switch kind {
                case "pin": action = .pin(messageID: message.messageID, isPinned: true, expectedRoomSequence: 1); reference = .pinnedMessage(.init(uuid: operationID)); scope = .message(room, message.messageID)
                case "announcement": action = .announcement(body: "owner announcement", expectedRevision: 0); reference = .groupAnnouncement(.init(uuid: operationID)); scope = .room(room)
                case "permissions": action = .rolePermissions(role: .member, permissions: [], expectedRevision: 1); reference = .groupPermission(.init(uuid: operationID)); scope = .room(room)
                default: action = .memberRole(targetUserID: .init(uuid: memberTwoUUID), role: .admin, expectedMembershipRevision: 1); reference = .groupRole(.init(uuid: operationID)); scope = .room(room)
                }
                let intent = try V2GroupCapabilityIntent(identity: .init(accountID: senderID, scope: scope, operation: reference), action: action, confirmedUntilMilliseconds: 1_750_000_120_000)
                guard case .admitted(let admission) = try await client.admitGroupCapability(intent) else { throw V2GroupCapabilityValidationError.invalidAdmission }
                let command = try V2GroupCapabilityCommand(intent: intent, admission: admission)
                guard case .receipt(let proof) = try await client.submitGroupCapability(command), proof.validates(command: command) else { throw V2GroupCapabilityValidationError.invalidReceipt }
                return "receipt"
            }
            let table = "group_capability_receipts"
            let before = try await ownerSQL.raw("SELECT to_jsonb(x)::text AS value FROM im_v2.rooms x WHERE room_id=\(bind: room.uuidValue!)").first(decoding: StringValueRow.self)?.value
            let sequenceBefore = try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value
            await #expect(throws: (any Error).self) { _ = try await run(router, on: owner, operationID: operation) }
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 0)
            #expect(try await ownerSQL.raw("SELECT to_jsonb(x)::text AS value FROM im_v2.rooms x WHERE room_id=\(bind: room.uuidValue!)").first(decoding: StringValueRow.self)?.value == before)
            #expect(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value == sequenceBefore)
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=0 WHERE room_id=\(bind: room.uuidValue!)").run()
            let cached = V2CachedRoomShardRouter(source: router)
            _ = try await cached.route(for: room)
            let outcomes = try await withThrowingTaskGroup(of: String.self) { tasks in
                for _ in 0..<10 { tasks.addTask { try await run(router, on: owner, operationID: operation) } }
                var values: [String] = []
                for try await value in tasks { values.append(value) }
                return values
            }
            #expect(outcomes.count == 10 && outcomes.allSatisfy { $0 == "receipt" })
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            for op in [operation, UUID()] {
                await #expect(throws: (any Error).self) { _ = try await run(cached, on: owner, operationID: op, colocated: true) }
            }
            #expect(try await run(router, on: owner, operationID: operation) == "receipt")
            try await ownerSQL.raw("UPDATE im_v2.rooms SET room_shard_id='retired-room-b' WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: (any Error).self) { _ = try await run(router, on: owner, operationID: operation) }
            try await ownerSQL.raw("UPDATE im_v2.rooms SET room_shard_id='room-b' WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: (any Error).self) { _ = try await run(router, on: control, operationID: operation) }
            try await sql.raw("UPDATE im_v2.room_owner_routes SET room_shard_id='unregistered' WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: V2RoomShardStorageRegistryError.unknownShardID) { _ = try await run(router, on: owner, operationID: operation) }
            try await sql.raw("UPDATE im_v2.room_owner_routes SET room_shard_id='room-b' WHERE room_id=\(bind: room.uuidValue!)").run()
            // This is an already committed operation. It must still wait for
            // the room fence, and observe epoch changes while acquiring it.
            let barrier = InviteImportTestBarrier()
            let holder = Task {
                try await owner.transaction { transaction in
                    let locked = try #require(transaction as? any SQLDatabase)
                    try await locked.raw("SELECT room_id FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!) FOR UPDATE").run()
                    await barrier.hold()
                    try await locked.raw("UPDATE im_v2.rooms SET owner_epoch=2 WHERE room_id=\(bind: room.uuidValue!)").run()
                }
            }
            await barrier.waitUntilHeld()
            let replay = Task { try await run(router, on: owner, operationID: operation) }
            do {
                var waiting = false
                for _ in 0..<1000 {
                    waiting = try await ownerSQL.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%im_v2.rooms%'").first(decoding: CountRow.self)?.value == 1
                    if waiting { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(waiting)
                guard waiting else { throw TestConfigurationError.schemaAlreadyExists }
                try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=2 WHERE room_id=\(bind: room.uuidValue!)").run()
                await barrier.release(); try await holder.value
                await #expect(throws: (any Error).self) { _ = try await replay.value }
            } catch {
                await barrier.release(); _ = try? await holder.value; _ = try? await replay.value
                throw error
            }
            #expect(try await run(router, on: owner, operationID: operation) == "receipt")
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 1)
            #expect(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value == sequenceBefore.map { $0 + 1 })
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.public_user_profiles").first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 0)
        }
    }

    @Test("message mutations fence the selected owner before writes and operation replay", arguments: [V2GroupCapacityClass.standard, .large], ["edit", "withdraw", "reaction"])
    func routedMessageMutationOwnerEpochFence(_ mode: V2GroupCapacityClass, _ kind: String) async throws {
        try await withForwardOwnerDatabases(mode: mode) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let send = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(
                database: owner, controlDatabase: control,
                store: PostgresV2RoomWriteStore(database: owner), shardID: "room-b", epoch: 0), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: room, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "original")) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: room.uuidValue!), 'room-b', 1, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
            let router = V2PostgresRoomShardRouter(database: control)
            let operation = UUID()
            let identities = V2PostgresMembershipIdentitySnapshotValidator(database: control)
            let host=V2ActorHostIdentity(hostID:try .init("routed-mutation"),incarnationID:UUID())
            @Sendable func run(_ router:any V2RoomShardRouting,on database:any Database,operationID:UUID,local:Bool = false) async throws -> String {
                let selected=try await router.route(for:room)
                guard selected.shardID=="room-b" else { throw V2RoomShardStorageRegistryError.unknownShardID }
                try await database.transaction { transaction in
                    let selectedSQL=try #require(transaction as? any SQLDatabase)
                    try await v2RequireRoomOwner(roomID:room.uuidValue!,route:selected,sql:selectedSQL)
                }
                let acquisition=try await PostgresV2RoomActivationStore(database:database).acquire(roomID:room,owner:.init(shardID:selected.shardID,epoch:selected.epoch),host:host,duration:.init(30_000))
                let lease:V2RoomActivationLease
                switch acquisition { case .acquired(let value),.occupied(let value): lease=value }
                guard lease.token.host==host else { throw CancellationError() }
                let deadline=UInt64(now.timeIntervalSince1970*1000)+60_000
                let mutations=PostgresV2MessageMutationOperationStore(database:database,contentReviewMode:.disabled,identities:identities,clock:{now})
                switch kind {
                case "edit":
                    let command=try V2MessageEditOperationCommand(command:.init(roomID:room,actorUserID:senderID,operationID:.init(uuid:operationID),messageID:message.messageID,expectedMessageRevision:1,text:"edited",maximumUTF8Bytes:64),firstSubmissionDeadlineMilliseconds:deadline)
                    guard case .receipt(let receipt)=try await mutations.edit(command,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now.addingTimeInterval(1),maximumUTF8Bytes:64),case .committed=receipt.outcome else { throw CancellationError() }
                case "withdraw":
                    let command=try V2MessageWithdrawalOperationCommand(command:.init(roomID:room,actorUserID:senderID,operationID:.init(uuid:operationID),messageID:message.messageID,expectedMessageRevision:1),firstSubmissionDeadlineMilliseconds:deadline)
                    guard case .receipt(let receipt)=try await mutations.withdraw(command,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now.addingTimeInterval(1)),case .committed=receipt.outcome else { throw CancellationError() }
                default:
                    let command=try V2MessageReactionOperationCommand(command:.init(roomID:room,actorUserID:senderID,operationID:.init(uuid:operationID),messageID:message.messageID,reaction:"👍",action:.add),expectedReactionRevision:0,firstSubmissionDeadlineMilliseconds:deadline)
                    guard case .receipt(let receipt)=try await PostgresV2MessageReactionOperationStore(database:database,clock:{now}).change(command,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now.addingTimeInterval(1)),case .committed=receipt.outcome else { throw CancellationError() }
                }
                return "committed"
            }
            let table = kind == "reaction" ? "message_reaction_receipts" : "message_mutation_receipts"
            let before = try await ownerSQL.raw("SELECT to_jsonb(x)::text AS value FROM im_v2.messages x WHERE message_id=\(bind: message.messageID.uuidValue!)").first(decoding: StringValueRow.self)?.value
            let sequenceBefore = try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await run(router, on: owner, operationID: operation) }
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 0)
            #expect(try await ownerSQL.raw("SELECT to_jsonb(x)::text AS value FROM im_v2.messages x WHERE message_id=\(bind: message.messageID.uuidValue!)").first(decoding: StringValueRow.self)?.value == before)
            #expect(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value == sequenceBefore)
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=0 WHERE room_id=\(bind: room.uuidValue!)").run()
            let cached = V2CachedRoomShardRouter(source: router)
            _ = try await cached.route(for: room)
            let outcomes = try await withThrowingTaskGroup(of: String.self) { tasks in
                for _ in 0..<10 { tasks.addTask { try await run(router, on: owner, operationID: operation) } }
                var values: [String] = []
                for try await value in tasks { values.append(value) }
                return values
            }
            #expect(outcomes.count==10 && outcomes.allSatisfy { $0=="committed" })
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            for op in [operation, UUID()] {
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await run(cached, on: owner, operationID: op) }
            }
            #expect(try await run(router, on: owner, operationID: operation) == "committed")
            try await ownerSQL.raw("UPDATE im_v2.rooms SET room_shard_id='retired-room-b' WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await run(router, on: owner, operationID: operation) }
            try await ownerSQL.raw("UPDATE im_v2.rooms SET room_shard_id='room-b' WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await run(router, on: control, operationID: operation) }
            try await sql.raw("UPDATE im_v2.room_owner_routes SET room_shard_id='unregistered' WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: V2RoomShardStorageRegistryError.unknownShardID) { _ = try await run(router, on: owner, operationID: operation) }
            try await sql.raw("UPDATE im_v2.room_owner_routes SET room_shard_id='room-b' WHERE room_id=\(bind: room.uuidValue!)").run()
            // This is an already committed operation. It must still wait for
            // the room fence, and observe epoch changes while acquiring it.
            let barrier = InviteImportTestBarrier()
            let holder = Task {
                try await owner.transaction { transaction in
                    let locked = try #require(transaction as? any SQLDatabase)
                    try await locked.raw("SELECT room_id FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!) FOR UPDATE").run()
                    await barrier.hold()
                    try await locked.raw("UPDATE im_v2.rooms SET owner_epoch=2 WHERE room_id=\(bind: room.uuidValue!)").run()
                }
            }
            await barrier.waitUntilHeld()
            let replay = Task { try await run(router, on: owner, operationID: operation) }
            do {
                var waiting = false
                for _ in 0..<1000 {
                    waiting = try await ownerSQL.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%SELECT room_shard_id, owner_epoch FROM im_v2.rooms%'").first(decoding: CountRow.self)?.value == 1
                    if waiting { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(waiting)
                guard waiting else { throw TestConfigurationError.schemaAlreadyExists }
                try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=2 WHERE room_id=\(bind: room.uuidValue!)").run()
                await barrier.release(); try await holder.value
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await replay.value }
            } catch {
                await barrier.release(); _ = try? await holder.value; _ = try? await replay.value
                throw error
            }
            #expect(try await run(router, on: owner, operationID: operation) == "committed")
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 1)
            #expect(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value == sequenceBefore.map { $0 + 1 })
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.public_user_profiles").first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 0)
        }
    }

    @Test("typed membership preserves selected owner epochs and original receipts", arguments: [V2GroupCapacityClass.standard, .large])
    func routedMembershipOwnerEpochFence(_ mode: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: mode) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: room.uuidValue!), 'room-b', 1, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id=EXCLUDED.room_shard_id,route_epoch=EXCLUDED.route_epoch").run()
            let router = V2PostgresRoomShardRouter(database: control)
            let identities = V2PostgresMembershipIdentitySnapshotValidator(database: control)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 3))
            func client(_ router: any V2RoomShardRouting, database: any Database) -> V2RoomRefAdministrationClient {
                .init(caller: V2RoomRefUserCaller(timeout: .seconds(10)) { wire, principal, _ in
                    let route = try await router.route(for: room)
                    guard route.shardID == "room-b" else { throw V2RoomShardStorageRegistryError.unknownShardID }
                    return try await withRoomActivation(database: database, roomID: room, shardID: route.shardID, epoch: route.epoch) { token in
                        let store = PostgresV2MembershipOperationStore(database: database, clock: { now })
                        switch wire {
                        case .administration(.membershipAdmission(let intent)):
                            #expect(principal == intent.actorUserID)
                            let snapshot = try await identities.snapshot(actorUserID: intent.actorUserID, targetUserID: intent.targetUserID)
                            return .administration(.membershipAdmission(try await store.admit(intent, identitySnapshot: snapshot, token: token)))
                        case .administration(.membershipSubmit(let command)):
                            #expect(principal == command.intent.actorUserID)
                            let snapshot = try await identities.snapshot(actorUserID: command.intent.actorUserID, targetUserID: command.intent.targetUserID)
                            return .administration(.membershipRecovery(try await store.submit(command, token: token, capacityProfile: profile, eventID: .init(uuid: UUID()), identitySnapshot: snapshot)))
                        default: throw V2RoomCallFailure.outcomeUnknown
                        }
                    }
                })
            }
            let routed = client(router, database: owner)
            let intent = try V2MembershipIntent(roomID: room, actorUserID: .init(uuid: senderUUID), operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID), action: .remove, expectedMembershipRevision: 0, confirmedUntilMilliseconds: 1_750_000_120_000)
            await #expect(throws: (any Error).self) { _ = try await routed.admitMembershipOperation(intent) }
            #expect(try await count("im_v2.membership_operation_receipts", on: ownerSQL) == 0)
            #expect(try await count("im_v2.room_memberships WHERE left_revision IS NULL", on: ownerSQL) == 3)
            #expect(try await count("im_v2.room_events", on: ownerSQL) == 0)
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=0 WHERE room_id=\(bind: room.uuidValue!)").run()
            let cachedRouter = V2CachedRoomShardRouter(source: router)
            _ = try await cachedRouter.route(for: room)
            let cached = client(cachedRouter, database: owner)
            guard case .admitted(let admission) = try await routed.admitMembershipOperation(intent) else { throw V2MembershipOperationValidationError.invalidAdmission }
            let command = try V2MembershipOperationCommand(intent: intent, admission: admission)
            guard case .receipt(let first) = try await routed.submitMembershipOperation(command) else { throw V2MembershipOperationValidationError.invalidReceipt }
            for _ in 0..<9 {
                #expect(try await routed.submitMembershipOperation(command) == .receipt(first))
            }
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: (any Error).self) { _ = try await cached.submitMembershipOperation(command) }
            #expect(try await count("im_v2.membership_operation_receipts", on: ownerSQL) == 1)
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
            #expect(try await routed.submitMembershipOperation(command) == .receipt(first))
            let add = try V2MembershipIntent(roomID: room, actorUserID: .init(uuid: senderUUID), operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID), action: .add, expectedMembershipRevision: 1, confirmedUntilMilliseconds: 1_750_000_120_000)
            #expect(try await routed.admitMembershipOperation(add) == .currentUnavailable(.permissionDenied))
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='active' WHERE user_id=\(bind: senderUUID)").run()
            guard case .admitted(let addAdmission) = try await routed.admitMembershipOperation(add) else { throw V2MembershipOperationValidationError.invalidAdmission }
            let addCommand = try V2MembershipOperationCommand(intent: add, admission: addAdmission)
            guard case .receipt(let added) = try await routed.submitMembershipOperation(addCommand) else { throw V2MembershipOperationValidationError.invalidReceipt }
            #expect(added.validates(command: addCommand))
            let wrong = client(router, database: control)
            await #expect(throws: (any Error).self) { _ = try await wrong.submitMembershipOperation(command) }
            try await sql.raw("UPDATE im_v2.room_owner_routes SET room_shard_id='unregistered' WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: V2RoomShardStorageRegistryError.unknownShardID) { _ = try await routed.submitMembershipOperation(command) }
            #expect(try await count("im_v2.membership_operation_receipts", on: ownerSQL) == 2)
            #expect(try await count("im_v2.public_user_profiles", on: ownerSQL) == 0)
            #expect(try await count("im_v2.membership_operation_receipts", on: sql) == 0)
        }
    }

    @Test("owner-first creation retry publishes its original binding and preserves terminal state", arguments: [V2GroupCapacityClass.standard, .large])
    func inviteCreationRetryPreservesOwnerBinding(_ mode: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: mode) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000.123456)
            let actor = UserID(uuid: senderUUID)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x71, count: 32))
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 3))
            let clock = TestSequenceClock([now])
            let directory = PostgresV2GroupInviteDirectory(database: control)
            let base = invitationOperationPort(control: control, owner: owner, shardID: "room-b", issuer: issuer, capacityProfile: profile, now: { clock.now() })
            let roomPort = invitationRoomPort(control: control, owner: owner, shardID: "room-b", capacityProfile: profile, now: { clock.now() })
            for state in [V2GroupInviteState.active, .expired, .revoked, .exhausted] {
                clock.set([now])
                try await sql.raw("UPDATE im_v2.public_user_profiles SET state='active' WHERE user_id=\(bind: senderUUID)").run()
                let loss = CapabilityInvitationResponseLoss()
                let interrupted = V2GroupInvitationOperationRoomPort(baseline: base.baseline, admit: base.admit, submit: { command, deadline in
                    let result = try await base.submit(command, deadline)
                    if loss.consume() { throw ProfilePropagationShadowFailure.interrupted }; return result
                }, recover: base.recover)
                let coordinator = V2ActorInvitationCoordinator(controlDatabase: control, room: roomPort, operations: interrupted, secretIssuer: issuer, now: { clock.now() })
                let intent = try capabilityInvitationIntent(actor: actor, room: room, reference: .groupInvite(.init(uuid: UUID())),
                    action: .create(lifetimeSeconds: 3_600, maximumApprovedUses: 5, expectedMembershipRevision: 0), confirmedAt: now)
                let submission = try await capabilityInvitationAdmission(coordinator, intent: intent)
                await #expect(throws: ProfilePropagationShadowFailure.interrupted) { _ = try await coordinator.submitOperation(submission, deadline: invitationTestDeadline()) }
                let proof = try capabilityInvitationProof(await base.recover(.init(intent: intent, action: .query), invitationTestDeadline()), intent: intent)
                guard case .applied(.inviteCreated(let inviteID, let created, let expiry, 5)) = proof.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
                let secret = try issuer.secret(actorUserID: actor, operationID: .init(intent.identity.operation.rawOperationID))
                #expect(try await directory.resolve(tokenDigest: issuer.digest(secret)) == nil)
                if state == .revoked {
                    let revoke = try capabilityInvitationIntent(actor: actor, room: room, reference: .groupInvite(.init(uuid: UUID())), action: .revoke(inviteID: inviteID, expectedMembershipRevision: 0), confirmedAt: now)
                    let command = try await capabilityInvitationAdmission(coordinator, intent: revoke)
                    _ = try capabilityInvitationProof(await coordinator.submitOperation(command, deadline: invitationTestDeadline()), intent: revoke)
                } else if state == .exhausted {
                    try await ownerSQL.raw("UPDATE im_v2.group_invite_links SET approved_use_count=maximum_approved_uses WHERE invite_id=\(bind: inviteID.uuidValue!)").run()
                }
                clock.set([now.addingTimeInterval(state == .expired ? 3_601 : 30)])
                let changed = try capabilityInvitationIntent(actor: actor, room: room, reference: intent.identity.operation,
                    action: .create(lifetimeSeconds: 7_200, maximumApprovedUses: 5, expectedMembershipRevision: 0), confirmedAt: now)
                #expect(try await coordinator.recoverOperation(.init(intent: changed, action: .query), deadline: invitationTestDeadline()) == .fingerprintConflict)
                if state != .active { try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run() }
                try await withThrowingTaskGroup(of: V2GroupInvitationOperationRecoveryResult.self) { tasks in
                    for _ in 0..<10 { tasks.addTask { try await coordinator.recoverOperation(.init(intent: intent, action: .query), deadline: invitationTestDeadline()) } }
                    for try await result in tasks { #expect(try capabilityInvitationProof(result, intent: intent) == proof) }
                }
                let request = try v2GroupInvitationCreationRequest(submission.command, issuer: issuer, policy: .standard, now: now)
                let storedCreated = try V2PersistenceTimestamp(date: request.createdAt).date
                let storedExpiry = try V2PersistenceTimestamp(date: request.expiresAt).date
                #expect(created == UInt64(try v2GatewayMilliseconds(storedCreated)))
                #expect(expiry == UInt64(try v2GatewayMilliseconds(storedExpiry)))
                #expect(storedExpiry.timeIntervalSince(storedCreated) == 3_600)
                #expect(try await directory.resolve(tokenDigest: issuer.digest(secret)) == .init(inviteID: inviteID, roomID: room))
                #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links WHERE creation_operation_id=\(bind: UUID(uuidString: intent.identity.operation.rawOperationID)!)").first(decoding: CountRow.self)?.value == 1)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_creation_recovery WHERE operation_id=\(bind: UUID(uuidString: intent.identity.operation.rawOperationID)!) AND state='completed'").first(decoding: CountRow.self)?.value == 1)
                let currentState = try await ownerSQL.raw("SELECT state FROM im_v2.group_invite_links WHERE invite_id=\(bind: inviteID.uuidValue!)").first(decoding: CapabilityInvitationStateRow.self)?.state
                #expect(currentState == (state == .revoked ? "revoked" : "active"))
                // Key rotation cannot manufacture a second link or replace the digest of this operation.
                let otherKey = V2ActorInvitationCoordinator(controlDatabase: control, room: roomPort, operations: base,
                    secretIssuer: try .init(rawKey: Data(repeating: 0xf1, count: 32)), now: { clock.now() })
                await #expect(throws: (any Error).self) { _ = try await otherKey.submitOperation(submission, deadline: invitationTestDeadline()) }
            }
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.public_user_profiles").first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory").first(decoding: CountRow.self)?.value == 4)
        }
    }

    @Test("owner-first creation retry recovers publication failure but never rewrites contradictory bindings")
    func inviteCreationRetryFencesAndRecovery() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000), actor = UserID(uuid: senderUUID)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            let directory = PostgresV2GroupInviteDirectory(database: control)
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x91, count: 32))
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let clock = TestSequenceClock([now]), ownerSwitch = InvitationOwnerSwitch()
            let select: @Sendable (RoomID) throws -> (database: any Database, shardID: String, epoch: Int64) = { _ in (owner, "room-b", try ownerSwitch.current()) }
            let port = invitationOperationPort(control: control, owner: select, issuer: issuer, capacityProfile: profile, now: { clock.now() })
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: control,
                room: invitationRoomPort(control: control, owner: select, capacityProfile: profile, now: { clock.now() }),
                operations: port, secretIssuer: issuer, now: { clock.now() })
            func candidate() async throws -> V2GroupInvitationSubmission {
                let intent = try capabilityInvitationIntent(actor: actor, room: room, reference: .groupInvite(.init(uuid: UUID())), action: .create(lifetimeSeconds: 3_600, maximumApprovedUses: 5, expectedMembershipRevision: 0), confirmedAt: now)
                return try await capabilityInvitationAdmission(coordinator, intent: intent)
            }
            let original = try await candidate()
            ownerSwitch.set(epoch: 1)
            await #expect(throws: V2RoomActivationLeaseError.ownerChanged) { _ = try await coordinator.submitOperation(original, deadline: invitationTestDeadline()) }
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory").first(decoding: CountRow.self)?.value == 0)
            ownerSwitch.set(epoch: 0)
            try await sql.raw("CREATE FUNCTION im_v2.fail_invite_ready() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'test publication failure'; END;$$").run()
            try await sql.raw("CREATE TRIGGER test_invite_ready BEFORE UPDATE ON im_v2.group_invite_directory FOR EACH ROW EXECUTE FUNCTION im_v2.fail_invite_ready()").run()
            await #expect(throws: (any Error).self) { _ = try await coordinator.submitOperation(original, deadline: invitationTestDeadline()) }
            let ownerProof = try capabilityInvitationProof(await port.recover(.init(intent: original.command.intent, action: .query), invitationTestDeadline()), intent: original.command.intent)
            guard case .applied(.inviteCreated(let originalID, _, _, _)) = ownerProof.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            let digest = issuer.digest(try issuer.secret(actorUserID: actor, operationID: .init(original.command.identity.operation.rawOperationID)))
            #expect(try await directory.resolve(tokenDigest: digest) == nil)
            try await sql.raw("DROP TRIGGER test_invite_ready ON im_v2.group_invite_directory").run()
            try await sql.raw("DROP FUNCTION im_v2.fail_invite_ready()").run()
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
            let later = now.addingTimeInterval(31); clock.set([later])
            let worker = V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, now: { later })
            let report = try await worker.runOnce()
            #expect(report.attempted == 1 && report.completed == 1)
            #expect(try await directory.resolve(tokenDigest: digest)?.inviteID == originalID)
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='active' WHERE user_id=\(bind: senderUUID)").run()
            clock.set([now])
            let second = try await candidate()
            // Inject contradictory control evidence after a genuine fenced owner commit.
            try await PostgresV2GroupInvitationControlCommandStore(database: control).save(second.command)
            let secondProof = try capabilityInvitationProof(await port.submit(.init(command: second.command), invitationTestDeadline()), intent: second.command.intent)
            let bound = try v2GroupInvitationCreationRequest(second.command, issuer: issuer, policy: .standard, now: now)
            let contradictory = V2GroupInviteCreatePersistenceRequest(inviteID: .init(uuid: UUID()), roomID: room, actorUserID: actor,
                operationID: bound.operationID, tokenDigest: bound.tokenDigest, requestedLifetimeSeconds: bound.requestedLifetimeSeconds,
                expiresAt: bound.expiresAt.addingTimeInterval(10), maximumApprovedUses: 5, maximumActiveInvitesPerRoom: 20, createdAt: bound.createdAt.addingTimeInterval(10))
            _ = try await directory.prepare(contradictory)
            await #expect(throws: V2GroupInviteDirectoryError.ownerResultMismatch) { _ = try await coordinator.recoverOperation(.init(intent: second.command.intent, action: .query), deadline: invitationTestDeadline()) }
            let contradictoryReadyAt = later.addingTimeInterval(30)
            clock.set([contradictoryReadyAt])
            let contradictoryWorker = V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, now: { contradictoryReadyAt })
            #expect(try await contradictoryWorker.runOnce().paused == 1)
            #expect(try await directory.resolve(tokenDigest: bound.tokenDigest) == nil)
            #expect(try await port.recover(.init(intent: second.command.intent, action: .query), invitationTestDeadline()) == .receipt(secondProof))
            #expect(try await directory.prepare(contradictory).request.inviteID == contradictory.inviteID)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_creation_recovery WHERE operation_id=\(bind: bound.operationID.uuidValue!) AND state='paused' AND last_error_code='conflicting_evidence'").first(decoding: CountRow.self)?.value == 1)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 2)
        }
    }

    @Test("invite directory survives owner response loss and finalize failure across databases")
    func inviteDirectoryCreationRecovery() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, room in
            let actor = UserID(uuid: senderUUID), now = Date(timeIntervalSince1970: 1_750_000_000.123456)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0xa7, count: 32))
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let directory = PostgresV2GroupInviteDirectory(database: control)
            let base = invitationOperationPort(control: control, owner: owner, shardID: "room-b", issuer: issuer, capacityProfile: profile, now: { now })
            let loss = CapabilityInvitationResponseLoss()
            let dropping = V2GroupInvitationOperationRoomPort(baseline: base.baseline, admit: base.admit, submit: { request, deadline in
                let reply = try await base.submit(request, deadline)
                if loss.consume() { throw ProfilePropagationShadowFailure.interrupted }; return reply
            }, recover: base.recover)
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: control,
                room: invitationRoomPort(control: control, owner: owner, shardID: "room-b", capacityProfile: profile, now: { now }),
                operations: dropping, secretIssuer: issuer, now: { now })
            let intent = try capabilityInvitationIntent(actor: actor, room: room, reference: .groupInvite(.init(uuid: UUID())), action: .create(lifetimeSeconds: 3_600, maximumApprovedUses: 5, expectedMembershipRevision: 0), confirmedAt: now)
            let submission = try await capabilityInvitationAdmission(coordinator, intent: intent)
            let candidate = try v2GroupInvitationCreationRequest(submission.command, issuer: issuer, policy: .standard, now: now)
            await #expect(throws: ProfilePropagationShadowFailure.interrupted) { _ = try await coordinator.submitOperation(submission, deadline: invitationTestDeadline()) }
            #expect(try await directory.resolve(tokenDigest: candidate.tokenDigest) == nil)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
            try await controlSQL.raw("CREATE FUNCTION im_v2.fail_invite_directory_ready() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'test finalize failure'; END;$$").run()
            try await controlSQL.raw("CREATE TRIGGER test_invite_directory_ready AFTER UPDATE ON im_v2.group_invite_directory FOR EACH ROW EXECUTE FUNCTION im_v2.fail_invite_directory_ready()").run()
            await #expect(throws: (any Error).self) { _ = try await coordinator.recoverOperation(.init(intent: intent, action: .query), deadline: invitationTestDeadline()) }
            #expect(try await directory.resolve(tokenDigest: candidate.tokenDigest) == nil)
            try await controlSQL.raw("DROP TRIGGER test_invite_directory_ready ON im_v2.group_invite_directory").run()
            try await controlSQL.raw("DROP FUNCTION im_v2.fail_invite_directory_ready()").run()
            let original = try capabilityInvitationProof(await base.recover(.init(intent: intent, action: .query), invitationTestDeadline()), intent: intent)
            try await withThrowingTaskGroup(of: V2GroupInvitationOperationRecoveryResult.self) { tasks in
                for _ in 0..<10 { tasks.addTask { try await coordinator.recoverOperation(.init(intent: intent, action: .query), deadline: invitationTestDeadline()) } }
                for try await value in tasks { #expect(try capabilityInvitationProof(value, intent: intent) == original) }
            }
            #expect(try await directory.resolve(tokenDigest: candidate.tokenDigest) == .init(inviteID: candidate.inviteID, roomID: room))
            #expect(try await directory.prepare(candidate).isReady)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
            for changed in [
                V2GroupInviteCreatePersistenceRequest(inviteID: candidate.inviteID, roomID: .init(uuid: UUID()), actorUserID: actor, operationID: candidate.operationID, tokenDigest: candidate.tokenDigest, requestedLifetimeSeconds: 3_600, expiresAt: candidate.expiresAt, maximumApprovedUses: 5, maximumActiveInvitesPerRoom: 20, createdAt: candidate.createdAt),
                V2GroupInviteCreatePersistenceRequest(inviteID: candidate.inviteID, roomID: room, actorUserID: actor, operationID: candidate.operationID, tokenDigest: Data(repeating: 0xb7, count: 32), requestedLifetimeSeconds: 3_600, expiresAt: candidate.expiresAt, maximumApprovedUses: 5, maximumActiveInvitesPerRoom: 20, createdAt: candidate.createdAt),
                V2GroupInviteCreatePersistenceRequest(inviteID: candidate.inviteID, roomID: room, actorUserID: actor, operationID: candidate.operationID, tokenDigest: candidate.tokenDigest, requestedLifetimeSeconds: 3_600, expiresAt: candidate.expiresAt, maximumApprovedUses: 6, maximumActiveInvitesPerRoom: 20, createdAt: candidate.createdAt)
            ] { await #expect(throws: V2GroupInviteDirectoryError.conflict) { _ = try await directory.prepare(changed) } }
            let revoke = try capabilityInvitationIntent(actor: actor, room: room, reference: .groupInvite(.init(uuid: UUID())), action: .revoke(inviteID: candidate.inviteID, expectedMembershipRevision: 0), confirmedAt: now)
            _ = try capabilityInvitationProof(await coordinator.submitOperation(capabilityInvitationAdmission(coordinator, intent: revoke), deadline: invitationTestDeadline()), intent: revoke)
            #expect(try await directory.resolve(tokenDigest: candidate.tokenDigest) != nil)
            #expect(try await V2ActorGroupInvitationClient(coordinator: coordinator).preview(secret: issuer.secret(actorUserID: actor, operationID: candidate.operationID), applicantUserID: .init(uuid: memberTwoUUID)) == nil)
            for mutation in ["UPDATE im_v2.group_invite_directory SET state='prepared',ready_at=NULL", "UPDATE im_v2.group_invite_directory SET room_id=gen_random_uuid()", "DELETE FROM im_v2.group_invite_directory"] {
                await #expect(throws: (any Error).self) { try await controlSQL.raw("\(unsafeRaw: mutation)").run() }
            }
            let contested = Data(repeating: 0xd7, count: 32)
            let winners = try await withThrowingTaskGroup(of: Bool.self) { tasks in
                for _ in 0..<2 {
                    let contender = V2GroupInviteCreatePersistenceRequest(inviteID: .init(uuid: UUID()), roomID: room, actorUserID: actor, operationID: .init(uuid: UUID()), tokenDigest: contested, requestedLifetimeSeconds: 3_600, expiresAt: candidate.expiresAt, maximumApprovedUses: 5, maximumActiveInvitesPerRoom: 20, createdAt: candidate.createdAt)
                    tasks.addTask { do { _ = try await directory.prepare(contender);return true } catch V2GroupInviteDirectoryError.conflict { return false } }
                }
                var count = 0;for try await won in tasks { if won { count += 1 } };return count
            }
            let resolvedContested = try await directory.resolve(tokenDigest: contested)
            #expect(winners == 1 && resolvedContested == nil)
            await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { _ = try await directory.resolve(tokenDigest: Data()) }
            try await V2SchemaReadiness.verify(database: control)
            try await assertSQLSchemaGate(true, on: controlSQL)
            try await controlSQL.raw("ALTER TABLE im_v2.group_invite_directory DISABLE TRIGGER group_invite_directory_immutable").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.group_invite_directory[intent-binding]")) { try await V2SchemaReadiness.verify(database: control) }
            try await assertSQLSchemaGate(false, on: controlSQL)
            try await controlSQL.raw("ALTER TABLE im_v2.group_invite_directory ENABLE TRIGGER group_invite_directory_immutable").run()
        }
    }

    @Test("control identity and token directory drive two profile-free room owners", arguments: [V2GroupCapacityClass.standard, .large])
    func routedInvitationsUseControlIdentity(_ mode: V2GroupCapacityClass) async throws {
        guard let controlURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_CONTROL_DATABASE_URL"],
              controlURL != ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              controlURL != ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
        try await withForwardOwnerDatabases(mode: mode) { ownerA, ownerB, sqlA, sqlB, roomB in
            let resources = makeV2DatabaseTestResources(), app = try await Application(.testing)
            do {
                resources.databases.use(try .postgres(url: controlURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
                let control = resources.database(.psql), sql = try #require(control as? any SQLDatabase)
                guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
                try await installSchema(on: sql)
                let now = Date(timeIntervalSince1970: 1_750_000_000), actor = UserID(uuid: senderUUID)
                let applicant = UserID(uuid: UUID()), rejectedApplicant = UserID(uuid: UUID())
                for (id, handle) in [(actor, "invite_owner"), (applicant, "invite_applicant"), (rejectedApplicant, "invite_rejected")] {
                    try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: id.uuidValue!),\(bind: handle),'Control Profile',\(bind: now),\(bind: now))").run()
                }
                for ownerSQL in [sqlA, sqlB] {
                    try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
                    try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
                }
                let roomA = RoomID(uuid: roomUUID)
                let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 3))
                let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x81, count: 32)), switchB = InvitationOwnerSwitch()
                func coordinator(_ roomBOwner: @escaping @Sendable () throws -> (database: any Database, shardID: String, epoch: Int64)) -> V2ActorInvitationCoordinator {
                    let select: @Sendable (RoomID) throws -> (database: any Database, shardID: String, epoch: Int64) = { $0 == roomA ? (ownerA, "room-a", 0) : try roomBOwner() }
                    return .init(controlDatabase: control,
                        room: invitationRoomPort(control: control, owner: select, capacityProfile: profile, now: { now }),
                        operations: invitationOperationPort(control: control, owner: select, issuer: issuer, capacityProfile: profile, now: { now }), secretIssuer: issuer, now: { now })
                }
                let operations = coordinator { (ownerB, "room-b", try switchB.current()) }
                let reads = V2ActorGroupInvitationClient(coordinator: operations)
                var approvals: [V2GroupInvitationSubmission] = []
                var lastCreation: V2GroupInvitationSubmission?
                for (room, ownerSQL) in [(roomA, sqlA), (roomB, sqlB)] {
                    let intent = try capabilityInvitationIntent(actor: actor, room: room, reference: .groupInvite(.init(uuid: UUID())), action: .create(lifetimeSeconds: 3_600, maximumApprovedUses: 5, expectedMembershipRevision: 0), confirmedAt: now)
                    let creation = try await capabilityInvitationAdmission(operations, intent: intent)
                    try await sql.raw("CREATE FUNCTION im_v2.fail_routed_invite_ready() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'test unavailable'; END;$$").run()
                    try await sql.raw("CREATE TRIGGER test_routed_invite_ready AFTER UPDATE ON im_v2.group_invite_directory FOR EACH ROW EXECUTE FUNCTION im_v2.fail_routed_invite_ready()").run()
                    await #expect(throws: (any Error).self) { _ = try await operations.submitOperation(creation, deadline: invitationTestDeadline()) }
                    #expect(try await reads.activeInvites(roomID: room, actorUserID: actor).isEmpty)
                    try await sql.raw("DROP TRIGGER test_routed_invite_ready ON im_v2.group_invite_directory").run()
                    try await sql.raw("DROP FUNCTION im_v2.fail_routed_invite_ready()").run()
                    let created = try capabilityInvitationProof(await operations.submitOperation(creation, deadline: invitationTestDeadline()), intent: intent)
                    guard case .applied(.inviteCreated(let inviteID, _, _, _)) = created.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
                    let secret = try issuer.secret(actorUserID: actor, operationID: .init(intent.identity.operation.rawOperationID))
                    #expect(try await reads.activeInvites(roomID: room, actorUserID: actor).count == 1)
                    #expect(try await reads.preview(secret: secret, applicantUserID: applicant)?.roomID == room)
                    var requestIDs: [GroupJoinRequestID] = []
                    for user in [applicant, rejectedApplicant] {
                        let request = try capabilityInvitationIntent(actor: user, room: room, reference: .groupJoinRequest(.init(uuid: UUID())), action: .submit(inviteID: inviteID, tokenDigest: issuer.digest(secret), note: user == applicant ? "join" : nil), confirmedAt: now)
                        let frozen = try await capabilityInvitationAdmission(operations, intent: request, secret: secret)
                        let proof = try capabilityInvitationProof(await operations.submitOperation(frozen, deadline: invitationTestDeadline()), intent: request)
                        guard case .applied(.requestSubmitted(let requestID, _)) = proof.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch };requestIDs.append(requestID)
                    }
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET display_name='Current Control Name' WHERE user_id=\(bind: applicant.uuidValue!)").run()
                    let page = try await reads.pendingRequests(roomID: room, reviewerUserID: actor, cursor: nil, pageSize: 100)
                    #expect(page.requests.count == 2 && page.requests.contains { $0.applicant.userID == applicant && $0.applicant.displayName == "Current Control Name" })
                    let approve = try capabilityInvitationIntent(actor: actor, room: room, reference: .groupJoinDecision(.init(uuid: UUID())), action: .decide(requestID: requestIDs[0], decision: .approve, expectedMembershipRevision: 0), confirmedAt: now)
                    let frozenApproval = try await capabilityInvitationAdmission(operations, intent: approve)
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: applicant.uuidValue!)").run()
                    guard case .deferred = try await operations.submitOperation(frozenApproval, deadline: invitationTestDeadline()) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
                    #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.room_membership_operations").first(decoding: CountRow.self)?.value == 0)
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET state='active' WHERE user_id=\(bind: applicant.uuidValue!)").run()
                    let approved = try capabilityInvitationProof(await operations.submitOperation(frozenApproval, deadline: invitationTestDeadline()), intent: approve)
                    guard case .applied(.requestDecided(_, .approve, 1)) = approved.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
                    try await sql.raw("INSERT INTO im_v2.account_disables(user_id,operation_id,reason,operator_principal,disabled_at) VALUES (\(bind: actor.uuidValue!),\(bind: UUID()),'policy_enforcement','test.operator',\(bind: now))").run()
                    #expect(try await operations.recoverOperation(.init(intent: approve, action: .query), deadline: invitationTestDeadline()) == .receipt(approved))
                    let reject = try capabilityInvitationIntent(actor: actor, room: room, reference: .groupJoinDecision(.init(uuid: UUID())), action: .decide(requestID: requestIDs[1], decision: .reject, expectedMembershipRevision: 1), confirmedAt: now)
                    #expect(try await operations.admitOperation(.init(intent: reject), deadline: invitationTestDeadline()) == .currentUnavailable(.permissionDenied))
                    try await sql.raw("DELETE FROM im_v2.account_disables WHERE user_id=\(bind: actor.uuidValue!)").run()
                    let rejected = try capabilityInvitationProof(await operations.submitOperation(capabilityInvitationAdmission(operations, intent: reject), deadline: invitationTestDeadline()), intent: reject)
                    guard case .applied(.requestDecided(_, .reject, nil)) = rejected.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
                    #expect(try await reads.pendingRequests(roomID: room, reviewerUserID: actor, cursor: nil, pageSize: 100).requests.isEmpty)
                    #expect(try await ownerSQL.raw("SELECT approved_use_count AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
                    approvals.append(frozenApproval);lastCreation = creation
                    let revoke = try capabilityInvitationIntent(actor: actor, room: room, reference: .groupInvite(.init(uuid: UUID())), action: .revoke(inviteID: inviteID, expectedMembershipRevision: 1), confirmedAt: now)
                    _ = try capabilityInvitationProof(await operations.submitOperation(capabilityInvitationAdmission(operations, intent: revoke), deadline: invitationTestDeadline()), intent: revoke)
                    #expect(try await reads.preview(secret: secret, applicantUserID: applicant) == nil)
                }
                for name in ["rooms", "room_memberships", "group_join_requests"] { #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: name)").first(decoding: CountRow.self)?.value == 0) }
                for ownerSQL in [sqlA, sqlB] { #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.public_user_profiles").first(decoding: CountRow.self)?.value == 0) }
                let unauthorized = try capabilityInvitationIntent(actor: rejectedApplicant, room: roomB, reference: .groupInvite(.init(uuid: UUID())), action: .create(lifetimeSeconds: 3_600, maximumApprovedUses: 5, expectedMembershipRevision: 1), confirmedAt: now)
                #expect(try await operations.admitOperation(.init(intent: unauthorized), deadline: invitationTestDeadline()) == .currentUnavailable(.permissionDenied))
                switchB.set(epoch: 1)
                await #expect(throws: V2RoomActivationLeaseError.ownerChanged) { _ = try await reads.activeInvites(roomID: roomB, actorUserID: actor) }
                try await sqlB.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: roomB.uuidValue!)").run()
                _ = try await reads.activeInvites(roomID: roomB, actorUserID: actor)
                let stale = coordinator { (ownerB, "room-b", 0) }, approval = try #require(approvals.last)
                await #expect(throws: V2RoomActivationLeaseError.ownerChanged) { _ = try await stale.recoverOperation(.init(intent: approval.command.intent, action: .query), deadline: invitationTestDeadline()) }
                let creation = try #require(lastCreation)
                await #expect(throws: V2RoomActivationLeaseError.ownerChanged) { _ = try await stale.submitOperation(creation, deadline: invitationTestDeadline()) }
                let misplaced = V2ActorGroupInvitationClient(coordinator: coordinator { (ownerA, "room-b", 1) })
                await #expect(throws: V2RoomActivationLeaseError.roomNotFound) { _ = try await misplaced.activeInvites(roomID: roomB, actorUserID: actor) }
                let auth = RoutedInvitationTestAuthenticator(user: actor)
                V2VaporGroupInvitationRoutes(authenticator: auth, invitations: reads).register(on: app)
                V2VaporGroupInvitationOperationRoutes(authenticator: auth, coordinator: operations).register(on: app)
                var headers: HTTPFields = [:];headers[.authorization] = "Bearer invite-test";headers[.init("X-IM-Device-ID")!] = auth.device.rawValue;headers.contentType = .json
                try await app.testing { client in
                    let response = try await client.get(URI(string: "v2/rooms/\(roomB.rawValue)/invitation-operations/baseline"), headers: headers)
                    #expect(response.status == .ok && response.headers[.cacheControl] == "no-store")
                    #expect((try await response.body.string() ?? "").contains(roomB.rawValue))
                }
                switchB.set(available: false, epoch: 1)
                await #expect(throws: V2RoomCallFailure.notAccepted(.unavailable)) { _ = try await reads.activeInvites(roomID: roomB, actorUserID: actor) }
                try await app.testing { client in
                    let response = try await client.get(URI(string: "v2/group-invites?room_id=\(roomB.rawValue)"), headers: headers)
                    #expect(response.status == .serviceUnavailable)
                    #expect(!(try await response.body.string() ?? "").contains("room-b"))
                }
                try await sql.raw("ALTER TABLE im_v2.group_invite_links ADD CONSTRAINT test_control_identity_fk FOREIGN KEY(created_by_user_id) REFERENCES im_v2.public_user_profiles(user_id) NOT VALID").run()
                await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.group_invite_links[control-identity]")) { try await V2SchemaReadiness.verify(database: control) }
                try await assertSQLSchemaGate(false, on: sql)
                try await sql.raw("ALTER TABLE im_v2.group_invite_links DROP CONSTRAINT test_control_identity_fk").run()
                try await V2SchemaReadiness.verify(database: control);try await assertSQLSchemaGate(true, on: sql)
                try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
                try await app.shutdown();try await resources.shutdown()
            } catch {
                if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
                try? await app.shutdown();try? await resources.shutdown();throw error
            }
        }
    }

    @Test("invite creation recovery uses attempt time and publishes directory/job atomically")
    func inviteCreationRecoveryUsesAttemptClock() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000), actor = UserID(uuid: senderUUID)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            let directory = PostgresV2GroupInviteDirectory(database: control)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let policy = try V2GroupInvitationPolicy(maximumActiveInvitesPerRoom: 1)
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x31, count: 32)), clock = TestSequenceClock([now])
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: control,
                room: invitationRoomPort(control: control, owner: owner, shardID: "room-b", capacityProfile: profile, now: { clock.now() }),
                operations: invitationOperationPort(control: control, owner: owner, shardID: "room-b", issuer: issuer, policy: policy, capacityProfile: profile, now: { clock.now() }),
                secretIssuer: issuer, policy: policy, now: { clock.now() })
            func creation(at time: Date, lifetime: Int) async throws -> V2GroupInvitationSubmission {
                let intent = try capabilityInvitationIntent(actor: actor, room: room, reference: .groupInvite(.init(uuid: UUID())), action: .create(lifetimeSeconds: UInt64(lifetime), maximumApprovedUses: 5, expectedMembershipRevision: 0), confirmedAt: time)
                return try await capabilityInvitationAdmission(coordinator, intent: intent)
            }
            let first = try await creation(at: now, lifetime: 300)
            _ = try capabilityInvitationProof(await coordinator.submitOperation(first, deadline: invitationTestDeadline()), intent: first.command.intent)
            let second = try await creation(at: now, lifetime: 3_600)
            guard case .deferred = try await coordinator.submitOperation(second, deadline: invitationTestDeadline()) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            let later = now.addingTimeInterval(301); clock.set([later])
            let secondProof = try capabilityInvitationProof(await coordinator.recoverOperation(.init(intent: second.command.intent, action: .closeIfAbsent), deadline: invitationTestDeadline()), intent: second.command.intent)
            #expect(secondProof.outcome == .closed)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
            // A new explicit confirmation may use the released active-link capacity.
            let third = try await creation(at: later, lifetime: 3_600)
            let bound = try v2GroupInvitationCreationRequest(third.command, issuer: issuer, policy: policy, now: later)
            try await sql.raw("CREATE FUNCTION im_v2.fail_invite_job_completion() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF NEW.state='completed' THEN RAISE EXCEPTION 'test finalize job failure'; END IF; RETURN NEW; END;$$").run()
            try await sql.raw("CREATE TRIGGER test_invite_job_completion BEFORE UPDATE ON im_v2.group_invite_creation_recovery FOR EACH ROW EXECUTE FUNCTION im_v2.fail_invite_job_completion()").run()
            await #expect(throws: (any Error).self) { _ = try await coordinator.submitOperation(third, deadline: invitationTestDeadline()) }
            #expect(try await directory.resolve(tokenDigest: bound.tokenDigest) == nil)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 2)
            let attempt = later.addingTimeInterval(31); clock.set([attempt])
            let worker = V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, policy: policy, now: { attempt })
            #expect(try await worker.runOnce().deferred == 1)
            #expect(try await directory.resolve(tokenDigest: bound.tokenDigest) == nil)
            try await sql.raw("DROP TRIGGER test_invite_job_completion ON im_v2.group_invite_creation_recovery").run()
            try await sql.raw("DROP FUNCTION im_v2.fail_invite_job_completion()").run()
            #expect(try await worker.runOnce().attempted == 0)
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: actor.uuidValue!)").run()
            let retry = attempt.addingTimeInterval(15); clock.set([retry])
            let recovered = try await V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, policy: policy, now: { retry }).runOnce()
            #expect(recovered.completed == 1 && recovered.attempted == 1)
            #expect(try await directory.resolve(tokenDigest: bound.tokenDigest)?.inviteID == bound.inviteID)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory WHERE operation_id=\(bind: bound.operationID.uuidValue!) AND ready_at=\(bind: retry)").first(decoding: CountRow.self)?.value == 1)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links WHERE invite_id=\(bind: bound.inviteID.uuidValue!) AND created_at=\(bind: bound.createdAt) AND expires_at=\(bind: bound.expiresAt)").first(decoding: CountRow.self)?.value == 1)
        }
    }

    @Test("invite creation recovery fences stale claims, resumes dependencies and drains cancellation")
    func inviteCreationRecoveryClaimsAndFences() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000), actor = UserID(uuid: senderUUID)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            let directory = PostgresV2GroupInviteDirectory(database: control)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x41, count: 32)), clock = TestSequenceClock([now]), ownerSwitch = InvitationOwnerSwitch()
            let select: @Sendable (RoomID) throws -> (database: any Database, shardID: String, epoch: Int64) = { _ in (owner, "room-b", try ownerSwitch.current()) }
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: control,
                room: invitationRoomPort(control: control, owner: select, capacityProfile: profile, now: { clock.now() }),
                operations: invitationOperationPort(control: control, owner: select, issuer: issuer, capacityProfile: profile, now: { clock.now() }), secretIssuer: issuer, now: { clock.now() })
            func prepare(at time: Date) async throws -> V2GroupInvitationSubmission {
                let intent = try capabilityInvitationIntent(actor: actor, room: room, reference: .groupInvite(.init(uuid: UUID())), action: .create(lifetimeSeconds: 3_600, maximumApprovedUses: 5, expectedMembershipRevision: 0), confirmedAt: time)
                let submission = try await capabilityInvitationAdmission(coordinator, intent: intent)
                try await PostgresV2GroupInvitationControlCommandStore(database: control).save(submission.command)
                _ = try await directory.prepare(v2GroupInvitationCreationRequest(submission.command, issuer: issuer, policy: .standard, now: time))
                return submission
            }
            let submissions = try await [prepare(at: now), prepare(at: now)]
            let claimTime = now.addingTimeInterval(30)
            async let a = directory.claim(limit: 1, now: claimTime, lease: 60, maximumActiveInvitesPerRoom: 20)
            async let b = directory.claim(limit: 1, now: claimTime, lease: 60, maximumActiveInvitesPerRoom: 20)
            let originals = try await [a, b].flatMap { $0 }
            #expect(originals.count == 2 && Set(originals.map { $0.intent.request.operationID }).count == 2)
            #expect(try await directory.claim(limit: 1, now: claimTime, lease: 60, maximumActiveInvitesPerRoom: 20).isEmpty)
            let reclaimedAt = now.addingTimeInterval(91); clock.set([reclaimedAt])
            let reclaimed = try #require(try await directory.claim(limit: 1, now: reclaimedAt, lease: 60, maximumActiveInvitesPerRoom: 20).first)
            let old = try #require(originals.first { $0.intent.request.operationID == reclaimed.intent.request.operationID })
            #expect(old.claimToken != reclaimed.claimToken && reclaimed.attemptCount == 2)
            #expect(try await !directory.fail(old, reason: .permissionDenied, retryAt: nil, now: reclaimedAt))
            let frozen = try #require(submissions.first { $0.command.identity.operation.rawOperationID == reclaimed.intent.request.operationID.rawValue })
            async let foreground = coordinator.submitOperation(frozen, deadline: invitationTestDeadline())
            async let resumed: Void = coordinator.resumeCreation(reclaimed.intent, evaluatedAt: reclaimedAt, deadline: invitationTestDeadline())
            _ = try await (foreground, resumed)
            #expect(try await !directory.fail(reclaimed, reason: .dependencyUnavailable, retryAt: reclaimedAt.addingTimeInterval(15), now: reclaimedAt))
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: actor.uuidValue!)").run()
            _ = try await V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, now: { reclaimedAt }).runOnce()
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='active' WHERE user_id=\(bind: actor.uuidValue!)").run()
            let transient = try await prepare(at: reclaimedAt)
            ownerSwitch.set(available: false, epoch: 0)
            let retryNow = reclaimedAt.addingTimeInterval(31); clock.set([retryNow])
            let deferred = try await V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, now: { retryNow }).runOnce()
            #expect(deferred.deferred == 1)
            ownerSwitch.set(epoch: 1)
            let epochTime = retryNow.addingTimeInterval(15); clock.set([epochTime])
            #expect(try await V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, now: { epochTime }).runOnce().deferred == 1)
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            let availableAt = epochTime.addingTimeInterval(900); clock.set([availableAt])
            _ = try await V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, now: { availableAt }).runOnce()
            let expired = try capabilityInvitationProof(await coordinator.recoverOperation(.init(intent: transient.command.intent, action: .query), deadline: invitationTestDeadline()), intent: transient.command.intent)
            #expect(expired.outcome == .rejected(.admissionExpired))
            let cancelled = try await prepare(at: availableAt)
            let cancellationAt = availableAt.addingTimeInterval(30);clock.set([cancellationAt])
            await #expect(throws: CancellationError.self) { _ = try await V2GroupInviteCreationRecoveryWorker(jobs: directory, invitations: CancelledInviteCreationResumer(), now: { cancellationAt }).runOnce() }
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_creation_recovery WHERE state='claimed'").first(decoding: CountRow.self)?.value == 1)
            let restartTime = cancellationAt.addingTimeInterval(61); clock.set([restartTime])
            #expect(try await V2GroupInviteCreationRecoveryWorker(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, now: { restartTime }).runOnce().completed == 1)
            let bound = try v2GroupInvitationCreationRequest(cancelled.command, issuer: issuer, policy: .standard, now: availableAt)
            #expect(try await directory.resolve(tokenDigest: bound.tokenDigest)?.inviteID == bound.inviteID)
            try await V2SchemaReadiness.verify(database: control)
            try await assertSQLSchemaGate(true, on: sql)
            try await sql.raw("DROP INDEX im_v2.group_invite_creation_recovery_lease_idx").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.group_invite_creation_recovery[claim-state]")) { try await V2SchemaReadiness.verify(database: control) }
            try await assertSQLSchemaGate(false, on: sql)
        }
    }

    @Test("CI-required cross-store PostgreSQL endpoints are explicitly provisioned")
    func requiresCrossStorePostgresWhenConfigured() {
        guard ProcessInfo.processInfo.environment["IMV2_REQUIRE_CROSS_STORE_POSTGRES_TESTS"] == "1" else { return }
        #expect(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1")
        #expect(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"]?.isEmpty == false)
        #expect(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"]?.isEmpty == false)
        #expect(
            ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"] !=
            ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"]
        )
    }

    @Test("routed group creation validates identity on control and commits canonical rows only on owner")
    func routedGroupCreationUsesControlManifestAndRemoteOwner() async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              let secondaryDatabaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        let ownerID = DatabaseID(string: "group-owner")
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql,
                isDefault: true
            )
            resources.databases.use(
                try .postgres(
                    url: secondaryDatabaseURL,
                    maxConnectionsPerEventLoop: 1
                ),
                as: ownerID
            )
            guard let controlSQL = resources.database(.psql) as? any SQLDatabase,
                  let ownerSQL = resources.database(ownerID) as? any SQLDatabase
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            for sql in [controlSQL, ownerSQL] {
                guard (try await sql.raw(
                    "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
                ).first(decoding: ExistsRow.self))?.exists == false
                else { throw TestConfigurationError.schemaAlreadyExists }
                try await installSchema(on: sql)
            }

            let actor = try UserID(
                "00000000-0000-0000-0000-00000000c101"
            )
            let member = try UserID(
                "00000000-0000-0000-0000-00000000c102"
            )
            let stagedMemberA = try UserID(
                "00000000-0000-0000-0000-00000000c107"
            )
            let stagedMemberB = try UserID(
                "00000000-0000-0000-0000-00000000c108"
            )
            try await controlSQL.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, created_at, updated_at)
                VALUES
                    (\(bind: actor.uuidValue!), 'manifest_actor',
                     'Manifest Actor', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
                    (\(bind: member.uuidValue!), 'manifest_member',
                     'Manifest Member', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
                    (\(bind: stagedMemberA.uuidValue!), 'staged_member_a',
                     'Staged Member A', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
                    (\(bind: stagedMemberB.uuidValue!), 'staged_member_b',
                     'Staged Member B', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                """).run()
            try await ownerSQL.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                VALUES ('rooms-01', 'standard', '00000000-0000-0000-0000-00000000c1aa', 1, CURRENT_TIMESTAMP + INTERVAL '1 hour', 1000)
                """).run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 100, maxCommandsPerWindow: 1000, retryAfterSeconds: 1))
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let owner = try V2RoomBootstrapDomainExecutor(shardID: "rooms-01",
                direct: PostgresV2DirectMessagingStore(database: resources.database(ownerID), identityReader: PostgresV2DirectRoomIdentityReader(database: resources.database(.psql)), projectionDelivery: SuccessfulProjectionDelivery()),
                group: PostgresV2GroupMessagingStore(database: resources.database(ownerID)),
                capacityProfile: profile, now: { now })
            let bootstrap = V2ActorCreationBootstrapPort(execute: { command, _ in
                try await owner.execute(command)
            }, stage: { placement, page, _ in
                try await owner.stage(intent: placement, page: page)
            })
            let store = PostgresV2GroupCreationOperationStore(database: resources.database(.psql),
                selector: try .init(shardIDs: ["rooms-01"]), bootstrap: bootstrap, capacityProfile: profile)
            func create(_ members: [UserID], operation: GroupRoomOperationID, title: String) async throws -> (V2GroupCreationIntent, V2GroupCreationReceipt, RoomID) {
                let canonical = try V2GroupCreationAudience.canonical(members, actorUserID: actor)
                let intent = try V2GroupCreationIntent(identity: .init(accountID: actor, scope: .account(actor), operation: .groupRoom(operation)),
                    title: title, capacityClass: .standard, initialMemberCount: canonical.count,
                    audienceDigest: V2GroupCreationAudience.digest(canonical), firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                guard case .progress(let prepared) = try await store.begin(intent, now: now) else {
                    throw V2GroupMessagingStoreError.corruptPersistenceState
                }
                _ = try await store.append(.init(intent: intent, offset: 0, memberUserIDs: canonical), now: now)
                var result = try await store.finalize(intent, now: now, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
                for _ in 0..<4 {
                    if case .receipt = result { break }
                    result = try await store.recover(.init(intent: intent, action: .query), now: now)
                }
                guard case .receipt(let receipt) = result, case .created(let room,_,_,let count) = receipt.outcome else {
                    throw V2GroupMessagingStoreError.corruptPersistenceState
                }
                #expect(receipt.validates(intent: intent) && room == prepared.roomID && count == canonical.count + 1)
                return (intent, receipt, room)
            }
            let (intent, original, firstRoomID) = try await create([member], operation: .init("00000000-0000-0000-0000-00000000c103"), title: "跨库真实群")
            #expect(try await count("im_v2.rooms", on: controlSQL) == 0)
            #expect(try await count("im_v2.public_user_profiles", on: ownerSQL) == 0)
            #expect(try await count("im_v2.rooms", on: ownerSQL) == 1)
            #expect(try await count("im_v2.group_creation_owner_receipts", on: ownerSQL) == 1)
            #expect(try await count("im_v2.group_creation_pages", on: controlSQL) == 0)
            #expect(try await count("im_v2.group_room_creation_intent_members", on: ownerSQL) == 0)
            guard case .receipt(let replay) = try await store.recover(.init(intent: intent, action: .query), now: now.addingTimeInterval(700)) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
            #expect(replay == original)
            #expect(try await ownerSQL.raw("SELECT COUNT(*)::bigint AS value FROM im_v2.room_memberships WHERE room_id = \(bind: firstRoomID.uuidValue!)").first(decoding: CountRow.self)?.value == 2)
            _ = try await create([stagedMemberA, stagedMemberB], operation: .init("00000000-0000-0000-0000-00000000c109"), title: "跨库分页群")
            #expect(try await count("im_v2.rooms", on: ownerSQL) == 2)
            #expect(try await count("im_v2.group_creation_owner_receipts", on: ownerSQL) == 2)
            #expect(try await count("im_v2.group_room_creation_intent_pages", on: ownerSQL) == 0)
            #expect(try await count("im_v2.user_state_event_outbox", on: controlSQL) == 0)
            #expect(try await count("im_v2.user_state_event_outbox", on: ownerSQL) == 5)
            let worker = try V2UserStateEventWorker(outbox: PostgresV2UserStateEventOutbox(database: resources.database(ownerID)),
                projector: PostgresV2UserStateEventProjector(database: resources.database(.psql)))
            #expect(try await worker.runOnce(limit: 8) == 5)
            #expect(try await count("im_v2.user_sync_log", on: controlSQL) == 5)
            #expect(try await count("im_v2.user_sync_log", on: ownerSQL) == 0)

            try await controlSQL.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await ownerSQL.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw(
                    "DROP SCHEMA IF EXISTS im_v2 CASCADE"
                ).run()
            }
            if let sql = resources.database(ownerID) as? any SQLDatabase {
                try? await sql.raw(
                    "DROP SCHEMA IF EXISTS im_v2 CASCADE"
                ).run()
            }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("authorized group writes scope identity, replay and history to each room")
    func authorizedGroupWritesKeepRoomIdentityAndHistoryIndependent() async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2),
                as: .psql,
                isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(capacityClass: .large, on: sql)

            let secondRoom = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
            let createdAt = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.rooms
                    (room_id, room_shard_id, capacity_profile_id, capacity_class)
                VALUES
                    (\(bind: secondRoom), 'room-a', 'standard',
                     \(bind: V2GroupCapacityClass.large.rawValue))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at)
                VALUES (\(bind: secondRoom),'room-a',0,\(bind: createdAt),\(bind: createdAt))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.group_rooms
                    (room_id, owner_user_id, title, created_at)
                VALUES (\(bind: secondRoom), \(bind: senderUUID),
                        '第二个集合化群', \(bind: createdAt))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
                VALUES (\(bind: secondRoom), 3, 10, \(bind: leaseUUID), 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships
                    (room_id, user_id, joined_revision)
                VALUES
                    (\(bind: secondRoom), \(bind: senderUUID), 0),
                    (\(bind: secondRoom), \(bind: memberTwoUUID), 0),
                    (\(bind: secondRoom), \(bind: memberThreeUUID), 0)
                """).run()

            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10,
                maxCommandsPerWindow: 10,

                retryAfterSeconds: 1
            ))
            let rawWriter = PostgresV2RoomWriteStore(
                database: resources.database(.psql),
                strangerMessagePolicy: try .init(
                    maximumMessagesPerWindow: 10,
                    window: 86_400
                ),
                contentReviewMode: .disabled)
            let writer = V2PolicyAuthorizedTestWriteStore(database: resources.database(.psql),
                controlDatabase: resources.database(.psql), store: rawWriter, shardID: "room-a", epoch: 0)
            let roomIDs = [roomUUID, secondRoom]
            let requests = try roomIDs.enumerated().map { index, room in
                V2RoomWriteRequest(
                    command: try .init(
                        roomID: .init(room.uuidString),
                        senderUserID: senderID,
                        clientMessageID: .init(
                            "00000000-0000-0000-0004-000000000001"
                        ),
                        text: "集合化群消息 \(index + 1)",
                        limits: .init(maxUTF8Bytes: 128)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init(UUID().uuidString),
                        eventID: .init(UUID().uuidString)
                    ),
                    now: Date(timeIntervalSince1970: 1_750_000_001)
                )
            }

            var outcomes: [V2SendMessageOutcome] = []
            for request in requests {
                outcomes.append(try await writer.accept(command: request.command,
                    capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now))
            }
            #expect(outcomes.count == 2)
            for (index, outcome) in outcomes.enumerated() {
                guard case .accepted(let message) = outcome else {
                    Issue.record("expected accepted hybrid-group message")
                    continue
                }
                #expect(message.roomID.rawValue == roomIDs[index].uuidString.lowercased())
                try await assertSendCompletion(command: requests[index].command, accepted: message, eventID: requests[index].identifiers.eventID, sql: sql)
                // The same sender/client ID belongs independently to each room.
                #expect(try await writer.accept(command: requests[index].command, capacityProfile: profile, identifiers: requests[index].identifiers, now: requests[index].now) == .idempotent(message.receipt))
                #expect(message.roomSequence == 1)
                #expect(message.timelineSequence == 1)
                #expect(message.groupCapacityClass == .large)
            }

            let artifacts = try #require(try await sql.raw("""
                SELECT
                    (SELECT count(*) FROM im_v2.messages)::bigint AS messages,
                    (SELECT count(*) FROM im_v2.room_events
                     WHERE event_type = 'message.accepted')::bigint AS events,
                    (SELECT count(*) FROM im_v2.message_projection_states)::bigint
                        AS message_states,
                    (SELECT count(*) FROM im_v2.message_projection_state_values)::bigint
                        AS readable_message_states
                """).first(decoding: PlainHybridGroupBatchArtifacts.self))
            #expect(artifacts.messages == 2)
            #expect(artifacts.events == 2)
            #expect(artifacts.messageStates == 2)
            #expect(artifacts.readableMessageStates == 2)

            let roomLogCache = V2DirectRoomLogEventCache(configuration: .init(
                maximumEvents: 16,
                maximumBytes: 1_048_576,
                maximumEventsPerRoom: 8
            ))
            for outcome in outcomes {
                if case .accepted(let message) = outcome {
                    await roomLogCache.recordCommittedPlainDirectMessage(message)
                }
            }
            let eventLog = PostgresV2GroupEventLogStore(
                database: resources.database(.psql),
                directRoomLogEventCache: roomLogCache
            )
            for (index, room) in roomIDs.enumerated() {
                let page = try await eventLog.pull(
                    roomID: .init(room.uuidString),
                    actorUserID: senderID,
                    afterRoomSequence: 0,
                    pageSize: 10
                )
                #expect(page.events.count == 1)
                #expect(page.events.first?.sourceEventID == requests[index].identifiers.eventID)
                #expect(page.events.first?.roomSequence == 1)
                #expect(page.nextRoomSequence == 1)
                #expect(!page.hasMore)
            }

            for request in requests {
                let replay = try await writer.accept(
                    command: request.command,
                    capacityProfile: request.capacityProfile,
                    identifiers: request.identifiers,
                    now: request.now
                )
                guard case .idempotent = replay else {
                    Issue.record("expected exact replay of the committed room message")
                    continue
                }
            }

            let scalarRequest = V2RoomWriteRequest(
                command: try .init(
                    roomID: .init(roomUUID.uuidString),
                    senderUserID: senderID,
                    clientMessageID: .init("00000000-0000-0000-0006-000000000001"),
                    text: "单条完整路径群消息",
                    limits: .init(maxUTF8Bytes: 128)
                ),
                capacityProfile: profile,
                identifiers: try .init(
                    messageID: .init("00000000-0000-0000-0007-000000000001"),
                    eventID: .init("00000000-0000-0000-0008-000000000001")
                ),
                now: Date(timeIntervalSince1970: 1_750_000_001.5)
            )
            let scalarOutcome = try await writer.accept(
                command: scalarRequest.command,
                capacityProfile: scalarRequest.capacityProfile,
                identifiers: scalarRequest.identifiers,
                now: scalarRequest.now
            )
            guard case .accepted(let scalarMessage) = scalarOutcome else {
                Issue.record("expected scalar hybrid-group message acceptance")
                return
            }
            #expect(scalarMessage.groupCapacityClass == .large)

            #expect(scalarMessage.roomSequence == 2)
            await roomLogCache.recordCommittedPlainDirectMessage(scalarMessage)
            let scalarPage = try await eventLog.pull(
                roomID: .init(roomUUID.uuidString),
                actorUserID: senderID,
                afterRoomSequence: 1,
                pageSize: 10
            )
            #expect(scalarPage.events.map(\.sourceEventID) == [scalarRequest.identifiers.eventID])
            #expect(scalarPage.nextRoomSequence == 2)
            #expect(!scalarPage.hasMore)

            try await sql.raw("""
                DELETE FROM im_v2.room_memberships
                WHERE room_id = \(bind: secondRoom)
                  AND user_id = \(bind: senderUUID)
                """).run()
            await #expect(throws: V2GroupEventLogError.actorNotMember) {
                try await eventLog.pull(
                    roomID: .init(secondRoom.uuidString),
                    actorUserID: senderID,
                    afterRoomSequence: 0,
                    pageSize: 10
                )
            }
            let rejectedRequests = try roomIDs.enumerated().map { index, room in
                V2RoomWriteRequest(
                    command: try .init(
                        roomID: .init(room.uuidString),
                        senderUserID: senderID,
                        clientMessageID: .init(
                            String(format: "00000000-0000-0000-0005-%012x", index + 1)
                        ),
                        text: "独立房间的权限边界 \(index + 1)",
                        limits: .init(maxUTF8Bytes: 128)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init(UUID().uuidString),
                        eventID: .init(UUID().uuidString)
                    ),
                    now: Date(timeIntervalSince1970: 1_750_000_002)
                )
            }
            // A removed member in one room cannot roll back another room's
            // accepted message. Both requests retain their own identities.
            let independent = rejectedRequests[0]
            guard case .accepted(let independentlyAccepted) = try await writer.accept(
                command: independent.command, capacityProfile: independent.capacityProfile,
                identifiers: independent.identifiers, now: independent.now) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(independentlyAccepted.roomSequence == 3)
            let rejected = rejectedRequests[1]
            await #expect(throws: V2RoomWriteStoreError.actorNotEligible) {
                try await writer.accept(command: rejected.command, capacityProfile: rejected.capacityProfile,
                    identifiers: rejected.identifiers, now: rejected.now)
            }
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.messages WHERE message_id=\(bind: rejected.identifiers.messageID.uuidValue!)")
                .first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.message_send_completions WHERE room_id=\(bind: secondRoom) AND client_message_id=\(bind: rejected.command.clientMessageID.uuidValue!)")
                .first(decoding: CountRow.self)?.value == 0)
            let rollback = try #require(try await sql.raw("""
                SELECT
                    (SELECT count(*) FROM im_v2.messages)::bigint AS messages,
                    (SELECT sum(room_sequence) FROM im_v2.rooms
                     WHERE room_id IN (\(bind: roomUUID), \(bind: secondRoom)))::bigint
                        AS sequence_sum
                """).first(decoding: IndependentGroupRoomArtifacts.self))
            #expect(rollback.messages == 4)
            #expect(rollback.sequenceSum == 4)

            try await assertAllAcceptedMessagesHaveCompletions(sql: sql)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("current durable group turns preserve sequence, completion and readable projection")
    func authorizedHybridGroupRoomMessagesPreserveSequence() async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2),
                as: .psql,
                isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(capacityClass: .large, on: sql)

            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10,
                maxCommandsPerWindow: 10,

                retryAfterSeconds: 1
            ))
            let rawWriter = PostgresV2RoomWriteStore(
                database: resources.database(.psql),
                strangerMessagePolicy: try .init(
                    maximumMessagesPerWindow: 10,
                    window: 86_400
                ),
                contentReviewMode: .disabled)

            let requests = try (1 ... 3).map { ordinal in
                V2RoomWriteRequest(
                    command: try .init(
                        roomID: roomID,
                        senderUserID: senderID,
                        clientMessageID: .init(
                            String(format: "00000000-0000-0000-0006-%012x", ordinal)
                        ),
                        text: "同一热群消息 \(ordinal)",
                        limits: .init(maxUTF8Bytes: 128)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init(UUID().uuidString),
                        eventID: .init(UUID().uuidString)
                    ),
                    now: Date(timeIntervalSince1970: 1_750_000_001 + Double(ordinal))
                )
            }

            // Exercise the current durable room turn, rather than the retired
            // cross-room atomic append entrypoint. Keep actual generated IDs and
            // post-commit messages observable for the existing log assertions.
            let database = resources.database(.psql)
            let acceptedAt = requests[0].now
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            let identifiers = Mutex(try requests.flatMap {
                [try #require($0.identifiers.messageID.uuidValue), try #require($0.identifiers.eventID.uuidValue)]
            })
            let factory = V2AcceptanceIDFactory(makeUUID: {
                identifiers.withLock { values in
                    guard !values.isEmpty else { return UUID() }
                    return values.removeFirst()
                }
            })
            let observer = RepeatedGroupCommittedMessages()
            let outcomes = try await withFixturePolicyOwners(database: database,
                projectionDelivery: SuccessfulProjectionDelivery()) { owners in
                let policies = V2RoomPolicyAuthorizationService(roomDatabase: database,
                    policyOwners: owners, endpoint: "room-a", maximumRooms: 1)
                let store = PostgresV2MessageSendOperationStore(database: database,
                    writes: rawWriter.usingControlDatabase(database).usingPolicyAuthorizations(policies),
                    clock: { acceptedAt }, committedMessageObserver: observer)
                do {
                    try await withRoomActivation(database: database, roomID: roomID) { token in
                        let commands = try requests.map {
                            try V2MessageSendOperationCommand(command: $0.command,
                                firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                        }
                        let prepared = try await policies.prepareOwnerBatches(store: store,
                            requests: [.init(commands: commands, token: token, deadline: .now + .seconds(30))],
                            now: { acceptedAt })[0].get()
                        let results = try await store.executePreparedRoomSend(prepared,
                            capacityProfile: profile, identifiers: factory, now: { acceptedAt })
                        try #require(results.count == commands.count)
                        for (command, result) in zip(commands, results) {
                            guard case .sendOperation(.receipt(let receipt)) = result,
                                  case .accepted = receipt.outcome else {
                                throw V2RoomWriteStoreError.corruptPersistenceState
                            }
                            #expect(receipt.validates(identity: try command.identity,
                                fingerprint: try command.fingerprint))
                        }
                    }
                    await policies.shutdown()
                    return observer.outcomes
                } catch {
                    await policies.shutdown()
                    throw error
                }
            }
            #expect(identifiers.withLock { $0.isEmpty })
            #expect(outcomes.count == 3)
            for (index, outcome) in outcomes.enumerated() {
                guard case .accepted(let message) = outcome else {
                    Issue.record("expected accepted repeated-room group message")
                    continue
                }
                try await assertSendCompletion(command: requests[index].command, accepted: message, eventID: requests[index].identifiers.eventID, sql: sql)
                #expect(message.roomSequence == UInt64(index + 1))
                #expect(message.timelineSequence == UInt64(index + 1))
            }

            let messageRows = try await sql.raw("""
                SELECT room_sequence, timeline_sequence
                FROM im_v2.messages
                WHERE room_id = \(bind: roomUUID)
                ORDER BY room_sequence
                """).all(decoding: HybridGroupSequenceRow.self)
            #expect(messageRows.map(\.roomSequence) == [1, 2, 3])
            #expect(messageRows.map(\.timelineSequence) == [1, 2, 3])
            let state = try #require(try await sql.raw("""
                SELECT room_sequence, timeline_sequence,
                       (SELECT count(*) FROM im_v2.room_events
                        WHERE room_id = \(bind: roomUUID)
                          AND event_type = 'message.accepted')::bigint AS events,
                       (SELECT count(*) FROM im_v2.message_projection_states
                        WHERE room_id = \(bind: roomUUID))::bigint AS message_states
                FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)
                """).first(decoding: RepeatedHybridGroupStateRow.self))
            #expect(state.roomSequence == 3)
            #expect(state.timelineSequence == 3)
            // The current group path persists complete events and projection
            // states. Omission was a retired append optimization; the current
            // compact single-statement path applies to direct rooms.
            #expect(state.events == 3)
            #expect(state.messageStates == 3)
            let page = try await PostgresV2GroupEventLogStore(database: resources.database(.psql)).pull(
                roomID: roomID,
                actorUserID: senderID,
                afterRoomSequence: 0,
                pageSize: 10
            )
            #expect(page.events.map(\.roomSequence) == [1, 2, 3])
            #expect(page.events.map(\.sourceEventID) == requests.map(\.identifiers.eventID))

            // A later edit/withdrawal reads the canonical revision-one state
            // with the original source event and accepted sequence.
            let firstMessageID = try #require(
                UUID(uuidString: requests[0].identifiers.messageID.rawValue)
            )
            let materialized = try await PostgresV2MessageProjectionStateRepository()
                .loadCurrentOrMaterialize(messageID: firstMessageID, revision: 1, sql: sql)
            let materializedState = try materialized.state
            #expect(materialized.originEventID.uuidString.lowercased()
                    == requests[0].identifiers.eventID.rawValue.lowercased())
            #expect(materializedState.text == "同一热群消息 1")
            #expect(materializedState.acceptedRoomSequence == 1)

            try await assertAllAcceptedMessagesHaveCompletions(sql: sql)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }

}

private struct PlainHybridGroupBatchArtifacts: Decodable {
    let messages: Int64
    let events: Int64
    let messageStates: Int64
    let readableMessageStates: Int64

    enum CodingKeys: String, CodingKey {
        case messages, events
        case messageStates = "message_states"
        case readableMessageStates = "readable_message_states"
    }
}
private struct IndependentGroupRoomArtifacts: Decodable {
    let messages: Int64
    let sequenceSum: Int64

    enum CodingKeys: String, CodingKey {
        case messages
        case sequenceSum = "sequence_sum"
    }
}
private struct HybridGroupSequenceRow: Decodable {
    let roomSequence: Int64
    let timelineSequence: Int64

    enum CodingKeys: String, CodingKey {
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
    }
}
private final class RepeatedGroupCommittedMessages: V2CommittedMessageBatchObserving, Sendable {
    private let messages = Mutex<[V2SendMessageOutcome]>([])
    var outcomes: [V2SendMessageOutcome] { messages.withLock { $0 } }
    func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome], activation: V2RoomActivationToken) {
        messages.withLock { $0.append(contentsOf: outcomes) }
    }
}

private struct RepeatedHybridGroupStateRow: Decodable {
    let roomSequence: Int64
    let timelineSequence: Int64
    let events: Int64
    let messageStates: Int64

    enum CodingKeys: String, CodingKey {
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case events
        case messageStates = "message_states"
    }
}

private struct RoutedInvitationTestAuthenticator: V2GatewayAuthenticator {
    let user: UserID
    let device = DeviceID(uuid: UUID())
    func authenticateSession(accessToken: String, deviceID: DeviceID) throws -> V2GatewayAuthentication {
        guard accessToken == "invite-test", deviceID == device else { throw V2GatewayAuthenticationError.unauthenticated }
        return .init(userID: user, expiresAt: nil)
    }
}

private struct CancelledInviteCreationResumer: V2GroupInviteCreationResuming {
    func resumeCreation(_ intent: V2GroupInviteCreationIntent, now: Date) async throws { throw CancellationError() }
}

private func capabilityInvitationIntent(actor: UserID, room: RoomID, reference: V2OperationReference,
    action: V2GroupInvitationOperationAction, confirmedAt: Date) throws -> V2GroupInvitationOperationIntent {
    try .init(identity: .init(accountID: actor, scope: .room(room), operation: reference), action: action,
        confirmedUntilMilliseconds: UInt64(confirmedAt.timeIntervalSince1970 * 1_000) + 120_000)
}
private func capabilityInvitationAdmission(_ coordinator: V2ActorInvitationCoordinator,
    intent: V2GroupInvitationOperationIntent, secret: V2GroupInviteSecret? = nil) async throws -> V2GroupInvitationSubmission {
    let authorization = secret.map(V2GroupInvitationSecretAuthorization.init(secret:))
    guard case .admitted(let admission) = try await coordinator.admitOperation(.init(intent: intent, secretAuthorization: authorization), deadline: invitationTestDeadline()) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
    return try .init(command: .init(intent: intent, admission: admission), secretAuthorization: authorization)
}
private func capabilityInvitationProof(_ result: V2GroupInvitationOperationRecoveryResult,
    intent: V2GroupInvitationOperationIntent) throws -> V2GroupInvitationOperationReceipt {
    guard case .receipt(let proof) = result, proof.validates(intent: intent) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }; return proof
}

private final class CapabilityInvitationResponseLoss: Sendable {
    private let armed = Mutex(true)
    func consume() -> Bool { armed.withLock { value in let previous = value; value = false; return previous } }
}
private struct CapabilityInvitationStateRow: Decodable { let state: String }
