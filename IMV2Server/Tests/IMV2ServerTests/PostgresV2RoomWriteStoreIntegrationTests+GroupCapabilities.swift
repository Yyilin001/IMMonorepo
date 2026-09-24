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
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: owner), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: room, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "original")) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: room.uuidValue!), 'room-b', 1, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
            let router = V2PostgresRoomShardRouter(database: control)
            let operation = UUID()
            @Sendable func run(_ route: any V2RoomShardRouting, on database: any Database, operationID: UUID, colocated: Bool = false, local: Bool = false) async throws -> String {
                let ownerStore = PostgresV2GroupCapabilitiesStore(database: database)
                let stores = colocated ? ["room-b": ownerStore, "colocated": ownerStore] : ["room-b": ownerStore]
                let routed: any V2GroupCapabilitiesStore = local ? ownerStore : try V2RoutedGroupCapabilitiesStore(router: route, stores: stores,
                    physicalStoreKeyByShard: colocated ? ["room-b": "physical-owner", "colocated": "physical-owner"] : nil)
                let event = EventID(uuid: UUID())
                switch kind {
                case "pin":
                    let result = try await routed.setPinnedMessage(actorUserID: senderID, command: .init(operationID: .init(uuid: operationID), roomID: room, messageID: message.messageID, isPinned: true), capacityProfile: profile, eventID: event, now: now)
                    switch result { case .applied: return "changed"; case .idempotent: return "replay"; default: return "other" }
                case "announcement":
                    let result = try await routed.setAnnouncement(actorUserID: senderID, command: .init(operationID: .init(uuid: operationID), roomID: room, body: "owner announcement", expectedRevision: 0), capacityProfile: profile, eventID: event, now: now)
                    switch result { case .applied: return "changed"; case .idempotent: return "replay"; default: return "other" }
                case "permissions":
                    let result = try await routed.setRolePermissions(actorUserID: senderID, command: .init(operationID: .init(uuid: operationID), roomID: room, role: .member, permissions: [], expectedRevision: 1), capacityProfile: profile, eventID: event, now: now)
                    switch result { case .applied: return "changed"; case .idempotent: return "replay"; default: return "other" }
                default:
                    let result = try await routed.changeMemberRole(actorUserID: senderID, command: .init(operationID: .init(uuid: operationID), roomID: room, targetUserID: .init(uuid: memberTwoUUID), role: .admin, expectedMembershipRevision: 1), capacityProfile: profile, eventID: event, now: now)
                    switch result { case .applied: return "changed"; case .idempotent: return "replay"; default: return "other" }
                }
            }
            let table = kind == "pin" ? "room_pinned_message_operations" : kind == "announcement" ? "group_announcement_operations" : kind == "permissions" ? "group_permission_operations" : "group_role_operations"
            let before = try await ownerSQL.raw("SELECT to_jsonb(x)::text AS value FROM im_v2.rooms x WHERE room_id=\(bind: room.uuidValue!)").first(decoding: StringValueRow.self)?.value
            let sequenceBefore = try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await run(router, on: owner, operationID: operation) }
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 0)
            #expect(try await ownerSQL.raw("SELECT to_jsonb(x)::text AS value FROM im_v2.rooms x WHERE room_id=\(bind: room.uuidValue!)").first(decoding: StringValueRow.self)?.value == before)
            #expect(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value == sequenceBefore)
            // Even the self-role no-op must validate its selected owner.
            if kind == "role" {
                let routed = try V2RoutedGroupCapabilitiesStore(router: router, stores: ["room-b": PostgresV2GroupCapabilitiesStore(database: owner)])
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                    _ = try await routed.changeMemberRole(actorUserID: senderID,
                        command: .init(operationID: .init(uuid: UUID()), roomID: room, targetUserID: senderID, role: .admin, expectedMembershipRevision: 1),
                        capacityProfile: profile, eventID: .init(uuid: UUID()), now: now)
                }
            }
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=0 WHERE room_id=\(bind: room.uuidValue!)").run()
            let cached = V2CachedRoomShardRouter(source: router)
            _ = try await cached.route(for: room)
            let outcomes = try await withThrowingTaskGroup(of: String.self) { tasks in
                for _ in 0..<10 { tasks.addTask { try await run(router, on: owner, operationID: operation) } }
                var values: [String] = []
                for try await value in tasks { values.append(value) }
                return values
            }
            #expect(outcomes.filter { $0 == "changed" }.count == 1 && outcomes.filter { $0 == "replay" }.count == 9)
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            for op in [operation, UUID()] {
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await run(cached, on: owner, operationID: op, colocated: true) }
            }
            #expect(try await run(router, on: owner, operationID: operation) == "replay")
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
            #expect(try await run(router, on: owner, operationID: operation) == "replay")
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
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: owner), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: room, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "original")) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: room.uuidValue!), 'room-b', 1, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
            let router = V2PostgresRoomShardRouter(database: control)
            let operation = UUID()
            let identities = V2PostgresMembershipIdentitySnapshotValidator(database: control)
            @Sendable func run(_ route: any V2RoomShardRouting, on database: any Database, operationID: UUID, local: Bool = false) async throws -> String {
                switch kind {
                case "edit":
                    let store = PostgresV2MessageEditStore(database: database, contentReviewMode: .disabled, identities: identities)
                    let routed: any V2MessageEditStore = local ? store : try V2RoutedMessageEditStore(router: route, stores: ["room-b": store])
                    let result = try await routed.edit(command: .init(roomID: room, actorUserID: senderID, operationID: .init(uuid: operationID), messageID: message.messageID, expectedMessageRevision: 1, text: "edited", maximumUTF8Bytes: 64), capacityProfile: profile, eventID: .init(uuid: UUID()), now: now.addingTimeInterval(1))
                    switch result { case .edited: return "changed"; case .idempotent: return "replay"; default: return "other" }
                case "withdraw":
                    let store = PostgresV2MessageWithdrawalStore(database: database)
                    let routed: any V2MessageWithdrawalStore = local ? store : try V2RoutedMessageWithdrawalStore(router: route, stores: ["room-b": store])
                    let result = try await routed.withdraw(command: .init(roomID: room, actorUserID: senderID, operationID: .init(uuid: operationID), messageID: message.messageID, expectedMessageRevision: 1), capacityProfile: profile, eventID: .init(uuid: UUID()), now: now.addingTimeInterval(1))
                    switch result { case .withdrawn: return "changed"; case .idempotent: return "replay"; default: return "other" }
                default:
                    let store = PostgresV2MessageReactionStore(database: database)
                    let routed: any V2MessageReactionStore = local ? store : try V2RoutedMessageReactionStore(router: route, stores: ["room-b": store])
                    let result = try await routed.change(command: .init(roomID: room, actorUserID: senderID, operationID: .init(uuid: operationID), messageID: message.messageID, reaction: "👍", action: .add), capacityProfile: profile, eventID: .init(uuid: UUID()), now: now.addingTimeInterval(1))
                    switch result { case .changed: return "changed"; case .idempotent: return "replay"; default: return "other" }
                }
            }
            let table = kind == "edit" ? "message_edit_operations" : kind == "withdraw" ? "message_withdrawal_operations" : "message_reaction_operations"
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
            #expect(outcomes.filter { $0 == "changed" }.count == 1 && outcomes.filter { $0 == "replay" }.count == 9)
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            for op in [operation, UUID()] {
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await run(cached, on: owner, operationID: op) }
            }
            #expect(try await run(router, on: owner, operationID: operation) == "replay")
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
            #expect(try await run(router, on: owner, operationID: operation) == "replay")
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 1)
            #expect(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value == sequenceBefore.map { $0 + 1 })
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.public_user_profiles").first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 0)
        }
    }

    @Test("routed ordinary membership rejects a stale owner before writing or replaying", arguments: [V2GroupCapacityClass.standard, .large])
    func routedMembershipOwnerEpochFence(_ mode: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: mode) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: room.uuidValue!), 'room-b', 1, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
            let router = V2PostgresRoomShardRouter(database: control)
            let identities = V2PostgresMembershipIdentitySnapshotValidator(database: control)
            let routed = try V2RoutedRoomMembershipStore(router: router,
                stores: ["room-b": PostgresV2RoomMembershipStore(database: owner)], identities: identities)
            let command = try V2ChangeRoomMembershipCommand(roomID: room, actorUserID: .init(uuid: senderUUID),
                operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID), action: .remove, expectedMembershipRevision: 0)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            await #expect(throws: V2RoomMembershipStoreError.ownerChanged) {
                _ = try await routed.change(command: command, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now)
            }
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.room_membership_operations").first(decoding: CountRow.self)?.value == 0)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.room_memberships WHERE left_revision IS NULL").first(decoding: CountRow.self)?.value == 3)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.room_events").first(decoding: CountRow.self)?.value == 0)
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=0 WHERE room_id=\(bind: room.uuidValue!)").run()
            let cachedRouter = V2CachedRoomShardRouter(source: router)
            _ = try await cachedRouter.route(for: room)
            let cached = try V2RoutedRoomMembershipStore(router: cachedRouter,
                stores: ["room-b": PostgresV2RoomMembershipStore(database: owner), "same-physical": PostgresV2RoomMembershipStore(database: owner)],
                identities: identities, physicalStoreKeyByShard: ["room-b": "owner-b", "same-physical": "owner-b"])
            let results = try await withThrowingTaskGroup(of: V2RoomMembershipChangeOutcome.self) { tasks in
                for _ in 0..<10 { tasks.addTask { try await routed.change(command: command, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) } }
                var values: [V2RoomMembershipChangeOutcome] = []
                for try await value in tasks { values.append(value) }
                return values
            }
            #expect(results.count == 10)
            #expect(results.filter { if case .changed = $0 { true } else { false } }.count == 1)
            #expect(results.filter { if case .idempotent = $0 { true } else { false } }.count == 9)
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            let add = try V2ChangeRoomMembershipCommand(roomID: room, actorUserID: .init(uuid: senderUUID),
                operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID), action: .add, expectedMembershipRevision: 1)
            for stale in [command, add] {
                await #expect(throws: V2RoomMembershipStoreError.ownerChanged) {
                    _ = try await cached.change(command: stale, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now)
                }
            }
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.room_membership_operations").first(decoding: CountRow.self)?.value == 1)
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
            guard case .idempotent(let prior) = try await routed.change(command: command, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) else {
                Issue.record("fresh owner must replay the original membership result"); return
            }
            #expect(prior.membershipRevision == 1)
            await #expect(throws: V2RoomMembershipStoreError.actorNotOwner) {
                _ = try await routed.change(command: add, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now)
            }
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='active' WHERE user_id=\(bind: senderUUID)").run()
            guard case .changed(let added) = try await routed.change(command: add, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) else {
                Issue.record("fresh owner must allow the new authorized operation"); return
            }
            #expect(added.membershipRevision == 2)
            let wrong = try V2RoutedRoomMembershipStore(router: router, stores: ["room-b": PostgresV2RoomMembershipStore(database: control)], identities: identities)
            await #expect(throws: V2RoomMembershipStoreError.ownerChanged) {
                _ = try await wrong.change(command: command, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now)
            }
            try await sql.raw("UPDATE im_v2.room_owner_routes SET room_shard_id='unregistered' WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: V2RoomShardStorageRegistryError.unknownShardID) {
                _ = try await routed.change(command: command, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now)
            }
            try await sql.raw("UPDATE im_v2.room_owner_routes SET room_shard_id='room-b' WHERE room_id=\(bind: room.uuidValue!)").run()
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
            let queuedCommand = try V2ChangeRoomMembershipCommand(roomID: room, actorUserID: .init(uuid: senderUUID), operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberThreeUUID), action: .remove, expectedMembershipRevision: 2)
            let queued = Task { try await routed.change(command: queuedCommand, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) }
            do {
                var waiting = false
                for _ in 0..<1000 {
                    waiting = try await ownerSQL.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%owner_epoch, room_sequence%'").first(decoding: CountRow.self)?.value == 1
                    if waiting { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(waiting)
                guard waiting else { throw TestConfigurationError.schemaAlreadyExists }
                try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=2 WHERE room_id=\(bind: room.uuidValue!)").run()
                await barrier.release(); try await holder.value
                await #expect(throws: V2RoomMembershipStoreError.ownerChanged) { _ = try await queued.value }
            } catch {
                await barrier.release(); _ = try? await holder.value; _ = try? await queued.value
                throw error
            }
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.room_membership_operations").first(decoding: CountRow.self)?.value == 2)
            guard case .changed(let retried) = try await routed.change(command: queuedCommand, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) else {
                Issue.record("retry on the new owner epoch must use the unconsumed operation"); return
            }
            #expect(retried.membershipRevision == 3)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.public_user_profiles").first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.room_membership_operations").first(decoding: CountRow.self)?.value == 0)
        }
    }


    @Test("legacy owner creation retry publishes its original binding and preserves terminal state", arguments: [V2GroupCapacityClass.standard, .large])
    func legacyInviteCreationRetryPreservesOwnerBinding(_ mode: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: mode) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000.123456)
            let actor = UserID(uuid: senderUUID)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: room.uuidValue!), 'room-b', 0, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
            let registry = try V2StaticRoomShardStorageRegistry(locations: [.init(shardID: "room-b", database: owner, schema: "im_v2")])
            let routed = V2RoutedGroupInvitationStore(controlDatabase: control, router: V2PostgresRoomShardRouter(database: control), owners: registry)
            let directory = PostgresV2GroupInviteDirectory(database: control)
            let legacy = PostgresV2GroupInvitationStore(database: owner,
                identities: PostgresV2GroupInvitationIdentityReader(database: control),
                scope: .init(roomID: room.uuidValue!, route: try .init(shardID: "room-b", epoch: 0), inviteID: nil))
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x71, count: 32))
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            for state in [V2GroupInviteState.active, .expired, .revoked, .exhausted] {
                try await sql.raw("UPDATE im_v2.public_user_profiles SET state='active' WHERE user_id=\(bind: senderUUID)").run()
                let operation = GroupInviteOperationID(uuid: UUID())
                let secret = try issuer.secret(actorUserID: actor, operationID: operation)
                let original = V2GroupInviteCreatePersistenceRequest(inviteID: .init(uuid: UUID()), roomID: room,
                    actorUserID: actor, operationID: operation, tokenDigest: issuer.digest(secret),
                    requestedLifetimeSeconds: 3600, expiresAt: now.addingTimeInterval(3600),
                    maximumApprovedUses: 5, maximumActiveInvitesPerRoom: 20, createdAt: now)
                let stored = try await legacy.create(original)
                if state == .revoked {
                    try await legacy.revoke(inviteID: stored.inviteID, roomID: room, actorUserID: actor,
                        operationID: .init(uuid: UUID()), now: now.addingTimeInterval(1))
                } else if state == .exhausted {
                    try await ownerSQL.raw("UPDATE im_v2.group_invite_links SET approved_use_count=maximum_approved_uses WHERE invite_id=\(bind: stored.inviteID.uuidValue!)").run()
                }
                let later = now.addingTimeInterval(state == .expired ? 3601 : 30)
                @Sendable func retry(digest: Data? = nil, lifetime: Int = 3600, uses: Int = 5) -> V2GroupInviteCreatePersistenceRequest {
                    .init(inviteID: .init(uuid: UUID()), roomID: room, actorUserID: actor, operationID: original.operationID,
                        tokenDigest: digest ?? original.tokenDigest, requestedLifetimeSeconds: lifetime,
                        expiresAt: later.addingTimeInterval(Double(lifetime)), maximumApprovedUses: uses,
                        maximumActiveInvitesPerRoom: 20, createdAt: later)
                }
                for changed in [retry(digest: Data(repeating: 0xf1, count: 32)), retry(lifetime: 7200), retry(uses: 6)] {
                    await #expect(throws: V2GroupInvitationServiceError.conflict) { _ = try await routed.create(changed) }
                }
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory WHERE operation_id=\(bind: original.operationID.uuidValue!)").first(decoding: CountRow.self)?.value == 0)
                if state != .active {
                    // Recovering a committed creation grants no new authority.
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
                }
                let results = try await withThrowingTaskGroup(of: V2StoredGroupInvite.self) { tasks in
                    for _ in 0..<10 { tasks.addTask { try await routed.create(retry()) } }
                    var values: [V2StoredGroupInvite] = []
                    for try await value in tasks { values.append(value) }
                    return values
                }
                #expect(results.count == 10)
                #expect(results.allSatisfy { $0.inviteID == stored.inviteID && $0.createdAt == stored.createdAt
                    && $0.expiresAt == stored.expiresAt && $0.state == state
                    && $0.approvedUseCount == (state == .exhausted ? 5 : 0) })
                #expect(try await directory.resolve(tokenDigest: original.tokenDigest) == .init(inviteID: stored.inviteID, roomID: room))
                let published = try await directory.prepare(retry())
                #expect(published.isReady && published.request.inviteID == stored.inviteID)
                #expect(published.request.createdAt == stored.createdAt && published.request.expiresAt == stored.expiresAt)
                #expect(published.request.evaluatedAt == later)
                let service = V2GroupInvitationService(store: routed, capacityProfile: profile, secretIssuer: issuer, now: { later })
                let response = try await service.create(.init(roomID: room, actorUserID: actor, operationID: operation, lifetime: 3600, maximumApprovedUses: 5))
                #expect(response.inviteID == stored.inviteID && response.secret == secret && response.state == state)
                #expect(response.createdAt == stored.createdAt && response.expiresAt == stored.expiresAt)
                let preview = try await service.preview(secret: secret, applicantUserID: .init(uuid: memberTwoUUID))
                #expect((preview != nil) == (state == .active || state == .exhausted))
                #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links WHERE creation_operation_id=\(bind: original.operationID.uuidValue!)").first(decoding: CountRow.self)?.value == 1)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_creation_recovery WHERE operation_id=\(bind: original.operationID.uuidValue!) AND state='completed'").first(decoding: CountRow.self)?.value == 1)
            }
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.public_user_profiles").first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory").first(decoding: CountRow.self)?.value == 4)
            print("PASS legacy binding: four states, changed input rejected, ten concurrent retries each, original ID/time/use count preserved, no owner profiles")
        }
    }

    @Test("legacy creation retry recovers publication failure but never rewrites contradictory bindings")
    func legacyInviteCreationRetryFencesAndRecovery() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let actor = UserID(uuid: senderUUID)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: room.uuidValue!), 'room-b', 0, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
            let registry = try V2StaticRoomShardStorageRegistry(locations: [.init(shardID: "room-b", database: owner, schema: "im_v2")])
            let routed = V2RoutedGroupInvitationStore(controlDatabase: control, router: V2PostgresRoomShardRouter(database: control), owners: registry)
            let directory = PostgresV2GroupInviteDirectory(database: control)
            let legacy = PostgresV2GroupInvitationStore(database: owner,
                identities: PostgresV2GroupInvitationIdentityReader(database: control),
                scope: .init(roomID: room.uuidValue!, route: try .init(shardID: "room-b", epoch: 0), inviteID: nil))
            func candidate(_ byte: UInt8, operation: GroupInviteOperationID? = nil, invite: GroupInviteID? = nil, time: Date? = nil) -> V2GroupInviteCreatePersistenceRequest {
                let time = time ?? now
                return .init(inviteID: invite ?? .init(uuid: UUID()), roomID: room, actorUserID: actor,
                    operationID: operation ?? .init(uuid: UUID()), tokenDigest: Data(repeating: byte, count: 32),
                    requestedLifetimeSeconds: 3600, expiresAt: time.addingTimeInterval(3600),
                    maximumApprovedUses: 5, maximumActiveInvitesPerRoom: 20, createdAt: time)
            }
            let original = candidate(0x91)
            _ = try await legacy.create(original)
            let retry = candidate(0x91, operation: original.operationID, time: now.addingTimeInterval(10))
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: V2GroupInvitationServiceError.ownerChanged) { _ = try await routed.create(retry) }
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory").first(decoding: CountRow.self)?.value == 0)
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=0 WHERE room_id=\(bind: room.uuidValue!)").run()
            try await sql.raw("CREATE FUNCTION im_v2.fail_legacy_invite_ready() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'test publication failure'; END;$$").run()
            try await sql.raw("CREATE TRIGGER test_legacy_invite_ready BEFORE UPDATE ON im_v2.group_invite_directory FOR EACH ROW EXECUTE FUNCTION im_v2.fail_legacy_invite_ready()").run()
            await #expect(throws: (any Error).self) { _ = try await routed.create(retry) }
            let prepared = try await directory.prepare(retry)
            #expect(!prepared.isReady && prepared.request.inviteID == original.inviteID)
            #expect(prepared.request.createdAt == original.createdAt && prepared.request.expiresAt == original.expiresAt)
            #expect(try await directory.resolve(tokenDigest: original.tokenDigest) == nil)
            try await sql.raw("DROP TRIGGER test_legacy_invite_ready ON im_v2.group_invite_directory").run()
            try await sql.raw("DROP FUNCTION im_v2.fail_legacy_invite_ready()").run()
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: senderUUID)").run()
            let later = now.addingTimeInterval(61)
            let recovered = try await V2GroupInviteCreationRecoveryWorker(jobs: directory, invitations: routed, now: { later }).runOnce()
            #expect(recovered.attempted == 1 && recovered.completed == 1)
            #expect(try await directory.resolve(tokenDigest: original.tokenDigest)?.inviteID == original.inviteID)
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='active' WHERE user_id=\(bind: senderUUID)").run()

            // A previously poisoned intent must not silently overwrite either
            // side, even when preflight now finds the authoritative owner link.
            let second = candidate(0x92)
            _ = try await legacy.create(second)
            let contradictory = candidate(0x92, operation: second.operationID, time: now.addingTimeInterval(10))
            _ = try await directory.prepare(contradictory)
            await #expect(throws: V2GroupInviteDirectoryError.ownerResultMismatch) { _ = try await routed.create(contradictory) }
            let paused = try await V2GroupInviteCreationRecoveryWorker(jobs: directory, invitations: routed, now: { later }).runOnce()
            #expect(paused.attempted == 1 && paused.paused == 1)
            let unchanged = try await directory.prepare(contradictory)
            #expect(!unchanged.isReady && unchanged.request.inviteID == contradictory.inviteID)
            #expect(unchanged.request.createdAt == contradictory.createdAt && unchanged.request.expiresAt == contradictory.expiresAt)
            #expect(try await directory.resolve(tokenDigest: second.tokenDigest) == nil)
            #expect(try await legacy.create(second).inviteID == second.inviteID)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_creation_recovery WHERE operation_id=\(bind: second.operationID.uuidValue!) AND state='paused' AND last_error_code='conflicting_evidence'").first(decoding: CountRow.self)?.value == 1)

            // Other operations already owning this digest or invite ID also
            // fail without reassigning their directory keys or owner receipts.
            for (index, sameDigest) in [true, false].enumerated() {
                let byte = UInt8(0xa1 + index)
                let ownerRequest = candidate(byte)
                _ = try await legacy.create(ownerRequest)
                let collision = candidate(sameDigest ? byte : 0xff,
                    invite: sameDigest ? nil : ownerRequest.inviteID)
                _ = try await directory.prepare(collision)
                await #expect(throws: V2GroupInviteDirectoryError.conflict) { _ = try await routed.create(ownerRequest) }
                #expect(try await directory.prepare(collision).request.operationID == collision.operationID)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory WHERE operation_id=\(bind: ownerRequest.operationID.uuidValue!)").first(decoding: CountRow.self)?.value == 0)
                #expect(try await legacy.create(ownerRequest).inviteID == ownerRequest.inviteID)
            }
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 4)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory WHERE state='ready'").first(decoding: CountRow.self)?.value == 1)
            print("PASS legacy fences: stale epoch before allocation, original binding survives publication failure, background recovery after suspension, immutable conflicts and unique collisions")
        }
    }

    @Test("invite directory survives owner response loss and finalize failure across databases")
    func inviteDirectoryCreationRecovery() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, room in
            let actor = UserID(uuid: senderUUID)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: room.uuidValue!) AND user_id = \(bind: senderUUID)").run()
            #expect(try await controlSQL.raw("SELECT COUNT(*) AS value FROM im_v2.room_memberships WHERE room_id = \(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value == 0)
            let directory = PostgresV2GroupInviteDirectory(database: control)
            let coordinator = V2GroupInviteCreationCoordinator(directory: directory)
            let ownerStore = PostgresV2GroupInvitationStore(database: owner)
            let operation = GroupInviteOperationID(uuid: UUID())
            let invite = GroupInviteID(uuid: UUID())
            let digest = Data(repeating: 0xa7, count: 32)
            let now = Date(timeIntervalSince1970: 1_750_000_000.123456)
            @Sendable func candidate(inviteID: GroupInviteID = .init(uuid: UUID()), operationID: GroupInviteOperationID? = nil, roomID: RoomID? = nil, token: Data? = nil, uses: Int = 5, offset: Double = 0) -> V2GroupInviteCreatePersistenceRequest {
                .init(inviteID: inviteID, roomID: roomID ?? room, actorUserID: actor,
                      operationID: operationID ?? operation, tokenDigest: token ?? digest,
                      requestedLifetimeSeconds: 3600, expiresAt: now.addingTimeInterval(3600 + offset),
                      maximumApprovedUses: uses, maximumActiveInvitesPerRoom: 20,
                      createdAt: now.addingTimeInterval(offset))
            }
            let intent = try await directory.prepare(candidate(inviteID: invite))
            #expect(!intent.isReady)
            #expect(try await directory.resolve(tokenDigest: digest) == nil)
            // Commit on a real, independent owner and lose the response.
            await #expect(throws: ProfilePropagationShadowFailure.interrupted) {
                _ = try await coordinator.create(candidate(offset: 10)) { fixed in
                    _ = try await ownerStore.create(fixed)
                    throw ProfilePropagationShadowFailure.interrupted
                }
            }
            #expect(try await directory.resolve(tokenDigest: digest) == nil)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
            // Owner replay succeeds but control's final write fails. Nothing is
            // published and neither the original invite nor expiry is replaced.
            try await controlSQL.raw("CREATE FUNCTION im_v2.fail_invite_directory_ready() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'test finalize failure'; END;$$").run()
            try await controlSQL.raw("CREATE TRIGGER test_invite_directory_ready AFTER UPDATE ON im_v2.group_invite_directory FOR EACH ROW EXECUTE FUNCTION im_v2.fail_invite_directory_ready()").run()
            await #expect(throws: (any Error).self) {
                _ = try await coordinator.create(candidate(offset: 20)) { try await ownerStore.create($0) }
            }
            #expect(try await directory.resolve(tokenDigest: digest) == nil)
            try await controlSQL.raw("DROP TRIGGER test_invite_directory_ready ON im_v2.group_invite_directory").run()
            try await controlSQL.raw("DROP FUNCTION im_v2.fail_invite_directory_ready()").run()
            let recreated = V2GroupInviteCreationCoordinator(directory: PostgresV2GroupInviteDirectory(database: control))
            let results = try await withThrowingTaskGroup(of: V2StoredGroupInvite.self) { tasks in
                for index in 0..<10 {
                    tasks.addTask {
                        try await recreated.create(candidate(offset: Double(30 + index))) { fixed in
                            #expect(fixed.inviteID == invite)
                            #expect(fixed.createdAt == intent.request.createdAt)
                            return try await ownerStore.create(fixed)
                        }
                    }
                }
                var results: [V2StoredGroupInvite] = []
                for try await result in tasks { results.append(result) }
                return results
            }
            #expect(results.count == 10)
            #expect(results.allSatisfy { $0.inviteID == invite && $0.expiresAt == intent.request.expiresAt })
            #expect(try await directory.resolve(tokenDigest: digest) == .init(inviteID: invite, roomID: room))
            #expect(try await directory.prepare(candidate()).isReady)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
            #expect(try await controlSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory").first(decoding: CountRow.self)?.value == 1)
            for changed in [candidate(roomID: .init(uuid: UUID())), candidate(token: Data(repeating: 0xb7, count: 32)), candidate(uses: 6), candidate(operationID: .init(uuid: UUID())), candidate(inviteID: invite, operationID: .init(uuid: UUID()), token: Data(repeating: 0xb7, count: 32))] {
                await #expect(throws: V2GroupInviteDirectoryError.conflict) { _ = try await directory.prepare(changed) }
            }
            // Even a ready locator does not confer validity after revoke.
            try await ownerStore.revoke(inviteID: invite, roomID: room, actorUserID: actor, operationID: .init(uuid: UUID()), now: now.addingTimeInterval(50))
            #expect(try await directory.resolve(tokenDigest: digest) != nil)
            #expect(try await ownerStore.preview(tokenDigest: digest, applicantUserID: .init(uuid: memberTwoUUID), now: now.addingTimeInterval(51)) == .unavailable)
            for mutation in ["UPDATE im_v2.group_invite_directory SET state = 'prepared', ready_at = NULL", "UPDATE im_v2.group_invite_directory SET room_id = gen_random_uuid()", "DELETE FROM im_v2.group_invite_directory"] {
                await #expect(throws: (any Error).self) { try await controlSQL.raw("\(unsafeRaw: mutation)").run() }
            }
            let interruptedDigest = Data(repeating: 0xc7, count: 32)
            let interrupted = candidate(operationID: .init(uuid: UUID()), token: interruptedDigest)
            await #expect(throws: ProfilePropagationShadowFailure.interrupted) {
                _ = try await coordinator.create(interrupted) { _ in throw ProfilePropagationShadowFailure.interrupted }
            }
            #expect(try await directory.resolve(tokenDigest: interruptedDigest) == nil)
            let wrongOwnerResult = try #require(results.first)
            await #expect(throws: V2GroupInviteDirectoryError.ownerResultMismatch) {
                _ = try await coordinator.create(interrupted) { _ in wrongOwnerResult }
            }
            #expect(try await directory.resolve(tokenDigest: interruptedDigest) == nil)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
            // Independent operations race for one digest; exactly one binds it.
            let contestedDigest = Data(repeating: 0xd7, count: 32)
            let winners = try await withThrowingTaskGroup(of: Bool.self) { tasks in
                for _ in 0..<2 {
                    let contender = candidate(operationID: .init(uuid: UUID()), token: contestedDigest)
                    tasks.addTask {
                        do { _ = try await directory.prepare(contender); return true }
                        catch V2GroupInviteDirectoryError.conflict { return false }
                    }
                }
                var winners = 0
                for try await won in tasks { if won { winners += 1 } }
                return winners
            }
            #expect(winners == 1)
            #expect(try await directory.resolve(tokenDigest: contestedDigest) == nil)
            await #expect(throws: V2GroupInviteDirectoryError.invalidRequest) { _ = try await directory.resolve(tokenDigest: Data()) }
            #expect(try await directory.resolve(tokenDigest: Data(repeating: 0xee, count: 32)) == nil)
            try await V2SchemaReadiness.verify(database: control)
            try await assertSQLSchemaGate(true, on: controlSQL)
            try await controlSQL.raw("ALTER TABLE im_v2.group_invite_directory DISABLE TRIGGER group_invite_directory_immutable").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.group_invite_directory[intent-binding]")) { try await V2SchemaReadiness.verify(database: control) }
            try await assertSQLSchemaGate(false, on: controlSQL)
            try await controlSQL.raw("ALTER TABLE im_v2.group_invite_directory ENABLE TRIGGER group_invite_directory_immutable").run()
            print("PASS invite directory: independent owner commit/response loss, finalize rollback, ten concurrent retries, stable identity/expiry, collision rejection, owner revoke, immutable binding/readiness")
        }
    }

    @Test("control identity and token directory drive two profile-free room owners", arguments: [V2GroupCapacityClass.standard, .large])
    func routedInvitationsUseControlIdentity(_ mode: V2GroupCapacityClass) async throws {
        guard let controlURL = Environment.get("IMV2_POSTGRES_TEST_CONTROL_DATABASE_URL"),
              controlURL != Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              controlURL != Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        try await withForwardOwnerDatabases(mode: mode) { ownerA, ownerB, sqlA, sqlB, roomB in
            let resources = makeV2DatabaseTestResources()
        let app = try await Application(.testing)
            do {
                resources.databases.use(try .postgres(url: controlURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
                let control = resources.database(.psql), sql = try #require(control as? any SQLDatabase)
                guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
                try await installSchema(on: sql)
                let now = Date(timeIntervalSince1970: 1_750_000_000)
                let actor = UserID(uuid: senderUUID), applicant = UserID(uuid: UUID()), rejectedApplicant = UserID(uuid: UUID())
                for (id, handle) in [(actor, "invite_owner"), (applicant, "invite_applicant"), (rejectedApplicant, "invite_rejected")] {
                    try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES (\(bind: id.uuidValue!),\(bind: handle),'Control Profile',\(bind: now),\(bind: now))").run()
                }
                for ownerSQL in [sqlA, sqlB] {
                    try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
                    try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
                }
                let roomA = RoomID(uuid: roomUUID)
                for (room, shard) in [(roomA, "room-a"), (roomB, "room-b")] {
                    try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: room.uuidValue!),\(bind: shard),0,\(bind: now),\(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
                }
                let registry = try V2StaticRoomShardStorageRegistry(locations: [
                    .init(shardID: "room-a", database: ownerA, schema: "im_v2"),
                    .init(shardID: "room-b", database: ownerB, schema: "im_v2")
                ])
                let router = V2PostgresRoomShardRouter(database: control)
                let routed = V2RoutedGroupInvitationStore(controlDatabase: control, router: router, owners: registry)
                let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
                let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x81, count: 32))
                let service = V2GroupInvitationService(store: routed, capacityProfile: profile, secretIssuer: issuer, now: { now })
                var completedApprovals: [V2DecideGroupJoinRequest] = []
                for (room, ownerSQL) in [(roomA, sqlA), (roomB, sqlB)] {
                    let create = V2CreateGroupInviteRequest(roomID: room, actorUserID: actor, operationID: .init(uuid: UUID()), lifetime: 3600, maximumApprovedUses: 5)
                    // Directory failure after owner commit must not leak a token
                    // via management listing while the intent is still prepared.
                    try await sql.raw("CREATE FUNCTION im_v2.fail_routed_invite_ready() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'test unavailable'; END;$$").run()
                    try await sql.raw("CREATE TRIGGER test_routed_invite_ready AFTER UPDATE ON im_v2.group_invite_directory FOR EACH ROW EXECUTE FUNCTION im_v2.fail_routed_invite_ready()").run()
                    await #expect(throws: (any Error).self) { _ = try await service.create(create) }
                    #expect(try await service.activeInvites(roomID: room, actorUserID: actor).isEmpty)
                    try await sql.raw("DROP TRIGGER test_routed_invite_ready ON im_v2.group_invite_directory").run()
                    try await sql.raw("DROP FUNCTION im_v2.fail_routed_invite_ready()").run()
                    let link = try await service.create(create)
                    #expect(try await service.activeInvites(roomID: room, actorUserID: actor).count == 1)
                    #expect(try await service.preview(secret: link.secret, applicantUserID: applicant)?.roomID == room)
                    guard case .submitted(let first) = try await service.submit(.init(applicantUserID: applicant, operationID: .init(uuid: UUID()), secret: link.secret, note: "join")),
                          case .submitted(let second) = try await service.submit(.init(applicantUserID: rejectedApplicant, operationID: .init(uuid: UUID()), secret: link.secret, note: nil)) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET display_name = 'Current Control Name' WHERE user_id = \(bind: applicant.uuidValue!)").run()
                    let page = try await service.pendingRequests(roomID: room, reviewerUserID: actor, cursor: nil, pageSize: 100)
                    #expect(page.requests.count == 2)
                    #expect(page.requests.contains { $0.applicant.userID == applicant && $0.applicant.displayName == "Current Control Name" })
                    let approve = V2DecideGroupJoinRequest(roomID: room, requestID: first.requestID, reviewerUserID: actor, operationID: .init(uuid: UUID()), decision: .approve)
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET state = 'suspended' WHERE user_id = \(bind: applicant.uuidValue!)").run()
                    guard case .unavailable = try await service.decide(approve) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                    #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.room_membership_operations").first(decoding: CountRow.self)?.value == 0)
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET state = 'active' WHERE user_id = \(bind: applicant.uuidValue!)").run()
                    guard case .approved = try await service.decide(approve) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                    try await sql.raw("INSERT INTO im_v2.account_disables(user_id,operation_id,reason,operator_principal,disabled_at) VALUES (\(bind: actor.uuidValue!),\(bind: UUID()),'policy_enforcement','test.operator',\(bind: now))").run()
                    guard case .approved = try await service.decide(approve) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                    await #expect(throws: V2GroupInvitationServiceError.permissionDenied) {
                        _ = try await service.decide(.init(roomID: room, requestID: second.requestID, reviewerUserID: actor, operationID: .init(uuid: UUID()), decision: .reject))
                    }
                    try await sql.raw("DELETE FROM im_v2.account_disables WHERE user_id = \(bind: actor.uuidValue!)").run()
                    guard case .rejected = try await service.decide(.init(roomID: room, requestID: second.requestID, reviewerUserID: actor, operationID: .init(uuid: UUID()), decision: .reject)) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
                    #expect(try await service.pendingRequests(roomID: room, reviewerUserID: actor, cursor: nil, pageSize: 100).requests.isEmpty)
                    #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.room_membership_operations").first(decoding: CountRow.self)?.value == 1)
                    #expect(try await ownerSQL.raw("SELECT approved_use_count AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
                    completedApprovals.append(approve)
                    try await service.revoke(inviteID: link.inviteID, roomID: room, actorUserID: actor, operationID: .init(uuid: UUID()))
                    #expect(try await service.preview(secret: link.secret, applicantUserID: applicant) == nil)
                }
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.rooms").first(decoding: CountRow.self)?.value == 0)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.room_memberships").first(decoding: CountRow.self)?.value == 0)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_join_requests").first(decoding: CountRow.self)?.value == 0)
                for ownerSQL in [sqlA, sqlB] { #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.public_user_profiles").first(decoding: CountRow.self)?.value == 0) }
                let intentCount = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory").first(decoding: CountRow.self)?.value
                await #expect(throws: V2GroupInvitationServiceError.permissionDenied) {
                    _ = try await service.create(.init(roomID: roomB, actorUserID: rejectedApplicant, operationID: .init(uuid: UUID()), lifetime: 3600, maximumApprovedUses: 5))
                }
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory").first(decoding: CountRow.self)?.value == intentCount)
                // Epoch checks precede even an exact previously committed decision.
                let staleCreate = V2CreateGroupInviteRequest(roomID: roomB, actorUserID: actor, operationID: .init(uuid: UUID()), lifetime: 3600, maximumApprovedUses: 5)
                let staleLink = try await service.create(staleCreate)
                // Actual durable route and local epoch disagree: fail closed.
                let cachedRouter = V2CachedRoomShardRouter(source: router)
                _ = try await cachedRouter.route(for: roomB)
                let cached = V2RoutedGroupInvitationStore(controlDatabase: control, router: cachedRouter, owners: registry)
                try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch = 1 WHERE room_id = \(bind: roomB.uuidValue!)").run()
                await #expect(throws: V2GroupInvitationServiceError.ownerChanged) { _ = try await routed.activeInvites(roomID: roomB, actorUserID: actor, now: now) }
                try await sqlB.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: roomB.uuidValue!)").run()
                _ = try await routed.activeInvites(roomID: roomB, actorUserID: actor, now: now)
                await #expect(throws: V2GroupInvitationServiceError.ownerChanged) { _ = try await cached.activeInvites(roomID: roomB, actorUserID: actor, now: now) }
                let cachedService = V2GroupInvitationService(store: cached, capacityProfile: profile, secretIssuer: issuer, now: { now })
                await #expect(throws: V2GroupInvitationServiceError.ownerChanged) { _ = try await cachedService.create(staleCreate) }
                let completedApproval = try #require(completedApprovals.last)
                await #expect(throws: V2GroupInvitationServiceError.ownerChanged) { _ = try await cachedService.decide(completedApproval) }
                await #expect(throws: V2GroupInvitationServiceError.ownerChanged) { _ = try await cachedService.preview(secret: staleLink.secret, applicantUserID: applicant) }
                await #expect(throws: V2GroupInvitationServiceError.ownerChanged) { _ = try await cachedService.submit(.init(applicantUserID: rejectedApplicant, operationID: .init(uuid: UUID()), secret: staleLink.secret, note: nil)) }
                await #expect(throws: V2GroupInvitationServiceError.ownerChanged) { _ = try await cachedService.pendingRequests(roomID: roomB, reviewerUserID: actor, cursor: nil, pageSize: 100) }
                await #expect(throws: V2GroupInvitationServiceError.ownerChanged) { try await cachedService.revoke(inviteID: staleLink.inviteID, roomID: roomB, actorUserID: actor, operationID: .init(uuid: UUID())) }

                // A registry pointing to a different physical DB also fails, even
                // though that database has a valid schema and other rooms.
                let misplaced = V2RoutedGroupInvitationStore(controlDatabase: control, router: router, owners: try V2StaticRoomShardStorageRegistry(locations: [.init(shardID: "room-b", database: ownerA, schema: "im_v2")]))
                await #expect(throws: V2GroupInvitationServiceError.ownerChanged) { _ = try await misplaced.activeInvites(roomID: roomB, actorUserID: actor, now: now) }
                try await sql.raw("UPDATE im_v2.public_user_profiles SET state = 'suspended' WHERE user_id = \(bind: actor.uuidValue!)").run()
                await #expect(throws: V2GroupInvitationServiceError.permissionDenied) { _ = try await service.activeInvites(roomID: roomB, actorUserID: actor) }
                try await sql.raw("UPDATE im_v2.public_user_profiles SET state = 'active' WHERE user_id = \(bind: actor.uuidValue!)").run()
                await #expect(throws: V2GroupInvitationServiceError.permissionDenied) { _ = try await service.activeInvites(roomID: roomB, actorUserID: rejectedApplicant) }
                // Test real HTTP decoders/statuses on the same routed service.
                let auth = RoutedInvitationTestAuthenticator(user: actor)
                V2VaporGroupInvitationRoutes(authenticator: auth, invitations: service).register(on: app)
                var headers: HTTPFields = [:]
                headers[.authorization] = "Bearer invite-test"
                headers[.init("X-IM-Device-ID")!] = auth.device.rawValue
                headers.contentType = .json
                try await app.testing { client in
                    let response = try await client.send(.post, headers: headers, to: "v2/group-invites", beforeSend: { request in
                        request.body = .init(string: "{\"room_id\":\"\(roomB.rawValue)\",\"operation_id\":\"\(UUID())\",\"lifetime_seconds\":3600,\"maximum_approved_uses\":5}")
                    })
                    #expect(response.status == .ok)
                    #expect(response.headers[.cacheControl] == "no-store")
                    #expect((try await response.body.string() ?? "").contains(roomB.rawValue))
                }
                try await sql.raw("UPDATE im_v2.room_owner_routes SET room_shard_id = 'unknown-owner' WHERE room_id = \(bind: roomB.uuidValue!)").run()
                await #expect(throws: V2RoomShardStorageRegistryError.unknownShardID) { _ = try await service.activeInvites(roomID: roomB, actorUserID: actor) }
                try await app.testing { client in
                    let response = try await client.get(URI(string: "v2/group-invites?room_id=\(roomB.rawValue)"), headers: headers)
                    #expect(response.status == .serviceUnavailable)
                    #expect(!(try await response.body.string() ?? "").contains("unknown-owner"))
                }
                try await sql.raw("ALTER TABLE im_v2.group_invite_links ADD CONSTRAINT test_legacy_identity_fk FOREIGN KEY(created_by_user_id) REFERENCES im_v2.public_user_profiles(user_id) NOT VALID").run()
                await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.group_invite_links[control-identity]")) { try await V2SchemaReadiness.verify(database: control) }
                try await assertSQLSchemaGate(false, on: sql)
                try await sql.raw("ALTER TABLE im_v2.group_invite_links DROP CONSTRAINT test_legacy_identity_fk").run()
                try await V2SchemaReadiness.verify(database: control)
                try await assertSQLSchemaGate(true, on: sql)
                try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
                try await app.shutdown(); try await resources.shutdown()
                print("PASS routed invitations: mode=\(mode), two profile-free owners and independent control; create interruption/list/preview/submit/approve/reject/revoke; route/epoch/cache/identity/HTTP boundaries")
            } catch {
                if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
                try? await app.shutdown(); try? await resources.shutdown()
                throw error
            }
        }
    }

    @Test("invite creation recovery uses attempt time and publishes directory/job atomically")
    func inviteCreationRecoveryUsesAttemptClock() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let actor = UserID(uuid: senderUUID)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            let directory = PostgresV2GroupInviteDirectory(database: control)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let policy = try V2GroupInvitationPolicy(maximumActiveInvitesPerRoom: 1)
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x31, count: 32))
            let clock = TestSequenceClock([now])
            // Production path: control coordinator plus a room turn on the owner.
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: control,
                room: invitationRoomPort(control: control, owner: owner, shardID: "room-b", capacityProfile: profile, now: { clock.now() }),
                secretIssuer: issuer, policy: policy, now: { clock.now() })
            func invite(_ operation: GroupInviteOperationID, lifetime: Int) -> V2ActorCreateGroupInviteWire {
                .init(roomID: room, actorUserID: actor, operationID: operation, lifetime: TimeInterval(lifetime), maximumApprovedUses: 5)
            }
            func create(_ input: V2ActorCreateGroupInviteWire) async throws -> V2ActorGroupInviteLinkWire {
                guard case .created(let link) = try await coordinator.create(input, deadline: invitationTestDeadline()) else {
                    throw V2GroupInvitationServiceError.corruptPersistenceState
                }
                return link
            }
            func digest(_ operation: GroupInviteOperationID) throws -> Data {
                issuer.digest(try issuer.secret(actorUserID: actor, operationID: operation))
            }
            func recovery(at time: Date) -> V2GroupInviteCreationRecoveryWorker {
                .init(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, policy: policy, now: { time })
            }
            let firstOperation = GroupInviteOperationID(uuid: UUID()), secondOperation = GroupInviteOperationID(uuid: UUID())
            _ = try await create(invite(firstOperation, lifetime: 300))
            await #expect(throws: V2GroupInvitationServiceError.rateLimited) { _ = try await create(invite(secondOperation, lifetime: 3600)) }
            // A prepared intent whose owner creation never happened.
            let expired = V2GroupInviteCreatePersistenceRequest(inviteID: .init(uuid: UUID()), roomID: room, actorUserID: actor,
                operationID: .init(uuid: UUID()), tokenDigest: Data(repeating: 0x33, count: 32), requestedLifetimeSeconds: 300,
                expiresAt: now.addingTimeInterval(300), maximumApprovedUses: 5, maximumActiveInvitesPerRoom: 1, createdAt: now)
            _ = try await directory.prepare(expired)
            #expect(try await directory.resolve(tokenDigest: digest(secondOperation)) == nil)
            let later = now.addingTimeInterval(301)
            clock.set([later])
            #expect(try await create(invite(firstOperation, lifetime: 300)).state == .expired)
            // The final job update fails after directory UPDATE; the whole
            // control transaction must roll back publication while owner survives.
            try await sql.raw("CREATE FUNCTION im_v2.fail_invite_job_completion() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF NEW.state = 'completed' THEN RAISE EXCEPTION 'test finalize job failure'; END IF; RETURN NEW; END;$$").run()
            try await sql.raw("CREATE TRIGGER test_invite_job_completion BEFORE UPDATE ON im_v2.group_invite_creation_recovery FOR EACH ROW EXECUTE FUNCTION im_v2.fail_invite_job_completion()").run()
            let report = try await recovery(at: later).runOnce()
            #expect(report.attempted == 2 && report.deferred == 1 && report.paused == 1)
            #expect(try await directory.resolve(tokenDigest: digest(secondOperation)) == nil)
            #expect(try await directory.resolve(tokenDigest: expired.tokenDigest) == nil)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 2)
            try await sql.raw("DROP TRIGGER test_invite_job_completion ON im_v2.group_invite_creation_recovery").run()
            try await sql.raw("DROP FUNCTION im_v2.fail_invite_job_completion()").run()
            #expect(try await recovery(at: later).runOnce().attempted == 0)
            // No new authority is needed to finalize an already committed,
            // matching owner receipt after the original creator is suspended.
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: actor.uuidValue!)").run()
            let retryTime = later.addingTimeInterval(15)
            clock.set([retryTime])
            let recovered = try await recovery(at: retryTime).runOnce()
            #expect(recovered.completed == 1 && recovered.attempted == 1)
            let published = try #require(try await directory.resolve(tokenDigest: digest(secondOperation)))
            let value = try await create(invite(secondOperation, lifetime: 3600))
            #expect(published.inviteID == value.inviteID)
            #expect(value.createdAt == now && value.expiresAt == now.addingTimeInterval(3600) && value.state == .active)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 2)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_creation_recovery WHERE state='completed'").first(decoding: CountRow.self)?.value == 2)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_creation_recovery WHERE state='paused' AND last_error_code='creation_expired'").first(decoding: CountRow.self)?.value == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_directory WHERE operation_id = \(bind: secondOperation.uuidValue!) AND ready_at = \(bind: retryTime)").first(decoding: CountRow.self)?.value == 1)
            print("PASS creation recovery clock: expired links no longer count, original expiry unchanged, never-created expired intent paused, owner survives control rollback, current ready_at")
        }
    }

    @Test("invite creation recovery fences stale claims, resumes dependencies and drains cancellation")
    func inviteCreationRecoveryClaimsAndFences() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let actor = UserID(uuid: senderUUID)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            let directory = PostgresV2GroupInviteDirectory(database: control)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x41, count: 32))
            let clock = TestSequenceClock([now])
            // RoomRef stand-in: the owner can become unreachable or move epoch.
            let ownerSwitch = InvitationOwnerSwitch()
            let coordinator = V2ActorInvitationCoordinator(controlDatabase: control,
                room: invitationRoomPort(control: control, owner: { _ in (owner, "room-b", try ownerSwitch.current()) },
                                         capacityProfile: profile, now: { clock.now() }),
                secretIssuer: issuer, now: { clock.now() })
            func recovery(at time: Date) -> V2GroupInviteCreationRecoveryWorker {
                clock.set([time])
                return .init(jobs: directory, coordinator: coordinator, deadline: invitationTestDeadline, now: { time })
            }
            // Intents carry the digest the coordinator issues for their operation,
            // so foreground creation and recovery converge on one binding.
            func candidate() throws -> V2GroupInviteCreatePersistenceRequest {
                let operation = GroupInviteOperationID(uuid: UUID())
                return .init(inviteID: .init(uuid: UUID()), roomID: room, actorUserID: actor, operationID: operation,
                    tokenDigest: issuer.digest(try issuer.secret(actorUserID: actor, operationID: operation)),
                    requestedLifetimeSeconds: 3600, expiresAt: now.addingTimeInterval(3600), maximumApprovedUses: 5,
                    maximumActiveInvitesPerRoom: 20, createdAt: now)
            }
            for _ in 0..<2 { _ = try await directory.prepare(candidate()) }
            let claimTime = now.addingTimeInterval(30)
            async let firstBatch = directory.claim(limit: 1, now: claimTime, lease: 60, maximumActiveInvitesPerRoom: 20)
            async let secondBatch = directory.claim(limit: 1, now: claimTime, lease: 60, maximumActiveInvitesPerRoom: 20)
            let batches = try await [firstBatch, secondBatch]
            let originals = batches.flatMap { $0 }
            #expect(originals.count == 2)
            #expect(Set(originals.map { $0.intent.request.operationID }).count == 2)
            #expect(try await directory.claim(limit: 1, now: claimTime, lease: 60, maximumActiveInvitesPerRoom: 20).isEmpty)
            let reclaimedAt = now.addingTimeInterval(91)
            let reclaimed = try #require(try await directory.claim(limit: 1, now: reclaimedAt, lease: 60, maximumActiveInvitesPerRoom: 20).first)
            let old = try #require(originals.first { $0.intent.request.operationID == reclaimed.intent.request.operationID })
            #expect(old.claimToken != reclaimed.claimToken && reclaimed.attemptCount == 2)
            #expect(try await !directory.fail(old, reason: .permissionDenied, retryAt: nil, now: reclaimedAt))
            // Foreground creation and recovery race on the same operation.
            clock.set([reclaimedAt])
            let request = reclaimed.intent.request
            async let foreground = coordinator.create(.init(roomID: room, actorUserID: actor, operationID: request.operationID,
                lifetime: TimeInterval(request.requestedLifetimeSeconds), maximumApprovedUses: request.maximumApprovedUses),
                deadline: invitationTestDeadline())
            async let resumed: Void = coordinator.resumeCreation(reclaimed.intent, evaluatedAt: reclaimedAt, deadline: invitationTestDeadline())
            _ = try await (foreground, resumed)
            #expect(try await !directory.fail(reclaimed, reason: .dependencyUnavailable, retryAt: reclaimedAt.addingTimeInterval(15), now: reclaimedAt))
            // Current identity must still authorize creation without an owner
            // receipt. Pausing records no invitation and does not guess success.
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id = \(bind: actor.uuidValue!)").run()
            let denied = try await recovery(at: reclaimedAt).runOnce()
            #expect(denied.paused == 1 && denied.completed == 0)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
            try await sql.raw("UPDATE im_v2.public_user_profiles SET state='active' WHERE user_id = \(bind: actor.uuidValue!)").run()
            let transient = try candidate()
            _ = try await directory.prepare(transient)
            // An unreachable owner is a transient dependency: back off, never pause.
            ownerSwitch.set(available: false, epoch: 0)
            let retryNow = now.addingTimeInterval(100)
            let deferred = try await recovery(at: retryNow).runOnce()
            #expect(deferred.deferred == 1)
            #expect(try await recovery(at: retryNow).runOnce().attempted == 0)
            // A room turn for an epoch the owner has not reached is refused and deferred.
            ownerSwitch.set(epoch: 1)
            try await sql.raw("UPDATE im_v2.group_invite_creation_recovery SET attempt_count=1000 WHERE operation_id=\(bind: transient.operationID.uuidValue!)").run()
            let epochTime = retryNow.addingTimeInterval(15)
            let changed = try await recovery(at: epochTime).runOnce()
            #expect(changed.deferred == 1)
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            #expect(try await sql.raw("SELECT attempt_count AS value FROM im_v2.group_invite_creation_recovery WHERE operation_id=\(bind: transient.operationID.uuidValue!)").first(decoding: CountRow.self)?.value == 1000)
            let availableAt = epochTime.addingTimeInterval(900)
            #expect(try await recovery(at: availableAt).runOnce().completed == 1)
            let cancelled = try candidate()
            _ = try await directory.prepare(cancelled)
            await #expect(throws: CancellationError.self) {
                _ = try await V2GroupInviteCreationRecoveryWorker(jobs: directory, invitations: CancelledInviteCreationResumer(), now: { availableAt }).runOnce()
            }
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_creation_recovery WHERE state='claimed'").first(decoding: CountRow.self)?.value == 1)
            let restartTime = availableAt.addingTimeInterval(61)
            clock.set([restartTime])
            #expect(try await V2GroupInviteCreationRecoveryWorker(jobs: PostgresV2GroupInviteDirectory(database: control), coordinator: coordinator,
                deadline: invitationTestDeadline, now: { restartTime }).runOnce().completed == 1)
            #expect(try await directory.resolve(tokenDigest: cancelled.tokenDigest)?.inviteID == cancelled.inviteID)
            let conflicting = try candidate()
            _ = try await directory.prepare(conflicting)
            // A legacy/corrupt owner binding is evidence to quarantine, never
            // permission to overwrite a token and make the intent succeed.
            let wrongDigest = Data(repeating: 0x55, count: 32)
            try await ownerSQL.raw("""
                INSERT INTO im_v2.group_invite_links(invite_id,room_id,created_by_user_id,creation_operation_id,token_digest,requested_lifetime_seconds,expires_at,maximum_approved_uses,created_at)
                VALUES (\(bind: conflicting.inviteID.uuidValue!),\(bind: room.uuidValue!),\(bind: actor.uuidValue!),\(bind: conflicting.operationID.uuidValue!),\(bind: wrongDigest),3600,\(bind: conflicting.expiresAt),5,\(bind: now))
                """).run()
            #expect(try await recovery(at: restartTime).runOnce().paused == 1)
            #expect(try await directory.resolve(tokenDigest: conflicting.tokenDigest) == nil)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.group_invite_links WHERE creation_operation_id=\(bind: conflicting.operationID.uuidValue!) AND token_digest=\(bind: wrongDigest)").first(decoding: CountRow.self)?.value == 1)
            try await V2SchemaReadiness.verify(database: control)
            try await assertSQLSchemaGate(true, on: sql)
            try await sql.raw("DROP INDEX im_v2.group_invite_creation_recovery_lease_idx").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.group_invite_creation_recovery[claim-state]")) { try await V2SchemaReadiness.verify(database: control) }
            try await assertSQLSchemaGate(false, on: sql)
            print("PASS creation recovery claims: concurrent distinct claims, expired lease takeover, stale failure rejection, current identity pause, durable route/epoch backoff, cancellation then lease recovery")
        }
    }

    @Test("CI-required cross-store PostgreSQL endpoints are explicitly provisioned")
    func requiresCrossStorePostgresWhenConfigured() {
        guard Environment.get("IMV2_REQUIRE_CROSS_STORE_POSTGRES_TESTS") == "1" else { return }
        #expect(Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1")
        #expect(Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL")?.isEmpty == false)
        #expect(Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL")?.isEmpty == false)
        #expect(
            Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL") !=
            Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL")
        )
    }

    @Test("group creation intent fixes owner and identifiers across retries before route finalization")
    func groupCreationIntentPersistsStableOwnerAcrossRetries() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql,
                isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
            }
            guard (try await sql.raw(
                "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
            ).first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let store = PostgresV2GroupRoomCreationIntentStore(database: resources.database(.psql))
            let actorUserID = try UserID(
                "00000000-0000-0000-0000-00000000a001"
            )
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, created_at, updated_at)
                VALUES (
                    \(bind: UUID(uuidString: actorUserID.rawValue)!),
                    'intent_actor', 'Intent Actor',
                    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
                )
                """).run()
            let candidate = try V2GroupRoomCreationIntent(
                actorUserID: actorUserID,
                operationID: .init("00000000-0000-0000-0000-00000000a002"),
                roomID: .init("00000000-0000-0000-0000-00000000a003"),
                eventID: .init("00000000-0000-0000-0000-00000000a004"),
                roomShardID: "rooms-01",
                routeEpoch: 7,
                requestFingerprint: Data(repeating: 0x11, count: 32),
                audienceMemberCount: 1
            )
            let prepared = try await store.prepare(
                candidate,
                memberUserIDs: [actorUserID],
                now: .init(timeIntervalSince1970: 100)
            )
            #expect(prepared == .prepared(candidate))

            // A retry may generate new candidate IDs or observe a new shard
            // list. The durable intent, not those transient values, wins.
            let retryCandidate = try V2GroupRoomCreationIntent(
                actorUserID: candidate.actorUserID,
                operationID: candidate.operationID,
                roomID: .init("00000000-0000-0000-0000-00000000b003"),
                eventID: .init("00000000-0000-0000-0000-00000000b004"),
                roomShardID: "rooms-99",
                routeEpoch: 99,
                requestFingerprint: candidate.requestFingerprint,
                audienceMemberCount: 1
            )
            #expect(try await store.prepare(
                retryCandidate,
                memberUserIDs: [actorUserID],
                now: .init(timeIntervalSince1970: 101)
            ) == .idempotent(candidate))

            let conflict = try V2GroupRoomCreationIntent(
                actorUserID: candidate.actorUserID,
                operationID: candidate.operationID,
                roomID: retryCandidate.roomID,
                eventID: retryCandidate.eventID,
                roomShardID: retryCandidate.roomShardID,
                routeEpoch: retryCandidate.routeEpoch,
                requestFingerprint: Data(repeating: 0x22, count: 32),
                audienceMemberCount: 1
            )
            #expect(try await store.prepare(
                conflict,
                memberUserIDs: [actorUserID],
                now: .init(timeIntervalSince1970: 102)
            ) == .idempotencyConflict)

            let committed = try V2GroupRoomCreationIntent(
                actorUserID: candidate.actorUserID,
                operationID: candidate.operationID,
                roomID: candidate.roomID,
                eventID: candidate.eventID,
                roomShardID: candidate.roomShardID,
                routeEpoch: candidate.routeEpoch,
                requestFingerprint: candidate.requestFingerprint,
                audienceMemberCount: 1,
                state: .committed
            )
            #expect(try await store.finalizeCommitted(
                candidate,
                now: .init(timeIntervalSince1970: 103)
            ) == committed)
            #expect(try await store.finalizeCommitted(
                candidate,
                now: .init(timeIntervalSince1970: 104)
            ) == committed)
            guard let roomUUID = UUID(uuidString: candidate.roomID.rawValue) else {
                throw V2GroupRoomCreationIntentStoreError.invalidIntent
            }
            let route = try await sql.raw("""
                SELECT room_shard_id, route_epoch
                FROM im_v2.room_owner_routes
                WHERE room_id = \(bind: roomUUID)
                """).first(decoding: GroupCreationIntentRouteTestRow.self)
            #expect(route?.roomShardID == "rooms-01")
            #expect(route?.routeEpoch == 7)

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

    @Test("routed group creation validates identity on control and commits canonical rows only on owner")
    func routedGroupCreationUsesControlManifestAndRemoteOwner() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              let secondaryDatabaseURL = Environment.get(
                "IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"
              ),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
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
            let command = try V2CreateGroupRoomCommand(
                actorUserID: actor,
                operationID: .init(
                    "00000000-0000-0000-0000-00000000c103"
                ),
                title: "跨库真实群",
                capacityClass: .standard,
                initialMemberUserIDs: [member]
            )
            let profile = try V2CapacityProfile(
                id: "standard",
                limits: .init(
                    maxEligibleMembers: 100,
                    maxCommandsPerWindow: 1000,

                    retryAfterSeconds: 1
                )
            )
            let store = try V2RoutedGroupMessagingStore(
                intentStore: PostgresV2GroupRoomCreationIntentStore(
                    database: resources.database(.psql)
                ),
                ownerStores: [
                    "rooms-01": PostgresV2GroupMessagingStore(
                        database: resources.database(ownerID)
                    ),
                ]
            )
            let firstRoomID = try RoomID(
                "00000000-0000-0000-0000-00000000c104"
            )
            let first = try await store.create(
                command: command,
                capacityProfile: profile,
                roomShardID: "ignored",
                roomID: firstRoomID,
                eventID: .init("00000000-0000-0000-0000-00000000c105"),
                now: .init(timeIntervalSince1970: 200)
            )
            guard case .created(let group) = first else {
                Issue.record("expected owner group creation")
                return
            }
            #expect(group.roomID == firstRoomID)
            #expect(try await controlSQL.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.group_room_creation_intent_members
                """).first(decoding: CountRow.self)?.value == 2)
            #expect(try await controlSQL.raw("""
                SELECT COUNT(*)::bigint AS value FROM im_v2.rooms
                """).first(decoding: CountRow.self)?.value == 0)
            #expect(try await ownerSQL.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.public_user_profiles
                """).first(decoding: CountRow.self)?.value == 0)
            #expect(try await ownerSQL.raw("""
                SELECT COUNT(*)::bigint AS value FROM im_v2.room_memberships
                WHERE room_id = \(bind: firstRoomID.uuidValue!)
                """).first(decoding: CountRow.self)?.value == 2)

            let retry = try await store.create(
                command: command,
                capacityProfile: profile,
                roomShardID: "ignored-again",
                roomID: .init("00000000-0000-0000-0000-00000000c204"),
                eventID: .init("00000000-0000-0000-0000-00000000c205"),
                now: .init(timeIntervalSince1970: 201)
            )
            guard case .idempotent(let retryGroup) = retry else {
                Issue.record("expected idempotent owner retry")
                return
            }
            #expect(retryGroup.roomID == firstRoomID)
            #expect(try await ownerSQL.raw("""
                SELECT COUNT(*)::bigint AS value FROM im_v2.rooms
                """).first(decoding: CountRow.self)?.value == 1)

            let membershipStore = PostgresV2RoomMembershipStore(
                database: resources.database(ownerID)
            )
            let routedMembership = try V2RoutedRoomMembershipStore(
                router: V2PostgresRoomShardRouter(database: resources.database(.psql)),
                stores: [
                    "rooms-01": membershipStore,
                    "rooms-unused": membershipStore,
                ],
                identities: V2PostgresMembershipIdentitySnapshotValidator(
                    database: resources.database(.psql)
                )
            )
            let membershipOutcome = try await routedMembership.change(
                command: .init(
                    roomID: firstRoomID,
                    actorUserID: actor,
                    operationID: .init(
                        "00000000-0000-0000-0000-00000000c301"
                    ),
                    targetUserID: stagedMemberA,
                    action: .add,
                    expectedMembershipRevision: 1
                ),
                capacityProfile: profile,
                eventID: .init("00000000-0000-0000-0000-00000000c302"),
                now: .init(timeIntervalSince1970: 201.5)
            )
            guard case .changed(let membershipChange) = membershipOutcome else {
                Issue.record("expected remote owner membership change")
                return
            }
            #expect(membershipChange.membershipRevision == 2)
            #expect(try await controlSQL.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.room_membership_operations
                """).first(decoding: CountRow.self)?.value == 0)
            #expect(try await ownerSQL.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.room_memberships
                WHERE room_id = \(bind: firstRoomID.uuidValue!)
                  AND left_revision IS NULL
                """).first(decoding: CountRow.self)?.value == 3)

            let stagedOperationID = try GroupRoomOperationID(
                "00000000-0000-0000-0000-00000000c109"
            )
            try await controlSQL.raw("""
                INSERT INTO im_v2.group_room_creation_drafts
                    (actor_user_id, operation_id, title, state, created_at,
                     updated_at, expires_at)
                VALUES (
                    \(bind: actor.uuidValue!),
                    \(bind: stagedOperationID.uuidValue!),
                    '跨库分页群', 'finalizing', CURRENT_TIMESTAMP,
                    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + INTERVAL '1 hour'
                )
                """).run()
            try await controlSQL.raw("""
                INSERT INTO im_v2.group_room_creation_draft_members
                    (actor_user_id, operation_id, user_id)
                VALUES
                    (\(bind: actor.uuidValue!),
                     \(bind: stagedOperationID.uuidValue!),
                     \(bind: stagedMemberA.uuidValue!)),
                    (\(bind: actor.uuidValue!),
                     \(bind: stagedOperationID.uuidValue!),
                     \(bind: stagedMemberB.uuidValue!))
                """).run()
            let stagedCommand = try V2StagedGroupRoomCommand(
                actorUserID: actor,
                operationID: stagedOperationID,
                title: "跨库分页群",
                capacityClass: .standard,
                stagedMemberCount: 2
            )
            let stagedRoomID = try RoomID(
                "00000000-0000-0000-0000-00000000c10a"
            )
            let staged = try await store.createStaged(
                command: stagedCommand,
                capacityProfile: profile,
                roomShardID: "ignored-staged",
                roomID: stagedRoomID,
                eventID: .init("00000000-0000-0000-0000-00000000c10b"),
                now: .init(timeIntervalSince1970: 202)
            )
            guard case .created(let stagedGroup) = staged else {
                Issue.record("expected staged owner group creation")
                return
            }
            #expect(stagedGroup.roomID == stagedRoomID)
            #expect(stagedGroup.memberCount == 3)
            #expect(try await ownerSQL.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.group_room_creation_intent_pages
                WHERE actor_user_id = \(bind: actor.uuidValue!)
                  AND operation_id = \(bind: stagedOperationID.uuidValue!)
                  AND is_final
                """).first(decoding: CountRow.self)?.value == 1)
            #expect(try await ownerSQL.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.room_memberships
                WHERE room_id = \(bind: stagedRoomID.uuidValue!)
                """).first(decoding: CountRow.self)?.value == 3)
            #expect(try await ownerSQL.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.group_room_creation_intents
                WHERE actor_user_id = \(bind: actor.uuidValue!)
                  AND operation_id = \(bind: stagedOperationID.uuidValue!)
                  AND state = 'committed'
                """).first(decoding: CountRow.self)?.value == 1)

            #expect(try await count("im_v2.user_state_event_outbox", on: controlSQL) == 0)
            #expect(try await count("im_v2.user_state_event_outbox", on: ownerSQL) == 6)
            let worker = try V2UserStateEventWorker(
                outbox: PostgresV2UserStateEventOutbox(database: resources.database(ownerID)),
                projector: PostgresV2UserStateEventProjector(database: resources.database(.psql))
            )
            #expect(try await worker.runOnce(limit: 8) == 6)
            #expect(try await count("im_v2.user_sync_log", on: controlSQL) == 6)
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

    @Test("plain hybrid group rooms receive their own atomic batch partition")
    func preclassifiesPlainHybridGroupRoomsForAtomicWrite() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
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
            let writer = PostgresV2RoomWriteStore(
                database: resources.database(.psql),
                strangerMessagePolicy: try .init(
                    maximumMessagesPerWindow: 10,
                    window: 86_400
                ),
                contentReviewMode: .disabled,
                directRoomLogAdmissionMode: .shardOnly,
                shardAdmissionCommandCreditPool: .init(
                    database: resources.database(.psql),
                    batchSize: 4
                )
            )
            let requests = try (1...2).map { ordinal in
                V2RoomWriteRequest(
                    command: try .init(
                        roomID: roomID,
                        senderUserID: senderID,
                        clientMessageID: .init(
                            String(format: "00000000-0000-0000-0003-%012x", ordinal)
                        ),
                        text: "群聊路径预分类 \(ordinal)",
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

            #expect(
                await writer.atomicBatchPartitions(requests: requests) ==
                    [.large, .large]
            )
            #expect(
                await writer.atomicBatchPartitions(requests: requests) ==
                    [.large, .large]
            )
            #expect(try await count("im_v2.messages", on: sql) == 0)

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

    @Test("plain hybrid group messages for distinct rooms commit as one atomic batch")
    func atomicallyPersistsPlainHybridGroupMessagesAcrossRooms() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
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
            let writer = PostgresV2RoomWriteStore(
                database: resources.database(.psql),
                strangerMessagePolicy: try .init(
                    maximumMessagesPerWindow: 10,
                    window: 86_400
                ),
                contentReviewMode: .disabled,
                directRoomLogAdmissionMode: .shardOnly,
                shardAdmissionCommandCreditPool: .init(
                    database: resources.database(.psql),
                    batchSize: 4
                )
            )
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

            let outcomes = try await writer.acceptAtomically(requests: requests)
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
                    (SELECT count(*) FROM im_v2.group_event_wake_outbox)::bigint
                        AS wake_rows,
                    (SELECT command_window_used FROM im_v2.shard_admission_pools
                     WHERE room_shard_id = 'room-a'
                       AND capacity_profile_id = 'standard')::bigint
                        AS shard_commands,
                    (SELECT sum(command_window_used) FROM im_v2.room_admission)::bigint
                        AS room_commands,
                    (SELECT count(*) FROM im_v2.message_projection_state_values)::bigint
                        AS readable_message_states
                """).first(decoding: PlainHybridGroupBatchArtifacts.self))
            #expect(artifacts.messages == 2)
            // A plain hybrid-group accept is one canonical message row. Its
            // accepted event is derived by the room-log reader, while the
            // zero-target plan and revision-one projection state are omitted.
            #expect(artifacts.events == 0)
            #expect(artifacts.messageStates == 0)
            #expect(artifacts.wakeRows == 2)
            #expect(artifacts.shardCommands == 4)
            #expect(artifacts.roomCommands == 2)
            #expect(artifacts.readableMessageStates == 0)

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

            do {
                _ = try await writer.acceptAtomically(requests: requests)
                Issue.record("expected replay batch to fall back to scalar idempotency")
            } catch let error as V2AtomicRoomWriteBatchError {
                #expect(error.reason == .authorizationState)
                #expect(error.isolatedRequestIndices == [0, 1])
            }
            for request in requests {
                let replay = try await writer.accept(
                    command: request.command,
                    capacityProfile: request.capacityProfile,
                    identifiers: request.identifiers,
                    now: request.now
                )
                guard case .idempotent = replay else {
                    Issue.record("expected scalar fallback to replay committed group message")
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
                        text: "必须整批回滚 \(index + 1)",
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
            do {
                _ = try await writer.acceptAtomically(requests: rejectedRequests)
                Issue.record("expected one unauthorized room to reject the atomic batch")
            } catch let error as V2AtomicRoomWriteBatchError {
                #expect(error.reason == .authorizationState)
                #expect(error.isolatedRequestIndices == [1])
            }
            let rollback = try #require(try await sql.raw("""
                SELECT
                    (SELECT count(*) FROM im_v2.messages)::bigint AS messages,
                    (SELECT sum(room_sequence) FROM im_v2.rooms
                     WHERE room_id IN (\(bind: roomUUID), \(bind: secondRoom)))::bigint
                        AS sequence_sum,
                    (SELECT command_window_used FROM im_v2.shard_admission_pools
                     WHERE room_shard_id = 'room-a'
                       AND capacity_profile_id = 'standard')::bigint
                        AS shard_commands
                """).first(decoding: PlainHybridGroupRollbackArtifacts.self))
            #expect(rollback.messages == 3)
            #expect(rollback.sequenceSum == 3)
            // Replays and the rejected authorization batch return their
            // process-local tokens. The original four-credit durable charge
            // is conservative and does not grow on either rollback.
            #expect(rollback.shardCommands == 5)

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

    @Test("plain hybrid group messages for one hot room advance in one atomic batch")
    func atomicallyPersistsRepeatedPlainHybridGroupRoomMessages() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
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
            let writer = PostgresV2RoomWriteStore(
                database: resources.database(.psql),
                strangerMessagePolicy: try .init(
                    maximumMessagesPerWindow: 10,
                    window: 86_400
                ),
                contentReviewMode: .disabled,
                directRoomLogAdmissionMode: .shardOnly,
                shardAdmissionCommandCreditPool: .init(
                    database: resources.database(.psql),
                    batchSize: 4
                )
            )
            #expect(await writer.atomicBatchSupportsRepeatedRooms(in: .large))
            #expect(!(await writer.atomicBatchSupportsRepeatedRooms(in: .standard)))

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

            let outcomes = try await writer.acceptAtomically(requests: requests)
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
                       (SELECT command_window_used
                        FROM im_v2.room_admission
                        WHERE room_id = \(bind: roomUUID))::bigint AS room_commands,
                       (SELECT command_window_used
                        FROM im_v2.shard_admission_pools
                        WHERE room_shard_id = 'room-a'
                          AND capacity_profile_id = 'standard')::bigint
                           AS shard_commands,
                       (SELECT count(*) FROM im_v2.room_events
                        WHERE room_id = \(bind: roomUUID)
                          AND event_type = 'message.accepted')::bigint AS events,
                       (SELECT count(*) FROM im_v2.message_projection_states
                        WHERE room_id = \(bind: roomUUID))::bigint AS message_states,
                       (SELECT count(*) FROM im_v2.group_event_wake_outbox
                        WHERE room_id = \(bind: roomUUID))::bigint AS wake_rows,
                       (SELECT target_room_sequence
                        FROM im_v2.group_event_wake_outbox
                        WHERE room_id = \(bind: roomUUID))::bigint
                           AS wake_target_sequence,
                       (SELECT revision
                        FROM im_v2.group_event_wake_outbox
                        WHERE room_id = \(bind: roomUUID))::bigint AS wake_revision
                FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)
                """).first(decoding: RepeatedHybridGroupStateRow.self))
            #expect(state.roomSequence == 3)
            #expect(state.timelineSequence == 3)
            #expect(state.roomCommands == 3)
            // The shard row is charged once for a four-credit durable batch;
            // three committed messages consume tokens locally and the fourth
            // remains safely precharged for the next append.
            #expect(state.shardCommands == 4)
            #expect(state.events == 0)
            #expect(state.messageStates == 0)
            // Wake delivery is intentionally coalesced per room; one row's
            // high-watermark covers every event committed in this batch.
            #expect(state.wakeRows == 1)
            #expect(state.wakeTargetSequence == 3)
            // A relay cannot observe individual rows from the atomic INSERT.
            // The fencing revision therefore advances once for this statement,
            // rather than producing three redundant revisions and UPSERTs.
            #expect(state.wakeRevision == 1)

            let page = try await PostgresV2GroupEventLogStore(database: resources.database(.psql)).pull(
                roomID: roomID,
                actorUserID: senderID,
                afterRoomSequence: 0,
                pageSize: 10
            )
            #expect(page.events.map(\.roomSequence) == [1, 2, 3])
            #expect(page.events.map(\.sourceEventID) == requests.map(\.identifiers.eventID))

            // A later mutation can materialize the omitted revision-one state
            // directly from the canonical message row. This is the edit and
            // withdrawal compatibility fence for the compact representation.
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

            let laterRequests = try (4 ... 5).map { ordinal in
                V2RoomWriteRequest(
                    command: try .init(
                        roomID: roomID,
                        senderUserID: senderID,
                        clientMessageID: .init(
                            String(format: "00000000-0000-0000-000a-%012x", ordinal)
                        ),
                        text: "待唤醒合并群消息 \(ordinal)",
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

            // A later commit while the durable row is already pending must not
            // rewrite that hot row. The room counter is the authoritative
            // watermark and advances independently.
            guard case .accepted = try await writer.accept(
                command: laterRequests[0].command,
                capacityProfile: laterRequests[0].capacityProfile,
                identifiers: laterRequests[0].identifiers,
                now: laterRequests[0].now
            ) else {
                Issue.record("expected the pending-wake message to be accepted")
                return
            }
            var wakeState = try #require(try await sql.raw("""
                SELECT room.room_sequence,
                       wake.target_room_sequence,
                       wake.revision,
                       wake.state
                FROM im_v2.rooms AS room
                JOIN im_v2.group_event_wake_outbox AS wake
                  ON wake.room_id = room.room_id
                WHERE room.room_id = \(bind: roomUUID)
                """).first(decoding: HybridGroupWakeStateRow.self))
            #expect(wakeState.roomSequence == 4)
            #expect(wakeState.targetRoomSequence == 3)
            #expect(wakeState.revision == 1)
            #expect(wakeState.state == "pending")

            let wakeStore = PostgresV2GroupEventWakeStore(database: resources.database(.psql))
            let firstLease = try #require(try await wakeStore.claimPending(
                now: Date(timeIntervalSince1970: 1_750_000_010),
                leaseDuration: 30,
                limit: 1
            ).first)
            // Claiming reads the fresh room counter in a second statement,
            // rather than trusting the intentionally stale pending-row target.
            #expect(firstLease.wake.roomID == roomID)
            #expect(firstLease.wake.highWatermark == 4)
            #expect(firstLease.revision == 1)

            // A commit that races an in-flight publisher replaces the lease
            // and advances the revision. The stale publisher's completion is
            // fenced and cannot delete this newer wake.
            guard case .accepted = try await writer.accept(
                command: laterRequests[1].command,
                capacityProfile: laterRequests[1].capacityProfile,
                identifiers: laterRequests[1].identifiers,
                now: laterRequests[1].now
            ) else {
                Issue.record("expected the leased-wake message to be accepted")
                return
            }
            try await wakeStore.markPublished(firstLease)
            wakeState = try #require(try await sql.raw("""
                SELECT room.room_sequence,
                       wake.target_room_sequence,
                       wake.revision,
                       wake.state
                FROM im_v2.rooms AS room
                JOIN im_v2.group_event_wake_outbox AS wake
                  ON wake.room_id = room.room_id
                WHERE room.room_id = \(bind: roomUUID)
                """).first(decoding: HybridGroupWakeStateRow.self))
            #expect(wakeState.roomSequence == 5)
            #expect(wakeState.targetRoomSequence == 5)
            #expect(wakeState.revision == 2)
            #expect(wakeState.state == "pending")

            let replacementLease = try #require(try await wakeStore.claimPending(
                now: Date(timeIntervalSince1970: 1_750_000_011),
                leaseDuration: 30,
                limit: 1
            ).first)
            #expect(replacementLease.wake.highWatermark == 5)
            #expect(replacementLease.revision == 2)
            try await wakeStore.markPublished(replacementLease)
            #expect(try await count("im_v2.group_event_wake_outbox", on: sql) == 0)

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

private struct GroupCreationIntentRouteTestRow: Decodable {
    let roomShardID: String
    let routeEpoch: Int64

    enum CodingKeys: String, CodingKey {
        case roomShardID = "room_shard_id"
        case routeEpoch = "route_epoch"
    }
}
private struct PlainHybridGroupBatchArtifacts: Decodable {
    let messages: Int64
    let events: Int64
    let messageStates: Int64
    let wakeRows: Int64
    let shardCommands: Int64
    let roomCommands: Int64
    let readableMessageStates: Int64

    enum CodingKeys: String, CodingKey {
        case messages, events
        case messageStates = "message_states"
        case wakeRows = "wake_rows"
        case shardCommands = "shard_commands"
        case roomCommands = "room_commands"
        case readableMessageStates = "readable_message_states"
    }
}
private struct PlainHybridGroupRollbackArtifacts: Decodable {
    let messages: Int64
    let sequenceSum: Int64
    let shardCommands: Int64

    enum CodingKeys: String, CodingKey {
        case messages
        case sequenceSum = "sequence_sum"
        case shardCommands = "shard_commands"
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
private struct RepeatedHybridGroupStateRow: Decodable {
    let roomSequence: Int64
    let timelineSequence: Int64
    let roomCommands: Int64
    let shardCommands: Int64
    let events: Int64
    let messageStates: Int64
    let wakeRows: Int64
    let wakeTargetSequence: Int64
    let wakeRevision: Int64

    enum CodingKeys: String, CodingKey {
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case roomCommands = "room_commands"
        case shardCommands = "shard_commands"
        case events
        case messageStates = "message_states"
        case wakeRows = "wake_rows"
        case wakeTargetSequence = "wake_target_sequence"
        case wakeRevision = "wake_revision"
    }
}
private struct HybridGroupWakeStateRow: Decodable {
    let roomSequence: Int64
    let targetRoomSequence: Int64
    let revision: Int64
    let state: String

    enum CodingKeys: String, CodingKey {
        case roomSequence = "room_sequence"
        case targetRoomSequence = "target_room_sequence"
        case revision, state
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
