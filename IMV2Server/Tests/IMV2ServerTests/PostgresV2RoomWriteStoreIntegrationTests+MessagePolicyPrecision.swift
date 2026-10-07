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
import IMV2Core
import IMV2ActorContracts
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
    @Test("Message mutations preserve response and event timestamp precision across accepted delivery authorities",
          arguments: ["groupPersonal", "groupRoomLog", "directPersonal", "directPreplanned", "directRoomLog"],
          ["edit", "edit-owner", "withdraw", "withdraw-owner", "reaction", "reaction-owner"])
    func messageMutationTimestampPrecision(deliveryKind: String, path: String) async throws {
        let mode: V2GroupCapacityClass = deliveryKind == "groupRoomLog" ? .large : .standard
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 20,

                retryAfterSeconds: 3))
            let expiry = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 1)
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until = \(bind: expiry), command_window_limit = 20").run()
            try await sql.raw("UPDATE im_v2.room_admission SET command_window_limit = 20").run()
            let destination: RoomID
            if deliveryKind.hasPrefix("direct") {
                let room = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                        roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { base }).openedIdentity(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                destination = room.roomID
            } else { destination = roomID }
            let destinationUUID = try #require(destination.uuidValue)
            let writer = PostgresV2RoomWriteStore(database: database,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
            let send = try V2SendMessageService(store: writer, capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { base })
            guard case .acquired(let lease)=try await PostgresV2RoomActivationStore(database:database).acquire(roomID:destination,owner:.init(shardID:"room-a",epoch:0),host:.init(hostID:.init("mutation-precision"),incarnationID:UUID()),duration:.init(30_000)) else { throw CancellationError() }
            let mutations=PostgresV2MessageMutationOperationStore(database:database,contentReviewMode:.disabled,clock:{base})
            let reactions=PostgresV2MessageReactionOperationStore(database:database,clock:{base})
            let kind=String(path.split(separator:"-")[0])
            let table=kind=="reaction" ? "message_reaction_receipts" : "message_mutation_receipts"
            func invoke(_ id:UUID,message:MessageID,remove:Bool,now:Date,replay:Bool) async throws -> (Date,UInt64,EventID) {
                let deadline=UInt64(base.timeIntervalSince1970*1000)+60_000
                let sequence:UInt64,event:EventID
                switch kind {
                case "edit":
                    let command=try V2MessageEditOperationCommand(command:.init(roomID:destination,actorUserID:senderID,operationID:.init(uuid:id),messageID:message,expectedMessageRevision:1,text:"Edited clock fixture",maximumUTF8Bytes:64),firstSubmissionDeadlineMilliseconds:deadline)
                    guard case .receipt(let receipt)=try await mutations.edit(command,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now,maximumUTF8Bytes:64),case .committed(let commit)=receipt.outcome else { throw CancellationError() }
                    #expect(commit.messageRevision==2)
                    sequence=commit.roomSequence;event=commit.eventID
                case "withdraw":
                    let command=try V2MessageWithdrawalOperationCommand(command:.init(roomID:destination,actorUserID:senderID,operationID:.init(uuid:id),messageID:message,expectedMessageRevision:1),firstSubmissionDeadlineMilliseconds:deadline)
                    guard case .receipt(let receipt)=try await mutations.withdraw(command,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now),case .committed(let commit)=receipt.outcome else { throw CancellationError() }
                    #expect(commit.messageRevision==2)
                    sequence=commit.roomSequence;event=commit.eventID
                default:
                    let command=try V2MessageReactionOperationCommand(command:.init(roomID:destination,actorUserID:senderID,operationID:.init(uuid:id),messageID:message,reaction:"👍",action:remove ? .remove : .add),expectedReactionRevision:remove ? 1 : 0,firstSubmissionDeadlineMilliseconds:deadline)
                    guard case .receipt(let receipt)=try await reactions.change(command,token:lease.token,capacityProfile:profile,eventID:.init(uuid:UUID()),now:now),case .committed(let commit)=receipt.outcome,let proof=commit.event else { throw CancellationError() }
                    #expect(commit.targetState==(remove ? .absent : .present))
                    sequence=proof.roomSequence;event=proof.eventID
                }
                // Minimal original receipts do not carry a message body or grant
                // display access. This owner fixture independently inspects its event.
                let timestamp=try #require(try await sql.raw("SELECT created_at FROM im_v2.room_events WHERE event_id=\(bind:event.uuidValue!)").first(decoding:MutationPrecisionTimestamp.self))
                return (timestamp.createdAt,sequence,event)
            }
            func snapshot() async throws -> [String] {
                var result: [String] = []
                for name in ["rooms", "messages", "room_memberships", "room_admission", "shard_admission_pools", "room_events",
                    "message_projection_states", "content_review_jobs", "message_reactions", table] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: name) r").first(decoding: StringValueRow.self)
                    result.append(try #require(row).value)
                }
                return result
            }
            let dates: [Double] = [946_684_800 - 0.00000075, 946_684_800 + 0.00000075, 946_684_800 + 0.00000125,
                1_750_000_000 + 0.99999975, 946_684_800 + 9_223_371_331_200 - 10]
            for seconds in dates {
                guard case .accepted(let message) = try await send.send(.init(roomID: destination, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "Original clock fixture")) else { throw CancellationError() }
                let now = Date(timeIntervalSince1970: seconds)
                let beforeInvalidClock = try await snapshot()
                await #expect(throws: V2MessageOperationValidationError.invalidReceipt) {
                    _ = try await invoke(UUID(), message: message.messageID, remove: false,
                        now: Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000), replay: false)
                }
                #expect(try await snapshot() == beforeInvalidClock)
                for remove in kind == "reaction" ? [false, true] : [false] {
                    let operation = UUID()
                    let first = try await invoke(operation, message: message.messageID, remove: remove, now: now, replay: false)
                    #expect(first.1 == message.roomSequence + (remove ? 2 : 1))
                    let row = try await sql.raw("SELECT created_at AS value FROM im_v2.room_events WHERE event_id = \(bind: first.2.uuidValue!)").first(decoding: RevocationClockDateRow.self)
                    let stored = try #require(row).value
                    #expect(first.0 == stored)
                    #expect(try v2GatewayMilliseconds(first.0) == v2GatewayMilliseconds(stored))
                    let exact = try await sql.raw("""
                        SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table) o
                        CROSS JOIN im_v2.room_events e
                        WHERE o.operation_id = \(bind: operation) AND o.resolved_at = \(bind: base)
                            AND e.created_at = \(bind: now)
                            AND e.event_id = \(bind: first.2.uuidValue!)
                            AND e.room_sequence = \(bind: Int64(first.1))
                        """).first(decoding: CountRow.self)
                    #expect(exact?.value == 1)
                    let payload = try await sql.raw("SELECT (payload->>'server_created_at_ms')::bigint AS value FROM im_v2.room_events WHERE event_id = \(bind: first.2.uuidValue!)").first(decoding: CountRow.self)
                    #expect(try payload?.value == v2GatewayMilliseconds(stored))
                    if kind != "reaction" {
                        let state = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.message_projection_states WHERE state_event_id = \(bind: first.2.uuidValue!) AND created_at = \(bind: now)").first(decoding: CountRow.self)
                        #expect(state?.value == 1)
                    }
                    let before = try await snapshot()
                    let replay = try await invoke(operation, message: message.messageID, remove: remove, now: base, replay: true)
                    #expect(replay.0 == first.0 && replay.1 == first.1 && replay.2 == first.2)
                    #expect(try await snapshot() == before)
                }
                let original = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.messages WHERE message_id = \(bind: message.messageID.uuidValue!) AND created_at = \(bind: base)").first(decoding: CountRow.self)
                #expect(original?.value == 1)
            }
            #expect(try await count("im_v2." + table, on: sql) == (kind == "reaction" ? 10 : 5))
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.messages WHERE room_id = \(bind: destinationUUID)").first(decoding: CountRow.self)?.value == 5)
            if kind == "reaction" { #expect(try await count("im_v2.message_reactions", on: sql) == 0) }
        }
    }

    @Test("Group controls preserve original proof and event precision through the fenced owner",
          arguments: [V2GroupCapacityClass.standard, .large], ["pin", "announcement", "permissions", "role"])
    func groupCapabilityTimestampPrecision(mode: V2GroupCapacityClass, kind: String) async throws {
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind: roomUUID) AND user_id=\(bind: senderUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1 WHERE room_id=\(bind: roomUUID)").run()
            let expiry = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 1)
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=\(bind: expiry)").run()
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { base })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "Group timestamp fixture")) else { throw CancellationError() }
            guard case .acquired(let lease) = try await PostgresV2RoomActivationStore(database: database).acquire(
                roomID: roomID, owner: .init(shardID: "room-a", epoch: 0),
                host: .init(hostID: .init("group-precision"), incarnationID: UUID()), duration: .init(30_000)) else { throw CancellationError() }
            let dates: [Double] = [946_684_800 - 0.00000075, 946_684_800 + 0.00000075, 946_684_800 + 0.00000125,
                1_750_000_000 + 0.99999975, 946_684_800 + 9_223_371_331_200 - 180]
            for (index, seconds) in dates.enumerated() {
                let now = Date(timeIntervalSince1970: seconds), operation = UUID(), event = EventID(uuid: UUID())
                let action: V2GroupCapabilityAction
                let reference: V2OperationReference
                let scope: V2OperationScope
                switch kind {
                case "pin":
                    action = .pin(messageID: message.messageID, isPinned: index % 2 == 0, expectedRoomSequence: UInt64(index + 1))
                    reference = .pinnedMessage(.init(uuid: operation)); scope = .message(roomID, message.messageID)
                case "announcement":
                    action = .announcement(body: "Announcement \(index)", expectedRevision: UInt64(index))
                    reference = .groupAnnouncement(.init(uuid: operation)); scope = .room(roomID)
                case "permissions":
                    action = .rolePermissions(role: .member, permissions: index % 2 == 0 ? [.sendMessages] : [], expectedRevision: UInt64(index + 1))
                    reference = .groupPermission(.init(uuid: operation)); scope = .room(roomID)
                default:
                    action = .memberRole(targetUserID: .init(uuid: memberTwoUUID), role: index % 2 == 0 ? .admin : .member, expectedMembershipRevision: UInt64(index + 1))
                    reference = .groupRole(.init(uuid: operation)); scope = .room(roomID)
                }
                let milliseconds = UInt64(try v2GatewayMilliseconds(now))
                let intent = try V2GroupCapabilityIntent(identity: .init(accountID: senderID, scope: scope, operation: reference),
                    action: action, confirmedUntilMilliseconds: milliseconds + 120_000)
                let store = PostgresV2GroupCapabilityOperationStore(database: database, clock: { now })
                guard case .admitted(let admission) = try await store.admit(intent, token: lease.token) else { throw CancellationError() }
                let command = try V2GroupCapabilityCommand(intent: intent, admission: admission)
                let first = try await store.submit(command, token: lease.token, capacityProfile: profile, eventID: event)
                guard case .receipt(let proof) = first, case .applied(let value) = proof.outcome else { throw CancellationError() }
                #expect(proof.validates(command: command))
                #expect(proof.resolvedAtMilliseconds == milliseconds)
                #expect(value.roomSequence == UInt64(index + 2))
                let row = try await sql.raw("SELECT created_at AS value FROM im_v2.room_events WHERE event_id=\(bind: event.uuidValue!)").first(decoding: RevocationClockDateRow.self)
                let stored = try #require(row).value
                let storedMilliseconds = try v2GatewayMilliseconds(stored)
                let exact = try await sql.raw("""
                    SELECT COUNT(*) AS value FROM im_v2.room_events
                    WHERE event_id=\(bind: event.uuidValue!) AND created_at=\(bind: now)
                      AND room_sequence=\(bind: Int64(value.roomSequence))
                      AND (payload->>'room_sequence')::bigint=room_sequence
                      AND (payload->>'server_created_at_ms')::bigint=\(bind: storedMilliseconds)
                    """).first(decoding: CountRow.self)
                #expect(exact?.value == 1)
                let replay = PostgresV2GroupCapabilityOperationStore(database: database, clock: { Date(timeIntervalSince1970: .nan) })
                #expect(try await replay.submit(command, token: lease.token, capacityProfile: profile, eventID: .init(uuid: UUID())) == first)
                #expect(try await count("im_v2.group_capability_receipts", on: sql) == Int64(index + 1))
                #expect(try await count("im_v2.room_events", on: sql) == Int64(index + 2))
            }
            let page = try await PostgresV2GroupEventLogStore(database: database).pull(roomID: roomID, actorUserID: senderID, afterRoomSequence: 1, pageSize: 20)
            #expect(page.events.count == dates.count && page.nextRoomSequence == UInt64(dates.count + 1) && !page.hasMore)
        }
    }

    @Test("Direct, preference and social proofs retain their original timestamp across retries",
          arguments: ["direct", "stranger", "userAdd", "request", "accept", "reject", "remove", "block", "unblock", "block-remove"],
          [Double](arrayLiteral: 946_684_800 - 0.00000075, 946_684_800 + 0.00000075, 946_684_800 + 0.00000125,
              1_750_000_000 + 0.99999975, 946_684_800 + 9_223_371_331_200 - 660))
    func directSocialResponseTimestampPrecision(kind: String, seconds: Double) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, deliveryDB, sql, deliverySQL, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000), now = Date(timeIntervalSince1970: seconds)
            let direct = PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery())
            let social = PostgresV2SocialRelationshipStore(database: database)
            let preferences = PostgresV2AccountPreferenceOperationStore(database: database,
                projectionDelivery: SuccessfulProjectionDelivery(),
                authorizationCoordinator: .init(controlDatabase: database, ownerDatabases: ["room-a": database]))
            let profile = try forwardImportTestProfile(), target = UserID(uuid: memberTwoUUID)
            let newRoom = RoomID(uuid: UUID()), operation = UUID()
            let relationshipAction: V2RelationshipAction = kind == "accept" ? .accept : kind == "reject" ? .reject : kind == "remove" ? .remove : .request
            let blockAction: V2UserBlockAction = kind == "unblock" ? .unblock : .block
            if ["accept", "reject", "remove", "block-remove"].contains(kind) {
                guard case .receipt(let proof) = try await social.executeSocialFixture(actorUserID: target, targetUserID: senderID,
                    operation: .relationship(.init(uuid: UUID())), action: .relationship(.request), now: base), case .applied = proof.outcome else { throw CancellationError() }
                if ["remove", "block-remove"].contains(kind) {
                    guard case .receipt(let proof) = try await social.executeSocialFixture(actorUserID: senderID, targetUserID: target,
                        operation: .relationship(.init(uuid: UUID())), action: .relationship(.accept), now: base), case .applied = proof.outcome else { throw CancellationError() }
                }
            }
            if kind == "unblock" {
                guard case .receipt(let proof) = try await social.executeSocialFixture(actorUserID: senderID, targetUserID: target,
                    operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: base), case .applied = proof.outcome else { throw CancellationError() }
            }
            let directCommand: V2DirectRoomOperationCommand?
            let preferenceCommand: V2AccountPreferenceCommand?
            let socialCommand: V2SocialOperationCommand?
            let table: String
            if kind == "direct" {
                let expiry = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 1)
                try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=\(bind: expiry)").run()
                directCommand = try .init(actorUserID: senderID, operationID: .init(uuid: operation), targetUserID: target,
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                preferenceCommand = nil; socialCommand = nil; table = "direct_room_owner_receipts"
            } else if ["stranger", "userAdd"].contains(kind) {
                preferenceCommand = try await preferences.freezePreferenceFixture(owner: senderID,
                    operation: kind == "stranger" ? .strangerMessagePreference(.init(uuid: operation)) : .userAddPreference(.init(uuid: operation)),
                    value: kind == "stranger" ? .strangerMessage(.deny) : .userAdd(.deny), now: now)
                directCommand = nil; socialCommand = nil; table = "account_preference_receipts"
            } else {
                let block = ["block", "unblock", "block-remove"].contains(kind)
                socialCommand = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: target,
                    operation: block ? .userBlock(.init(uuid: operation)) : .relationship(.init(uuid: operation)),
                    action: block ? .userBlock(blockAction) : .relationship(relationshipAction), now: now)
                directCommand = nil; preferenceCommand = nil; table = "social_operation_receipts"
            }
            enum Proof: Equatable {
                case direct(V2DirectRoomOperationReceipt), preference(V2AccountPreferenceReceipt), social(V2SocialOperationReceipt)
                var milliseconds: UInt64 {
                    switch self {
                    case .direct(let proof): if case .opened(_, let value) = proof.outcome { return value }; return proof.resolvedAtMilliseconds
                    case .preference(let proof): return proof.resolvedAtMilliseconds
                    case .social(let proof): return proof.resolvedAtMilliseconds
                    }
                }
            }
            func invoke(at clock: Date) async throws -> Proof {
                if let command = directCommand {
                    guard case .receipt(let proof) = try await direct.submitDirectRoomOperation(command, roomID: newRoom,
                        roomShardID: "room-a", capacityProfile: profile, now: clock), case .opened(let room, _) = proof.outcome else { throw CancellationError() }
                    #expect(try room == newRoom && proof.identity == command.identity && proof.fingerprint == command.fingerprint)
                    return .direct(proof)
                }
                if let command = preferenceCommand {
                    guard case .receipt(let proof) = try await preferences.submit(command, now: clock),
                          case .applied(let value, _) = proof.outcome else { throw CancellationError() }
                    #expect(value == command.value && proof.validates(command: command))
                    return .preference(proof)
                }
                let command = try #require(socialCommand)
                guard case .receipt(let proof) = try await social.submitSocialOperation(command, now: clock),
                      case .applied(let value) = proof.outcome else { throw CancellationError() }
                #expect(proof.validates(command: command))
                switch value {
                case .relationship(let state, _):
                    #expect(state == (kind == "request" ? .pending : kind == "accept" ? .accepted : .none))
                case .userBlock(let blocked, _): #expect(blocked == (blockAction == .block))
                }
                return .social(proof)
            }
            func snapshot() async throws -> [String] {
                var result: [String] = []
                for name in ["rooms", "room_memberships", "room_admission", "shard_admission_pools", "direct_room_pairs",
                    "direct_room_owner_receipts", "user_stranger_message_preferences", "user_add_preferences", "account_preference_receipts",
                    "user_relationships", "social_operation_receipts", "social_relationship_revisions", "social_block_revisions",
                    "user_blocks", "user_direct_send_policy_versions", "user_sync_sequences", "user_sync_log", "user_state_event_outbox"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: name) r").first(decoding: StringValueRow.self)
                    result.append(try #require(row).value)
                }
                return result
            }
            let first = try await invoke(at: now)
            let proofCount = try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table) WHERE operation_id=\(bind: operation)").first(decoding: CountRow.self)
            #expect(proofCount?.value == 1)
            if kind == "direct" {
                #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
                let outbox = try PostgresV2UserStateEventOutbox(database: database)
                let projector = try PostgresV2UserStateEventProjector(database: deliveryDB)
                let deliveryTime = max(base, now).addingTimeInterval(60)
                let leases = try await deliverUserStateEvents(outbox, projector: projector, now: deliveryTime, leaseDuration: 1, limit: 100)
                #expect(leases.count == 1)
                let roomTime = try await sql.raw("SELECT floor(extract(epoch FROM created_at)*1000)::bigint AS value FROM im_v2.rooms WHERE room_id=\(bind: newRoom.uuidValue!)").first(decoding: CountRow.self)
                #expect(roomTime?.value == Int64(first.milliseconds))
            } else {
                // The owner samples again after waiting for its policy lock.
                // The receipt must match that persisted sample, not the caller's initial clock.
                #expect(first.milliseconds >= UInt64(try v2GatewayMilliseconds(now)))
            }
            let projectionCount: Int64 = kind == "block-remove" ? 3 : ["request", "accept", "reject", "remove"].contains(kind) ? 2 : 1
            let projectionSQL: any SQLDatabase = kind == "direct" ? deliverySQL : sql
            let key = kind == "direct" ? "room_created_at_ms" : "updated_at_ms"
            let projections = try await projectionSQL.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE source_event_id=\(bind: operation) AND (payload->>\(bind: key))::bigint=\(bind: Int64(first.milliseconds))").first(decoding: CountRow.self)
            #expect(projections?.value == projectionCount)
            let beforeReplay = try await snapshot()
            #expect(try await invoke(at: Date(timeIntervalSince1970: .nan)) == first)
            #expect(try await snapshot() == beforeReplay)
            if kind == "direct" {
                let reopen = try V2DirectRoomOperationCommand(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: target,
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(base))
                let result = try await direct.submitDirectRoomOperation(reopen, roomID: .init(uuid: UUID()), roomShardID: "room-a", capacityProfile: profile, now: base)
                guard case .receipt(let proof) = result, case .opened(let room, let createdAt) = proof.outcome else { throw CancellationError() }
                #expect(room == newRoom && createdAt == first.milliseconds)
                #expect(try await direct.submitDirectRoomOperation(reopen, roomID: .init(uuid: UUID()), roomShardID: "room-a", capacityProfile: profile, now: .init(timeIntervalSince1970: .nan)) == result)
                #expect(try await count("im_v2.direct_room_pairs", on: sql) == 1)
                #expect(try await count("im_v2.direct_room_owner_receipts", on: sql) == 2)
            }
        }
    }

    @Test("Preference responses and projections use the persisted timestamp on first write and replay",
          arguments: ["receipts", "live"])
    func preferenceResponseTimestampPrecision(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let shadow = PreferenceReplayClockDelivery()
            let store = PostgresV2AccountPreferenceOperationStore(database: database, projectionDelivery: shadow,
                authorizationCoordinator: .init(controlDatabase: database, ownerDatabases: ["room-a": database]))
            let stateTable = kind == "receipts" ? "user_read_receipt_preferences" : "user_live_activity_preferences"
            let value: V2AccountPreferenceValue = kind == "receipts" ? .readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: true) : .liveActivity(allowsOnlinePresence: false, allowsTypingIndicators: true)
            func snapshot() async throws -> [String] {
                var result: [String] = []
                for name in ["account_preference_receipts", "account_preference_revisions", stateTable,
                    "read_receipt_preference_propagation_outbox", "user_sync_sequences", "user_sync_log"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: name) r").first(decoding: StringValueRow.self)
                    result.append(try #require(row).value)
                }
                return result
            }
            for seconds in [946_684_800 - 0.00000075, 946_684_800 + 0.00000075, 1_750_000_000 + 0.99999975,
                946_684_800 + 9_223_371_331_200 - 10] as [Double] {
                let now = Date(timeIntervalSince1970: seconds), operation = UUID()
                let reference: V2OperationReference = kind == "receipts" ? .readReceiptPreference(.init(uuid: operation)) : .liveActivityPreference(.init(uuid: operation))
                let command = try await store.freezePreferenceFixture(owner: senderID, operation: reference, value: value, now: now)
                guard case .receipt(let first) = try await store.submit(command, now: now), case .applied(let saved, _) = first.outcome else { throw CancellationError() }
                #expect(first.validates(command: command) && saved == value)
                let row = try await sql.raw("SELECT updated_at AS value FROM im_v2.\(unsafeRaw: stateTable) WHERE user_id = \(bind: senderUUID)").first(decoding: RevocationClockDateRow.self)
                let stored = try #require(row).value
                #expect(try UInt64(v2GatewayMilliseconds(stored)) == first.resolvedAtMilliseconds)
                let projection = try await sql.raw("SELECT (payload->>'updated_at_ms')::bigint AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: operation)").first(decoding: CountRow.self)
                #expect(try projection?.value == v2GatewayMilliseconds(stored))
                // Compare exact persisted timestamps without rebinding a Date;
                // its floating-point round trip can lose a PostgreSQL microsecond.
                let timestamp = try await sql.raw("""
                    SELECT COUNT(*) AS value FROM im_v2.user_sync_log AS event
                    JOIN im_v2.\(unsafeRaw: stateTable) AS preference ON preference.user_id=event.user_id
                    WHERE event.source_event_id=\(bind: operation) AND event.user_id=\(bind: senderUUID)
                      AND event.created_at=preference.updated_at
                    """).first(decoding: CountRow.self)
                #expect(timestamp?.value == 1)
                let before = try await snapshot()
                // Even an invalid current clock cannot replace the saved proof.
                #expect(try await store.submit(command, now: base) == .receipt(first))
                #expect(try await store.submit(command, now: Date(timeIntervalSince1970: -.infinity)) == .receipt(first))
                #expect(try await snapshot() == before)
            }
            let reference: V2OperationReference = kind == "receipts" ? .readReceiptPreference(.init(uuid: UUID())) : .liveActivityPreference(.init(uuid: UUID()))
            let command = try await store.freezePreferenceFixture(owner: senderID, operation: reference, value: value, now: base)
            let before = try await snapshot()
            await #expect(throws: (any Error).self) { try await store.submit(command, now: Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000)) }
            #expect(try await snapshot() == before)
        }
    }

    @Test("Business denials preserve receipt and private-event time through retries",
          arguments: ["scalar", "batch"], ["generic", "system"])
    func denialResponseTimestampPrecision(path: String, reason: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, deliveryDB, sql, deliverySQL, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let direct = PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery())
            var rooms: [RoomID] = []
            for target in [memberTwoUUID, memberThreeUUID] {
                let room = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                        roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { base }).openedIdentity(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: target),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                rooms.append(room.roomID)
            }
            if reason == "system" {
                try await sql.raw("INSERT INTO im_v2.special_accounts (account_user_id, stable_key, account_kind, allows_customer_messages, allows_service_messages, created_at, updated_at) VALUES (\(bind: memberTwoUUID), 'clock_system_target', 'system', false, true, \(bind: base), \(bind: base))").run()
                try await sql.raw("UPDATE im_v2.public_user_profiles SET account_kind = 'system', revision = revision + 1 WHERE user_id = \(bind: memberTwoUUID)").run()
            } else {
                _ = try await PostgresV2AccountPreferenceOperationStore(database: database, projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: .init(controlDatabase: database, ownerDatabases: [:])).executePreferenceFixture(owner: .init(uuid: memberTwoUUID), operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: base)
            }
            let writer = PostgresV2RoomWriteStore(database: database,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
            let admission = writer
            func scalar(_ request: V2RoomWriteRequest) async throws -> V2SendMessageOutcome {
                try await writer.accept(command: request.command, capacityProfile: request.capacityProfile,
                    identifiers: request.identifiers, now: request.now)
            }
            func request(room: RoomID, now: Date) throws -> V2RoomWriteRequest {
                .init(command: try .init(roomID: room, senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
                    text: "business response time", limits: .init(maxUTF8Bytes: 64)), capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())), now: now)
            }
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["direct_message_denials", "room_timeline_activities", "user_state_event_outbox", "user_sync_log", "user_sync_sequences", "rooms", "direct_room_pairs"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    values.append(try #require(row).value)
                }
                return values
            }
            let dates = [Date(timeIntervalSince1970: 946_684_799.99999925),
                         Date(timeIntervalSince1970: 946_684_800.00000075), base.addingTimeInterval(0.99999975),
                         Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)]
            let deniedRoom = try #require(rooms[0].uuidValue)
            for date in dates {
                // Exercise both private events even after an earlier denial
                // has already set the sender's cached capability to false.
                try await sql.raw("UPDATE im_v2.direct_room_pairs SET lower_can_send = true, higher_can_send = true WHERE room_id = \(bind: deniedRoom)").run()
                let input = try request(room: rooms[0], now: date)
                let sibling = try request(room: rooms[1], now: base)
                let outcome: V2SendMessageOutcome
                if path == "batch" {
                    async let denied = admission.accept(input)
                    async let allowed = admission.accept(sibling)
                    let pair = try await (denied, allowed)
                    outcome = pair.0
                    guard case .accepted = pair.1 else { throw CancellationError() }
                } else {
                    outcome = try await scalar(input)
                    guard case .accepted = try await scalar(sibling) else { throw CancellationError() }
                }
                guard case .denied(let denial) = outcome else { Issue.record("Expected normal business denial"); throw CancellationError() }
                #expect(denial.reason == (reason == "system" ? .systemAccountReadOnly : .generic))
                let eventID = try #require(input.identifiers.eventID.uuidValue)
                let storedRow = try await sql.raw("SELECT created_at AS value FROM im_v2.direct_message_denials WHERE source_event_id = \(bind: eventID)").first(decoding: RevocationClockDateRow.self)
                let stored = try #require(storedRow).value
                #expect(denial.createdAt == stored)
                let milliseconds = try v2GatewayMilliseconds(stored)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: eventID)").first(decoding: CountRow.self)?.value == 0)
                let outbox = try PostgresV2UserStateEventOutbox(database: database)
                let projector = try PostgresV2UserStateEventProjector(database: deliveryDB)
                let deliveryTime = max(base, date)
                let leases = try await deliverUserStateEvents(outbox, projector: projector, now: deliveryTime, leaseDuration: 1, limit: 100)
                #expect(leases.filter { $0.event.sourceEventID.uuidValue == eventID }.count == 2)
                for (kind, field) in [("timeline_activity", "server_created_at_ms"), ("direct_sending_capability", "updated_at_ms")] {
                    #expect(try await deliverySQL.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: eventID) AND projection_kind = \(bind: kind) AND (payload->>\(bind: field))::bigint = \(bind: milliseconds) AND created_at = \(bind: date)::timestamptz").first(decoding: CountRow.self)?.value == 1)
                }
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.room_timeline_activities WHERE source_event_id = \(bind: eventID) AND created_at = \(bind: date)::timestamptz").first(decoding: CountRow.self)?.value == 1)
                let before = try await snapshot()
                let replay = V2RoomWriteRequest(command: input.command, capacityProfile: profile, identifiers: input.identifiers, now: base)
                #expect(try await scalar(replay) == outcome)
                #expect(try await admission.accept(replay) == outcome)
                #expect(try await snapshot() == before)
            }
            #expect(try await count("im_v2.direct_message_denials", on: sql) == Int64(dates.count))
            #expect(try await count("im_v2.room_timeline_activities", on: sql) == Int64(dates.count))
            #expect(try await count("im_v2.messages", on: sql) == Int64(dates.count))
        }
    }

    @Test("Stranger quota cutoff bounds and precision agree in scalar, cold and hot writes",
          arguments: ["scalar", "cold", "hot"], ["precision", "lower", "tiny"])
    func strangerQuotaCutoffBounds(path: String, scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            var rooms: [RoomID] = []
            for target in [memberTwoUUID, memberThreeUUID] {
                let room = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                        roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { base }).openedIdentity(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: target),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                rooms.append(room.roomID)
            }
            let interval: TimeInterval = scenario == "precision" ? 0.1234567 : scenario == "tiny" ? 0.0000001 : 86_400
            func writer(window: TimeInterval, cache: V2DirectRoomLogFastAppendCache = .init()) throws -> PostgresV2RoomWriteStore {
                PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: window), contentReviewMode: .disabled,
                    directRoomLogFastAppendCache: cache)
            }
            let fastCache = V2DirectRoomLogFastAppendCache()
            let warm = try writer(window: interval, cache: fastCache)
            func request(_ index: Int, now: Date) throws -> V2RoomWriteRequest {
                .init(command: try .init(roomID: rooms[index], senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "quota window", limits: .init(maxUTF8Bytes: 64)),
                    capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())), now: now)
            }
            func scalar(_ request: V2RoomWriteRequest, on store: PostgresV2RoomWriteStore) async throws -> V2SendMessageOutcome {
                try await store.accept(command: request.command, capacityProfile: request.capacityProfile,
                    identifiers: request.identifiers, now: request.now)
            }
            for index in rooms.indices {
                guard case .accepted = try await scalar(request(index, now: base), on: warm) else { throw CancellationError() }
            }
            let store = path == "hot" ? warm : try writer(window: interval)
            let now: Date = scenario == "precision" ? Date(timeIntervalSince1970: 946_684_800.00000075)
                : scenario == "lower" ? Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000 + 86_399)
                : Date(timeIntervalSince1970: 946_684_800)
            let inputs = try rooms.indices.map { try request($0, now: now) }
            func send(on active: PostgresV2RoomWriteStore, atomic: Bool) async throws -> [V2SendMessageOutcome] {
                if atomic { return try await active.acceptAtomically(requests: inputs) }
                var outcomes: [V2SendMessageOutcome] = []
                for input in inputs { outcomes.append(try await scalar(input, on: active)) }
                return outcomes
            }
            func snapshot() async throws -> [String] {
                var rows: [String] = []
                for table in ["messages", "message_send_completions", "stranger_message_windows", "rooms", "direct_room_pairs", "room_admission", "room_events"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    rows.append(try #require(row).value)
                }
                return rows
            }
            if scenario != "precision" {
                let before = try await snapshot()
                var actual: V2RoomWriteStoreError?
                do { _ = try await send(on: store, atomic: path == "hot") } catch { actual = error as? V2RoomWriteStoreError }
                #expect(actual == .corruptPersistenceState)
                #expect(try await snapshot() == before)
                return
            }
            let cutoff = now.addingTimeInterval(-interval)
            // The canonical scalar cutoff is inclusive: a full window exactly
            // at that timestamp resets, while one microsecond later does not.
            try await sql.raw("UPDATE im_v2.stranger_message_windows SET window_started_at = \(bind: cutoff)::timestamptz + INTERVAL '1 microsecond', message_count = 10").run()
            let before = try await snapshot()
            // A separate rejecting writer preserves the warmed cache so the
            // following successful reset must exercise the prepared fast path.
            let rejecting = try writer(window: interval)
            do { _ = try await send(on: rejecting, atomic: false); Issue.record("Quota must remain exhausted before its cutoff") }
            catch { #expect(error is V2RoomWriteStoreError || error is V2AtomicRoomWriteBatchError) }
            #expect(try await snapshot() == before)
            try await sql.raw("UPDATE im_v2.stranger_message_windows SET window_started_at = \(bind: cutoff)").run()
            let beforeFast = await fastCache.snapshot()
            let outcomes = try await send(on: store, atomic: path == "hot")
            if path == "hot" {
                let afterFast = await fastCache.snapshot()
                #expect(afterFast.committedAppends == beforeFast.committedAppends)
                #expect(afterFast.fallbackAppends == beforeFast.fallbackAppends)
            }
            #expect(outcomes.count == 2)
            for (input, outcome) in zip(inputs, outcomes) {
                guard case .accepted(let message) = outcome else { throw CancellationError() }
                #expect(try await scalar(input, on: store) == .idempotent(message.receipt))
            }
            #expect(try await count("im_v2.messages", on: sql) == 4)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.stranger_message_windows WHERE message_count = 1 AND window_started_at = \(bind: now)::timestamptz").first(decoding: CountRow.self)?.value == 2)
        }
    }

    @Test("Message batches share scalar mute expiry and quota timestamp precision",
          arguments: ["hybrid", "direct"], [946_684_799.99999925, 946_684_800.00000075, 1_750_000_000.1234567])
    func messageBatchCurrentTimestampPrecision(path: String, seconds: Double) async throws {
        try await withForwardOwnerDatabases(mode: path == "hybrid" ? .large : .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: seconds)
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            var rooms = [roomID, roomID]
            var senders = [senderID, UserID(uuid: memberTwoUUID)]
            if path == "direct" {
                rooms = []
                senders = [senderID, senderID]
                for target in [memberTwoUUID, memberThreeUUID] {
                    let room = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                        roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { base }).openedIdentity(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: target),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                    rooms.append(room.roomID)
                }
            }
            func store() throws -> PostgresV2RoomWriteStore {
                PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
            }
            func request(_ index: Int) throws -> V2RoomWriteRequest {
                .init(command: try .init(roomID: rooms[index], senderUserID: senders[index],
                    clientMessageID: .init(uuid: UUID()), text: "expiry clock", limits: .init(maxUTF8Bytes: 64)),
                    capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())), now: now)
            }
            func scalar(_ request: V2RoomWriteRequest, on writer: PostgresV2RoomWriteStore) async throws -> V2SendMessageOutcome {
                try await writer.accept(command: request.command, capacityProfile: request.capacityProfile,
                    identifiers: request.identifiers, now: request.now)
            }
            let mutedRoom = try #require(rooms[0].uuidValue)
            let mutedSender = try #require(senders[0].uuidValue)
            try await sql.raw("""
                INSERT INTO im_v2.room_member_mutes (room_id, user_id, mute_until, actor_user_id, operation_id, created_at)
                VALUES (\(bind: mutedRoom), \(bind: mutedSender), \(bind: now)::timestamptz + INTERVAL '1 microsecond',
                        \(bind: memberTwoUUID), \(bind: UUID()), \(bind: now.addingTimeInterval(-1)))
                """).run()
            let writer = try store()
            let muted = try request(0), sibling = try request(1)
            await #expect(throws: V2RoomWriteStoreError.actorMuted) { try await scalar(muted, on: writer) }
            var batchError: V2AtomicRoomWriteBatchError?
            do { _ = try await writer.acceptAtomically(requests: [muted, sibling]) }
            catch { batchError = error as? V2AtomicRoomWriteBatchError }
            try #require(batchError?.reason == .authorizationState)
            for table in ["messages", "message_send_completions", "room_events", "stranger_message_windows"] {
                #expect(try await count("im_v2." + table, on: sql) == 0)
            }
            let admission = writer
            async let rejected: Void = { () async -> Void in
                await #expect(throws: V2RoomWriteStoreError.actorMuted) { try await admission.accept(muted) }
            }()
            async let accepted = admission.accept(sibling)
            let (_, siblingOutcome) = try await (rejected, accepted)
            guard case .accepted = siblingOutcome else { Issue.record("Normal sibling must complete"); throw CancellationError() }
            #expect(try await count("im_v2.messages", on: sql) == 1)

            // At the exact stored deadline the mute has ended. A fresh writer
            // forces the normal batch preflight rather than a warmed fast path.
            try await sql.raw("UPDATE im_v2.room_member_mutes SET mute_until = \(bind: now) WHERE room_id = \(bind: mutedRoom) AND user_id = \(bind: mutedSender)").run()
            guard case .accepted = try await scalar(request(1), on: writer) else { throw CancellationError() }
            let cold = try store()
            let expiredRequests = [muted, try request(1)]
            let outcomes: [V2SendMessageOutcome]
            if path == "direct" {
                var accepted: [V2SendMessageOutcome] = []
                for request in expiredRequests { accepted.append(try await scalar(request, on: cold)) }
                outcomes = accepted
            } else {
                outcomes = try await cold.acceptAtomically(requests: expiredRequests)
            }
            #expect(outcomes.count == 2)
            for (request, outcome) in zip(expiredRequests, outcomes) {
                guard case .accepted(let message) = outcome else { throw CancellationError() }
                #expect(try await scalar(request, on: cold) == .idempotent(message.receipt))
            }
            #expect(try await count("im_v2.messages", on: sql) == 4)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 4)
            if path == "direct" {
                #expect(try await count("im_v2.stranger_message_windows", on: sql) == 2)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.stranger_message_windows WHERE window_started_at IS DISTINCT FROM \(bind: now)::timestamptz").first(decoding: CountRow.self)?.value == 0)
                #expect(try await sql.raw("SELECT SUM(message_count)::bigint AS value FROM im_v2.stranger_message_windows").first(decoding: CountRow.self)?.value == 4)
            }
        }
    }

    @Test("Message append paths retain the scalar timestamp and replay the same wire milliseconds",
          arguments: ["group", "hybrid", "hybrid-batch", "direct", "direct-room"], [false, true])
    func messageAppendTimestampPrecision(path: String, nearDatabaseBounds: Bool) async throws {
        try await withForwardOwnerDatabases(mode: path.hasPrefix("hybrid") ? .large : .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            var rooms = [roomID, roomID]
            if path.hasPrefix("direct") {
                rooms = []
                for target in [memberTwoUUID, memberThreeUUID] {
                    let room = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                        roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { base }).openedIdentity(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: target),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                    rooms.append(room.roomID)
                }
            }
            let store = PostgresV2RoomWriteStore(database: database,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
            func scalar(_ request: V2RoomWriteRequest) async throws -> V2SendMessageOutcome {
                try await store.accept(command: request.command, capacityProfile: request.capacityProfile,
                    identifiers: request.identifiers, now: request.now)
            }
            let dates: [Date]
            if nearDatabaseBounds {
                // Direct sends also need a representable preceding quota window.
                let lowerOffset: TimeInterval = path.hasPrefix("direct") ? 86_400 : 0
                dates = [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000 + lowerOffset),
                         Date(timeIntervalSince1970: -0.00000075),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 120),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)]
                let expiry = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 1)
                try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until = \(bind: expiry)").run()
            } else {
                dates = [Date(timeIntervalSince1970: 946_684_799.99999925),
                         Date(timeIntervalSince1970: 946_684_800.00000075),
                         base.addingTimeInterval(0.1234567),
                         base.addingTimeInterval(0.99999975)]
            }
            for date in dates {
                let requests = try rooms.enumerated().map { offset, room in
                    V2RoomWriteRequest(command: try .init(roomID: room, senderUserID: senderID,
                        clientMessageID: .init(uuid: UUID()), text: "message clock", limits: .init(maxUTF8Bytes: 64)),
                        capacityProfile: profile,
                        identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())),
                        now: date.addingTimeInterval(Double(offset) * 0.25))
                }
                let outcomes: [V2SendMessageOutcome]
                if path.hasSuffix("batch") { outcomes = try await store.acceptAtomically(requests: requests) }
                else {
                    var values: [V2SendMessageOutcome] = []
                    for request in requests { values.append(try await scalar(request)) }
                    outcomes = values
                }
                #expect(outcomes.count == requests.count)
                for (request, outcome) in zip(requests, outcomes) {
                    guard case .accepted(let message) = outcome else { Issue.record("Expected fresh acceptance"); throw CancellationError() }
                    let messageID = try #require(request.identifiers.messageID.uuidValue)
                    // Verify the actual timestamp in SQL, not just its decoded Date.
                    for table in ["messages", "message_send_completions"] {
                        #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table) WHERE message_id = \(bind: messageID) AND created_at = \(bind: request.now)::timestamptz").first(decoding: CountRow.self)?.value == 1)
                    }
                    let native = try #require(try await sql.raw("""
                        SELECT floor(extract(epoch FROM created_at) * 1000)::bigint AS value
                        FROM im_v2.messages WHERE message_id = \(bind: messageID)
                        """).first(decoding: CountRow.self)).value
                    if let event = try await sql.raw("""
                        SELECT (payload->>'server_created_at_ms')::bigint AS value
                        FROM im_v2.room_events WHERE event_id = \(bind: request.identifiers.eventID.uuidValue!)
                          AND payload ? 'server_created_at_ms'
                        """).first(decoding: CountRow.self) {
                        #expect(event.value == native)
                    }
                    let projection = try V2MessageProjectionState(accepted: message, forwardedFromMessageID: nil, forwardedFromUserID: nil)
                    #expect(projection.acceptedAtUnixMilliseconds == native)
                    if path.hasPrefix("direct") {
                        let payload = try #require(V2DirectRoomLogPayloadCodec.encode(message))
                        let cached = try JSONDecoder().decode(V2MessageProjectionState.self, from: payload)
                        #expect(cached.acceptedAtUnixMilliseconds == native)
                        let live = try #require(V2DirectRoomLiveEvent(message))
                        #expect(live.payload == payload)
                        let cache = V2DirectRoomLogEventCache(configuration: .init(maximumEvents: 4, maximumBytes: 1_048_576, maximumEventsPerRoom: 4))
                        await cache.recordCommittedPlainDirectMessage(message)
                        let page = try #require(await cache.page(roomID: message.roomID, actorJoinedRevision: 0, actorLeftRevision: nil,
                            currentHighWatermark: message.roomSequence, afterRoomSequence: message.roomSequence - 1, pageSize: 1))
                        #expect(page.events.map(\.payload) == [payload])
                        await cache.finish()
                    }
                    guard case .idempotent(let receipt) = try await scalar(request) else { Issue.record("Expected canonical replay"); throw CancellationError() }
                    #expect(try v2GatewayMilliseconds(receipt.createdAt) == v2GatewayMilliseconds(message.createdAt))
                    #expect(receipt.messageID == message.messageID)
                }
            }
            #expect(try await count("im_v2.messages", on: sql) == Int64(dates.count * 2))
            #expect(try await count("im_v2.message_send_completions", on: sql) == Int64(dates.count * 2))
        }
    }

    @Test("Scalar and batched presence renewals preserve stored precision under database-clock authority")
    func liveLeaseBatchTimestampPrecision() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UUID(), device = UUID(), scalarConnection = UUID(), batchConnection = UUID()
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: user), \(bind: device), \(bind: base), \(bind: base))").run()
            let identity = V2AuthenticatedConnection(userID: .init(uuid: user), deviceID: .init(uuid: device), capabilityProfile: "base")
            let store = try PostgresV2LiveActivityStore(database: resources.database(.psql))
            let dates = [Date(timeIntervalSince1970: 946_684_800.00000075),
                         Date(timeIntervalSince1970: 946_684_799.99999925),
                         base.addingTimeInterval(0.1234567),
                         Date(timeIntervalSince1970: 946_684_800.99999975),
                         Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 120)]
            for now in dates {
                for remainingMicroseconds in [Int64(0), 1, 1_000_000] {
                    try await sql.raw("DELETE FROM im_v2.user_live_presence_leases").run()
                    let earlier = now.addingTimeInterval(-1)
                    let initialUpdate = v2PostgresTimestampCanEncode(earlier) ? earlier : now
                    // Seed identical leases using the scalar driver's time representation.
                    // SQL keeps the one-microsecond difference even where Date cannot.
                    for connection in [scalarConnection, batchConnection] {
                        try await sql.raw("""
                            INSERT INTO im_v2.user_live_presence_leases
                                (user_id, device_id, connection_id, expires_at, updated_at)
                            VALUES (\(bind: user), \(bind: device), \(bind: connection),
                                    \(bind: now)::timestamptz + \(bind: remainingMicroseconds) * INTERVAL '1 microsecond',
                                    \(bind: initialUpdate))
                            """).run()
                    }
                    struct Seed: Decodable { let value: Date; let active: Bool }
                    let seed = try #require(try await sql.raw("SELECT expires_at AS value, expires_at > clock_timestamp() AS active FROM im_v2.user_live_presence_leases WHERE connection_id=\(bind:scalarConnection)").first(decoding:Seed.self))
                    let scalar = try await store.renewConnection(identity: identity, connectionID: scalarConnection, now: now)
                    let batch = try await store.renewConnections([
                        .init(identity: identity, connectionID: batchConnection, now: now)
                    ])
                    // Historical input precision remains intact, but only actual database expiry authorizes renewal.
                    // The finite future-endpoint row dominates the 90-second renewal and retains every stored microsecond.
                    let expected: V2AuthenticatedConnectionLeaseOutcome = seed.active ? .accepted(expiresAt: seed.value) : .rejected
                    #expect(scalar == expected)
                    #expect(batch[batchConnection]?.outcome == expected)
                    #expect(batch[batchConnection]?.allowsOnlinePresence == true)
                    #expect((batch[batchConnection]?.remainingLeaseSeconds != nil) == seed.active)
                    // Compare persisted timestamps in SQL, without losing microseconds
                    // through Date decoding near PostgreSQL's finite endpoints.
                    #expect(try await sql.raw("""
                        SELECT COUNT(*) AS value
                        FROM im_v2.user_live_presence_leases scalar
                        JOIN im_v2.user_live_presence_leases batched
                          ON batched.connection_id = \(bind: batchConnection)
                        WHERE scalar.connection_id = \(bind: scalarConnection)
                          AND scalar.expires_at = batched.expires_at
                          AND scalar.updated_at = batched.updated_at
                        """).first(decoding: CountRow.self)?.value == 1)
                }
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("Scalar and batched group receipts preserve the same PostgreSQL timestamp",
          arguments: [V2GroupCapacityClass.standard, .large], ["mixed", "group", "owner"])
    func receiptBatchTimestampPrecision(mode: V2GroupCapacityClass, path: String) async throws {
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let store = PostgresV2ReadReceiptStore(database: database)
            let route = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
            let dates = [Date(timeIntervalSince1970: 946_684_800.00000075),
                         Date(timeIntervalSince1970: 946_684_799.99999925),
                         base.addingTimeInterval(0.1234567),
                         Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)]
            try await sql.raw("UPDATE im_v2.rooms SET room_sequence = \(bind: dates.count) WHERE room_id = \(bind: roomUUID)").run()
            func batch(_ requests: [V2ReadReceiptRecordRequest]) async throws -> [V2ReadReceiptRecordResult] {
                if path == "mixed" { return try await store.recordBatch(requests) }
                let result = path == "owner"
                    ? try await store.recordGroupsOwnerValidated(requests.map { .init(request: $0, ownerRoute: route) })
                    : try await store.recordGroups(requests)
                return try result.map {
                    switch $0 {
                    case .success(.handled(let outcome)): return .success(outcome)
                    case .failure(let error): return .failure(error)
                    case .success(.notGroup): throw CancellationError()
                    }
                }
            }
            func snapshot() async throws -> String {
                let row = try await sql.raw("""
                    SELECT jsonb_build_object(
                        'operations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id, operation_id) FROM im_v2.read_receipt_operations r),
                        'receipts', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id, user_id) FROM im_v2.room_read_receipts r)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)
                return try #require(row).value
            }
            for (index, date) in dates.enumerated() {
                let sequence = UInt64(index + 1)
                let scalar = try V2RecordReadReceiptCommand(roomID: roomID, actorUserID: senderID,
                    operationID: .init(uuid: UUID()), readThroughRoomSequence: sequence)
                guard case .recorded(let scalarReceipt) = try await store.record(command: scalar, now: date) else { throw CancellationError() }
                let requests = try [memberTwoUUID, memberThreeUUID].enumerated().map { offset, actor in
                    V2ReadReceiptRecordRequest(command: try .init(roomID: roomID, actorUserID: .init(uuid: actor),
                        operationID: .init(uuid: UUID()), readThroughRoomSequence: sequence), now: date.addingTimeInterval(TimeInterval(offset)))
                }
                let actual = try await batch(requests)
                var expectedReceipts: [V2ReadReceipt] = []
                for (offset, request) in requests.enumerated() {
                    let expectedDate = try #require(try await sql.raw("SELECT \(bind: request.now)::timestamptz AS value").first(decoding: RevocationClockDateRow.self)).value
                    let expected = try V2ReadReceipt(roomID: roomID, userID: request.command.actorUserID,
                        readThroughRoomSequence: sequence, recordedAt: expectedDate)
                    expectedReceipts.append(expected)
                    if offset == 0 { #expect(expected.recordedAt == scalarReceipt.recordedAt) }
                    let operation = try #require(UUID(uuidString: request.command.operationID.rawValue))
                    let actor = try #require(UUID(uuidString: request.command.actorUserID.rawValue))
                    #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.read_receipt_operations WHERE operation_id = \(bind: operation) AND recorded_at IS DISTINCT FROM \(bind: request.now)::timestamptz").first(decoding: CountRow.self)?.value == 0)
                    #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.room_read_receipts WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: actor) AND updated_at IS DISTINCT FROM \(bind: request.now)::timestamptz").first(decoding: CountRow.self)?.value == 0)
                }
                #expect(actual == expectedReceipts.map { .success(.recorded($0)) })
                #expect(try await count("im_v2.read_receipt_operations", on: sql) == Int64((index + 1) * 3))
                let before = try await snapshot()
                #expect(try await store.record(command: scalar, now: base) == .idempotent(scalarReceipt))
                let retries = requests.map { V2ReadReceiptRecordRequest(command: $0.command, now: base) }
                #expect(try await batch(retries) == expectedReceipts.map { .success(.idempotent($0)) })
                for (request, expected) in zip(requests, expectedReceipts) {
                    #expect(try await store.record(command: request.command, now: base) == .idempotent(expected))
                }
                #expect(try await snapshot() == before)
            }
        }
    }

    @Test("Message storage checks caller-supplied clocks and isolates invalid batch entries",
          arguments: ["group", "hybrid", "direct-room"])
    func messageStorageClockBounds(path: String) async throws {
        try await withForwardOwnerDatabases(mode: path == "hybrid" ? .large : .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let targetRoom: RoomID
            if path.hasPrefix("direct") {
                let room = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                        roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { base }).openedIdentity(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                targetRoom = room.roomID
            } else { targetRoom = roomID }
            let store = PostgresV2RoomWriteStore(database: database,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
            let admission = store
            let route = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
            func request(at date: Date, actor: UserID) throws -> V2RoomWriteRequest {
                .init(command: try .init(roomID: targetRoom, senderUserID: actor, clientMessageID: .init(uuid: UUID()),
                    text: "clock fixture", limits: .init(maxUTF8Bytes: 64)), capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())), now: date)
            }
            func scalar(_ request: V2RoomWriteRequest) async throws -> V2SendMessageOutcome {
                try await store.accept(command: request.command, capacityProfile: request.capacityProfile,
                    identifiers: request.identifiers, now: request.now)
            }
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["messages", "message_send_completions", "direct_message_denials", "rooms", "room_memberships",
                    "room_events", "room_timeline_activities",
                    "room_admission", "shard_admission_pools", "direct_room_pairs", "user_sync_log", "user_sync_sequences"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    values.append(try #require(row).value)
                }
                return values
            }
            guard case .accepted = try await scalar(request(at: base, actor: senderID)) else { throw CancellationError() }
            // Start with a finite driver-encodable date outside PostgreSQL's
            // range. A missing guard fails this requirement before the test
            // reaches non-finite dates that the driver's encoder cannot handle.
            for (index, seconds) in [-1e12, Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
                                     -.greatestFiniteMagnitude, 1e14, -1e14].enumerated() {
                let bad = try request(at: Date(timeIntervalSince1970: seconds), actor: senderID)
                let good = try request(at: base, actor: .init(uuid: memberTwoUUID))
                let before = try await snapshot()
                var scalarError: V2RoomWriteStoreError?
                do { _ = try await scalar(bad) } catch { scalarError = error as? V2RoomWriteStoreError }
                try #require(scalarError == .corruptPersistenceState)
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                    try await store.acceptOwnerValidated(request: bad, ownerRoute: route)
                }
                let ordered = index.isMultiple(of: 2) ? [bad, good] : [good, bad]
                let invalidIndex = index.isMultiple(of: 2) ? 0 : 1
                #expect(await store.atomicBatchEligibility(requests: ordered)[invalidIndex] == false)
                #expect(await store.atomicBatchPartitions(requests: ordered)[invalidIndex] == nil)
                let batchError = V2AtomicRoomWriteBatchError(reason: .requestShape)
                await #expect(throws: batchError) { try await store.acceptAtomically(requests: ordered) }
                await #expect(throws: batchError) {
                    try await store.acceptAtomicallyOwnerValidated(requests: ordered.map { .init(request: $0, ownerRoute: route) })
                }
                #expect(try await snapshot() == before)
                async let rejected: Void = { () async -> Void in
                    await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await admission.accept(bad) }
                }()
                async let accepted = admission.accept(good)
                let (_, outcome) = try await (rejected, accepted)
                guard case .accepted(let message) = outcome else { Issue.record("Normal sibling failed"); throw CancellationError() }
                #expect(try await scalar(good) == .idempotent(message.receipt))
                let after = try await snapshot()
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await admission.accept(bad) }
                #expect(try await snapshot() == after)
            }
            #expect(try await count("im_v2.messages", on: sql) == 9)
        }
    }

    @Test("Membership events validate their source group timestamp without changing completed retries",
          arguments: [V2GroupCapacityClass.standard, .large])
    func membershipSourceTimestampBounds(mode: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            let target = UserID(uuid: memberTwoUUID)
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
            let store = PostgresV2MembershipOperationStore(database: database, clock: { base })
            let identity = try await V2PostgresMembershipIdentitySnapshotValidator(database: database).snapshot(actorUserID: senderID, targetUserID: target)
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["group_rooms", "rooms", "room_memberships", "membership_operation_receipts", "membership_operation_admissions",
                    "room_events", "user_state_event_outbox", "room_admission", "shard_admission_pools", "user_sync_log", "user_sync_sequences"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    values.append(try #require(row).value)
                }
                return values
            }
            var revision: UInt64 = 0
            for date in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10), base] {
                for action in [V2RoomMembershipAction.remove, .add] {
                    try await sql.raw("UPDATE im_v2.group_rooms SET created_at=\(bind:base) WHERE room_id=\(bind:roomUUID)").run()
                    let intent = try V2MembershipIntent(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()),
                        targetUserID: target, action: action, expectedMembershipRevision: revision, confirmedUntilMilliseconds: 1_750_000_120_000)
                    let admission = try await withRoomActivation(database: database, roomID: roomID) { token in
                        guard case .admitted(let value) = try await store.admit(intent, identitySnapshot: identity, token: token) else { throw CancellationError() }
                        return value
                    }
                    let command = try V2MembershipOperationCommand(intent: intent, admission: admission)
                    func invoke() async throws -> V2MembershipRecoveryResult {
                        try await withRoomActivation(database: database, roomID: roomID) { token in
                            try await store.submit(command, token: token, capacityProfile: profile, eventID: .init(uuid: UUID()), identitySnapshot: identity)
                        }
                    }
                    for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                        try await sql.raw("UPDATE im_v2.group_rooms SET created_at=\(bind:literal)::timestamptz WHERE room_id=\(bind:roomUUID)").run()
                        let before = try await snapshot()
                        await #expect(throws: V2RoomMembershipStoreError.corruptPersistenceState) { try await invoke() }
                        #expect(try await snapshot() == before)
                    }
                    try await sql.raw("UPDATE im_v2.group_rooms SET created_at=\(bind:date) WHERE room_id=\(bind:roomUUID)").run()
                    guard case .receipt(let receipt) = try await invoke(), case .changed(let changed) = receipt.outcome else { throw CancellationError() }
                    revision += 1
                    #expect(receipt.validates(command: command) && changed.membershipRevision == revision && changed.roomSequence == revision)
                    let projected = try await sql.raw("SELECT (payload->>'created_at_ms')::bigint AS value FROM im_v2.room_events WHERE event_id=\(bind:changed.eventID.uuidValue!)").first(decoding: CountRow.self)
                    #expect(try #require(projected).value == v2GatewayMilliseconds(date))
                    try await sql.raw("UPDATE im_v2.group_rooms SET created_at='infinity'::timestamptz WHERE room_id=\(bind:roomUUID)").run()
                    let before = try await snapshot()
                    #expect(try await invoke() == .receipt(receipt))
                    let wrongFingerprint = try V2OperationFingerprint(kind: .membership, fields: [.init("changed", .text("action"))])
                    let conflict = try await withRoomActivation(database: database, roomID: roomID) { token in
                        try await store.recover(.init(identity: command.identity, fingerprint: wrongFingerprint, action: .query), token: token)
                    }
                    #expect(conflict == .fingerprintConflict)
                    #expect(try await snapshot() == before)
                }
            }
            #expect(try await count("im_v2.membership_operation_receipts", on: sql) == 6)
            #expect(try await count("im_v2.room_memberships WHERE left_revision IS NULL", on: sql) == 3)
        }
    }

    @Test("Message replay validates saved response times across direct store and service admission",
          arguments: ["group", "hybrid", "direct-planner", "direct-room-log", "direct-denial"])
    func messageReplayStoredTimestampBounds(path: String) async throws {
        try await withForwardOwnerDatabases(mode: path == "hybrid" ? .large : .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let targetRoom: RoomID
            if path.hasPrefix("direct") {
                let direct = PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery())
                let room = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                        roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { base }).openedIdentity(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                targetRoom = room.roomID
                if path == "direct-denial" {
                    _ = try await PostgresV2AccountPreferenceOperationStore(database: database, projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: .init(controlDatabase: database, ownerDatabases: [:])).executePreferenceFixture(owner: .init(uuid: memberTwoUUID), operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: base)
                }
            } else { targetRoom = roomID }
            let store = PostgresV2RoomWriteStore(database: database)
            let scalar = V2SendMessageService(store: store, capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { base })
            let client = UUID()
            let command = V2AuthenticatedSendMessage(roomID: targetRoom, actorUserID: senderID, clientMessageID: .init(uuid: client), text: "saved response")
            let conflict = V2AuthenticatedSendMessage(roomID: targetRoom, actorUserID: senderID, clientMessageID: command.clientMessageID, text: "changed request")
            let original = try await scalar.send(command)
            func expected(at date: Date) throws -> V2SendMessageOutcome {
                switch original {
                case .accepted(let message):
                    let r = message.receipt
                    return .idempotent(.init(messageID: r.messageID, roomID: r.roomID, roomSequence: r.roomSequence,
                        timelineSequence: r.timelineSequence, senderUserID: r.senderUserID, clientMessageID: r.clientMessageID,
                        groupCapacityClass: r.groupCapacityClass, sourceEventID: r.sourceEventID,
                        acceptedMembershipRevision: r.acceptedMembershipRevision, directRecipientUserID: r.directRecipientUserID, createdAt: date))
                case .denied(let denial):
                    #expect(path == "direct-denial")
                    return .denied(.init(roomID: denial.roomID, sourceEventID: denial.sourceEventID,
                        timelineSequence: denial.timelineSequence, createdAt: date, reason: denial.reason))
                default: Issue.record("Expected initial message acceptance or business denial"); throw CancellationError()
                }
            }
            if path == "direct-denial" { guard case .denied = original else { throw CancellationError() } }
            #expect(try await scalar.send(command) == expected(at: base))
            let table = path == "direct-denial" ? "direct_message_denials" : "message_send_completions"
            func setSavedTime(_ literal: String) async throws {
                // Attempt replacement with all production constraints enabled.
                // Permanent completion proofs must reject this operation.
                try await sql.raw("""
                    WITH removed AS (
                        DELETE FROM im_v2.\(unsafeRaw: table)
                        WHERE sender_user_id = \(bind: senderUUID) AND client_message_id = \(bind: client)
                        RETURNING *
                    )
                    INSERT INTO im_v2.\(unsafeRaw: table)
                    SELECT (jsonb_populate_record(NULL::im_v2.\(unsafeRaw: table),
                        to_jsonb(removed) || jsonb_build_object('created_at', \(bind: literal)::timestamptz))).*
                    FROM removed
                    """).run()
            }
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["messages", "message_send_completions", "direct_message_denials", "rooms", "room_memberships",
                    "room_events", "room_timeline_activities",
                    "room_admission", "shard_admission_pools", "direct_room_pairs", "user_sync_log", "user_sync_sequences"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    values.append(try #require(row).value)
                }
                return values
            }
            if path != "direct-denial" {
                // Permanent completion proofs reject replacement, including
                // extreme timestamps. Replays retain the original result.
                for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                    let before = try await snapshot()
                    await #expect(throws: (any Error).self) { try await setSavedTime(literal) }
                    #expect(try await snapshot() == before)
                    for service in [scalar] {
                        #expect(try await service.send(command) == expected(at: base))
                        #expect(try await service.send(conflict) == .idempotencyConflict)
                    }
                    let sibling = V2AuthenticatedSendMessage(roomID: targetRoom, actorUserID: .init(uuid: memberTwoUUID),
                        clientMessageID: .init(uuid: UUID()), text: "normal sibling")
                    async let replay = scalar.send(command)
                    async let accepted = scalar.send(sibling)
                    let (original, outcome) = try await (replay, accepted)
                    let expectedOriginal = try expected(at: base)
                    #expect(original == expectedOriginal)
                    guard case .accepted(let message) = outcome else { throw CancellationError() }
                    #expect(try await scalar.send(sibling) == .idempotent(message.receipt))
                }
            } else {
            for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                try await setSavedTime(literal)
                let before = try await snapshot()
                for service in [scalar] {
                    await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await service.send(command) }
                    #expect(try await service.send(conflict) == .idempotencyConflict)
                }
                #expect(try await snapshot() == before)
                // An adjacent valid send must complete even when the replay
                // uses the batcher's ordinary-path fallback and fails.
                let sibling = V2AuthenticatedSendMessage(roomID: targetRoom, actorUserID: .init(uuid: memberTwoUUID),
                    clientMessageID: .init(uuid: UUID()), text: "normal sibling")
                async let rejected: Void = { () async -> Void in
                    await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await scalar.send(command) }
                }()
                async let accepted = scalar.send(sibling)
                let (_, outcome) = try await (rejected, accepted)
                guard case .accepted(let message) = outcome else { Issue.record("Valid sibling did not commit"); throw CancellationError() }
                #expect(try await scalar.send(sibling) == .idempotent(message.receipt))
                let after = try await snapshot()
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await scalar.send(command) }
                #expect(try await snapshot() == after)
            }
            for date in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10), base] {
                let literal = try await sql.raw("SELECT \(bind: date)::timestamptz::text AS value").first(decoding: StringValueRow.self)
                try await setSavedTime(try #require(literal).value)
                let before = try await snapshot()
                for service in [scalar] { #expect(try await service.send(command) == expected(at: date)) }
                #expect(try await snapshot() == before)
            }
            }
            #expect(try await count("im_v2.messages", on: sql) == (path == "direct-denial" ? 3 : 4))
        }
    }

    @Test("Sync responses reject interior gaps without issuing capabilities and recover through the maximum sequence",
          arguments: [Int64(0), Int64.max - 3], [false, true])
    func syncResponseContiguousSequenceBoundary(start: Int64, withToken: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let userUUID = UUID(), deviceUUID = UUID()
            let user = UserID(uuid: userUUID), device = DeviceID(uuid: deviceUUID)
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: now), \(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.device_sync_cursors (user_id, device_id, state, reset_generation, acknowledged_sequence) VALUES (\(bind: userUUID), \(bind: deviceUUID), 'ready', 1, \(bind: start))").run()
            let store = V2SyncService(store: PostgresV2SyncStore(database: database), now: { now })
            guard case .ready(_, let empty, let initialToken, _, _) = try await store.pull(userID: user,
                deviceID: device, syncToken: nil, requestedMaxRecords: 3) else { throw CancellationError() }
            #expect(empty.isEmpty)
            let token: V2SyncToken? = withToken ? initialToken : nil
            let events = [UUID(), UUID(), UUID()]
            try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: userUUID), \(bind: start + 3))").run()
            func insert(_ index: Int) async throws {
                try await sql.raw("""
                    INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                    VALUES (\(bind: userUUID), \(bind: start + Int64(index) + 1), \(bind: events[index]),
                        'stranger_message_permission', '{"allows_stranger_messages":true}'::jsonb, \(bind: now))
                    """).run()
            }
            for index in events.indices { try await insert(index) }
            try await sql.raw("DELETE FROM im_v2.user_sync_log WHERE user_id = \(bind: userUUID) AND user_sync_sequence = \(bind: start + 2)").run()
            func capabilities() async throws -> String {
                guard let row = try await sql.raw("""
                    SELECT jsonb_build_object(
                        'cursor', (SELECT jsonb_agg(to_jsonb(r)) FROM im_v2.device_sync_cursors r WHERE user_id = \(bind: userUUID)),
                        'tokens', (SELECT jsonb_agg(to_jsonb(r) ORDER BY token) FROM im_v2.sync_tokens r WHERE user_id = \(bind: userUUID)),
                        'receipts', (SELECT jsonb_agg(to_jsonb(r) ORDER BY receipt) FROM im_v2.sync_receipts r WHERE user_id = \(bind: userUUID))
                    )::text AS value
                    """).first(decoding: StringValueRow.self) else { throw CancellationError() }
                return row.value
            }
            let before = try await capabilities()
            for _ in 0..<2 {
                await #expect(throws: V2SyncStoreError.syncLogSequenceGap) {
                    try await store.pull(userID: user, deviceID: device, syncToken: token, requestedMaxRecords: 3)
                }
                #expect(try await capabilities() == before)
            }
            // A gap in the unsent look-ahead row does not invalidate the
            // complete prefix that fits this page.
            guard case .ready(_, let prefix, let continuation, _, let more) = try await store.pull(userID: user,
                deviceID: device, syncToken: token, requestedMaxRecords: 1) else { throw CancellationError() }
            #expect(prefix.map(\.sequence) == [UInt64(start + 1)] && more)
            // The same valid prefix can be selected by a byte budget rather
            // than by the caller's record limit.
            let narrow = V2SyncService(store: PostgresV2SyncStore(database: database, maximumEncodedRecordsBytes: 200), now: { now })
            guard case .ready(_, let bytePrefix, _, _, let byteMore) = try await narrow.pull(userID: user,
                deviceID: device, syncToken: token, requestedMaxRecords: 3) else { throw CancellationError() }
            #expect(bytePrefix == prefix && byteMore)
            let afterPrefix = try await capabilities()
            await #expect(throws: V2SyncStoreError.syncLogSequenceGap) {
                try await store.pull(userID: user, deviceID: device, syncToken: continuation, requestedMaxRecords: 3)
            }
            #expect(try await capabilities() == afterPrefix)
            try await insert(1)
            for _ in 0..<2 {
                guard case .ready(let generation, let records, let next, let receipt, let hasMore) = try await store.pull(
                    userID: user, deviceID: device, syncToken: continuation, requestedMaxRecords: 3) else { throw CancellationError() }
                #expect(records.map(\.sequence) == [UInt64(start + 2), UInt64(start + 3)] && !hasMore)
                try await store.acknowledge(userID: user, deviceID: device, generation: generation,
                    highestContiguousSequence: UInt64(start + 3), receipt: receipt)
                guard case .ready(_, let tail, _, _, let more) = try await store.pull(userID: user,
                    deviceID: device, syncToken: next, requestedMaxRecords: 3) else { throw CancellationError() }
                #expect(tail.isEmpty && !more)
            }
        }
    }

    @Test("An oversized later sync record preserves the sendable prefix and never advances past the record", arguments: [1, 2])
    func syncResponseOversizedLaterRecord(prefixCount: Int) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let userUUID = UUID(), deviceUUID = UUID(), event = UUID()
            let user = UserID(uuid: userUUID), device = DeviceID(uuid: deviceUUID)
            let last = Int64(prefixCount + 1)
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: now), \(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: userUUID), \(bind: last))").run()
            for sequence in 1...prefixCount {
                try await sql.raw("""
                    INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                    VALUES (\(bind: userUUID), \(bind: Int64(sequence)), \(bind: UUID()),
                        'stranger_message_permission', '{"allows_stranger_messages":true}'::jsonb, \(bind: now))
                    """).run()
            }
            let state = try V2MessageProjectionState(accepted: .init(messageID: .init(uuid: UUID()), roomID: roomID,
                roomSequence: 1, senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
                text: String(repeating: "x", count: 1_000), mediaPresentations: [], createdAt: now),
                forwardedFromMessageID: nil, forwardedFromUserID: nil)
            let payload = try state.encodedPayloadJSON()
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                VALUES (\(bind: userUUID), \(bind: last), \(bind: event), 'message', \(bind: payload)::jsonb, \(bind: now))
                """).run()
            let narrow = V2SyncService(store: PostgresV2SyncStore(database: database, maximumEncodedRecordsBytes: 512), now: { now })
            guard case .ready(let generation, let prefix, let continuation, let receipt, let more) = try await narrow.pull(
                userID: user, deviceID: device, syncToken: nil, requestedMaxRecords: 5) else { throw CancellationError() }
            #expect(prefix.map(\.sequence) == (1...prefixCount).map { UInt64($0) } && more)
            #expect(prefix.reduce(0) { $0 + v2EncodedSyncBatchRecordFieldBytes($1) } <= 512)
            #expect(try await sql.raw("SELECT watermark AS value FROM im_v2.sync_tokens WHERE token = \(bind: continuation.rawValue)").first(decoding: CountRow.self)?.value == Int64(prefixCount))
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.sync_receipts WHERE receipt = \(bind: receipt.rawValue) AND first_sequence = 1 AND last_sequence = \(bind: Int64(prefixCount))").first(decoding: CountRow.self)?.value == 1)
            try await narrow.acknowledge(userID: user, deviceID: device, generation: generation,
                highestContiguousSequence: UInt64(prefixCount), receipt: receipt)
            func capabilities() async throws -> String {
                guard let row = try await sql.raw("""
                    SELECT jsonb_build_object(
                        'cursor', (SELECT jsonb_agg(to_jsonb(r)) FROM im_v2.device_sync_cursors r WHERE user_id = \(bind: userUUID)),
                        'tokens', (SELECT jsonb_agg(to_jsonb(r) ORDER BY token) FROM im_v2.sync_tokens r WHERE user_id = \(bind: userUUID)),
                        'receipts', (SELECT jsonb_agg(to_jsonb(r) ORDER BY receipt) FROM im_v2.sync_receipts r WHERE user_id = \(bind: userUUID))
                    )::text AS value
                    """).first(decoding: StringValueRow.self) else { throw CancellationError() }
                return row.value
            }
            let before = try await capabilities()
            for token: V2SyncToken? in [continuation, nil, continuation, nil] {
                await #expect(throws: V2SyncStoreError.syncRecordTooLarge) {
                    try await narrow.pull(userID: user, deviceID: device, syncToken: token, requestedMaxRecords: 5)
                }
                #expect(try await capabilities() == before)
            }
            // A larger response budget resumes at the unsent record. Neither
            // prefix delivery nor failed retries are allowed to skip it.
            let wider = V2SyncService(store: PostgresV2SyncStore(database: database, maximumEncodedRecordsBytes: 8_192), now: { now })
            guard case .ready(let resumedGeneration, let records, let next, let finalReceipt, let hasMore) = try await wider.pull(
                userID: user, deviceID: device, syncToken: continuation, requestedMaxRecords: 5) else { throw CancellationError() }
            #expect(resumedGeneration == generation && !hasMore && records.count == 1)
            let record = try #require(records.first)
            #expect(record.sequence == UInt64(last) && record.sourceEventID == EventID(uuid: event) && record.projectionKind == "message")
            #expect(v2EncodedSyncBatchRecordFieldBytes(record) > 512)
            #expect(try JSONDecoder().decode(V2MessageProjectionState.self, from: Data(record.payloadJSON.utf8)) == state)
            try await wider.acknowledge(userID: user, deviceID: device, generation: generation,
                highestContiguousSequence: UInt64(last), receipt: finalReceipt)
            guard case .ready(_, let tail, _, _, let tailMore) = try await narrow.pull(userID: user,
                deviceID: device, syncToken: next, requestedMaxRecords: 5) else { throw CancellationError() }
            #expect(tail.isEmpty && !tailMore)
        }
    }

    @Test("Pending snapshot responses do not require a new capability deadline", arguments: [false, true])
    func pendingSnapshotResponseClockBoundary(published: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let userUUID = UUID(), deviceUUID = UUID(), siblingUUID = UUID()
            let user = UserID(uuid: userUUID), device = DeviceID(uuid: deviceUUID), sibling = DeviceID(uuid: siblingUUID)
            for id in [deviceUUID, siblingUUID] {
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: userUUID), \(bind: id), \(bind: base), \(bind: base))").run()
            }
            let store = PostgresV2SyncStore(database: database, capabilityLifetime: 60)
            guard case .resetPreparing(let snapshotID, let generation, _) = try await store.pull(userID: user,
                deviceID: device, syncToken: nil, maxRecords: 20, requireSnapshot: true, now: base) else { throw CancellationError() }
            let builder = PostgresV2SnapshotArtifactBuilder(database: database)
            if published { while try await builder.runOnce(now: base).claimed { try Task.checkCancellation() } }
            func snapshot() async throws -> [String] {
                var rows: [String] = []
                for table in ["device_sync_cursors", "sync_snapshot_artifacts", "device_snapshot_resets", "sync_tokens", "sync_receipts", "user_projection_checkpoints"] {
                    guard let value = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                    rows.append(value.value)
                }
                return rows
            }
            let before = try await snapshot()
            let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
            #expect(v2PostgresTimestampCanEncode(upper))
            #expect(v2PostgresFutureTimestamp(now: upper, interval: 60) == nil)
            let expected: V2SyncPullResult = published
                ? .resetRequired(snapshotID: snapshotID, generation: generation, baseSequence: 0, expiresAt: base.addingTimeInterval(60))
                : .resetPreparing(snapshotID: snapshotID, generation: generation, retryAfter: 1)
            for requireSnapshot in [false, true] {
                for now in [upper, base, upper] {
                    #expect((try? await store.pull(userID: user, deviceID: device, syncToken: nil,
                        maxRecords: 20, requireSnapshot: requireSnapshot, now: now)) == expected)
                    #expect(try await snapshot() == before)
                }
                // A fresh device still needs a usable future deadline. Its
                // tentative cursor must roll back when issuance cannot proceed.
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                    try await store.pull(userID: user, deviceID: sibling, syncToken: nil,
                        maxRecords: 20, requireSnapshot: requireSnapshot, now: upper)
                }
                #expect(try await snapshot() == before)
            }
            for seconds in [Double.nan, .infinity, -.infinity, 1e14, -1e14] {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                    try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 20, now: .init(timeIntervalSince1970: seconds))
                }
                #expect(try await snapshot() == before)
            }
            while try await builder.runOnce(now: base).claimed { try Task.checkCancellation() }
            let manifest = try await store.fetchSnapshotManifest(userID: user, deviceID: device,
                snapshotID: snapshotID, generation: generation, now: base)
            try await store.acknowledgeSnapshot(userID: user, deviceID: device, snapshotID: snapshotID,
                generation: generation, baseSequence: manifest.baseSequence, receipt: manifest.receipt, now: base)
            guard case .ready(let resumed, let records, _, _, _) = try await store.pull(userID: user, deviceID: device,
                syncToken: manifest.nextSyncToken, maxRecords: 20, now: base) else { throw CancellationError() }
            #expect(resumed == generation && records.isEmpty)
        }
    }

    @Test("Shared snapshot lifetime does not extend an earlier device's reset response")
    func snapshotResponseUsesDeviceDeadline() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let userUUID = UUID(), firstUUID = UUID(), secondUUID = UUID()
            let user = UserID(uuid: userUUID), first = DeviceID(uuid: firstUUID), second = DeviceID(uuid: secondUUID)
            for device in [firstUUID, secondUUID] {
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: userUUID), \(bind: device), \(bind: base), \(bind: base))").run()
            }
            let store = PostgresV2SyncStore(database: database, capabilityLifetime: 60)
            guard case .resetPreparing(let snapshotID, let generation, _) = try await store.pull(userID: user, deviceID: first,
                syncToken: nil, maxRecords: 20, requireSnapshot: true, now: base) else { throw CancellationError() }
            #expect(generation == 2)
            let builder = PostgresV2SnapshotArtifactBuilder(database: database)
            while try await builder.runOnce(now: base).claimed { try Task.checkCancellation() }
            let firstManifest = try await store.fetchSnapshotManifest(userID: user, deviceID: first, snapshotID: snapshotID, generation: generation, now: base)
            #expect(firstManifest.expiresAt == base.addingTimeInterval(60))
            guard case .resetPreparing(let reused, let secondGeneration, _) = try await store.pull(userID: user, deviceID: second,
                syncToken: nil, maxRecords: 20, requireSnapshot: true, now: base.addingTimeInterval(30)) else { throw CancellationError() }
            #expect(reused == snapshotID && secondGeneration == generation)
            #expect(try await count("im_v2.sync_snapshot_artifacts", on: sql) == 1)
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["device_sync_cursors", "sync_snapshot_artifacts", "device_snapshot_resets", "sync_tokens", "sync_receipts", "user_projection_checkpoints"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    values.append(try #require(row).value)
                }
                return values
            }
            let before = try await snapshot()
            for (device, deadline) in [(first, base.addingTimeInterval(60)), (second, base.addingTimeInterval(90))] {
                for observed in [base.addingTimeInterval(30), deadline.addingTimeInterval(-1)] {
                    #expect(try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 20, now: observed)
                        == .resetRequired(snapshotID: snapshotID, generation: generation, baseSequence: 0, expiresAt: deadline))
                    #expect(try await store.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshotID, generation: generation, now: observed).expiresAt == deadline)
                }
                for observed in [deadline, deadline.addingTimeInterval(1)] {
                    // Pull continues to identify the pending snapshot with its
                    // actual deadline; it must not advertise another device's lease.
                    #expect(try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 20, now: observed)
                        == .resetRequired(snapshotID: snapshotID, generation: generation, baseSequence: 0, expiresAt: deadline))
                    await #expect(throws: V2SyncStoreError.snapshotExpiredOrInvalid) {
                        try await store.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshotID, generation: generation, now: observed)
                    }
                }
                #expect(try await snapshot() == before)
            }
            #expect(try await store.fetchSnapshotManifest(userID: user, deviceID: second, snapshotID: snapshotID, generation: generation,
                now: base.addingTimeInterval(60)).expiresAt == base.addingTimeInterval(90))
            // Boundary observations above made no writes. Complete both valid
            // assignments with a clock inside their original lifetimes.
            for device in [first, second] {
                let manifest = try await store.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshotID, generation: generation, now: base.addingTimeInterval(31))
                try await store.acknowledgeSnapshot(userID: user, deviceID: device, snapshotID: snapshotID, generation: generation,
                    baseSequence: manifest.baseSequence, receipt: manifest.receipt, now: base.addingTimeInterval(31))
                guard case .ready(let resumed, let records, _, _, _) = try await store.pull(userID: user, deviceID: device,
                    syncToken: manifest.nextSyncToken, maxRecords: 20, now: base.addingTimeInterval(31)) else { throw CancellationError() }
                #expect(resumed == generation && records.isEmpty)
            }
            #expect(try await count("im_v2.device_sync_cursors WHERE state = 'ready' AND reset_generation = 2", on: sql) == 2)
        }
    }

    @Test("Snapshot response expiry validates the effective artifact and device deadline")
    func snapshotResponseTimestampBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000), expiry = Date(timeIntervalSince1970: 1_750_000_060)
            let userUUID = UUID(), deviceUUID = UUID()
            let user = UserID(uuid: userUUID), device = DeviceID(uuid: deviceUUID)
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: base), \(bind: base))").run()
            let store = PostgresV2SyncStore(database: database, capabilityLifetime: 60)
            guard case .resetPreparing(let snapshotID, let generation, _) = try await store.pull(userID: user, deviceID: device,
                syncToken: nil, maxRecords: 20, requireSnapshot: true, now: base) else { throw CancellationError() }
            let builder = PostgresV2SnapshotArtifactBuilder(database: database)
            while try await builder.runOnce(now: base).claimed { try Task.checkCancellation() }
            let initialManifest = try await store.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshotID, generation: generation, now: base)
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["device_sync_cursors", "sync_snapshot_artifacts", "device_snapshot_resets", "sync_tokens", "sync_receipts", "user_projection_checkpoints"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    values.append(try #require(row).value)
                }
                return values
            }
            let initial = try await snapshot()
            let tables = ["sync_snapshot_artifacts", "device_snapshot_resets"]
            for affected in [[tables[0]], [tables[1]], tables] {
                for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                    for table in tables { try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET expires_at = \(bind: expiry)").run() }
                    for table in affected { try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET expires_at = \(bind: literal)::timestamptz").run() }
                    let before = try await snapshot()
                    if literal == "-infinity" || affected.count == 2 {
                        await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                            try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 20, now: base)
                        }
                        if literal == "-infinity" {
                            await #expect(throws: V2SyncStoreError.snapshotExpiredOrInvalid) {
                                try await store.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshotID, generation: generation, now: base)
                            }
                        } else {
                            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                                try await store.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshotID, generation: generation, now: base)
                            }
                        }
                    } else {
                        // The remaining finite lease still bounds both responses.
                        #expect(try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 20, now: base)
                            == .resetRequired(snapshotID: snapshotID, generation: generation, baseSequence: 0, expiresAt: expiry))
                        #expect(try await store.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshotID, generation: generation, now: base) == initialManifest)
                    }
                    #expect(try await snapshot() == before)
                }
            }
            for date in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10), expiry] {
                for table in tables { try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET expires_at = \(bind: date)").run() }
                let before = try await snapshot()
                #expect(try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 20, now: base)
                    == .resetRequired(snapshotID: snapshotID, generation: generation, baseSequence: 0, expiresAt: date))
                if date > base {
                    #expect(try await store.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshotID, generation: generation, now: base).expiresAt == date)
                } else {
                    await #expect(throws: V2SyncStoreError.snapshotExpiredOrInvalid) {
                        try await store.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshotID, generation: generation, now: base)
                    }
                }
                #expect(try await snapshot() == before)
            }
            #expect(try await snapshot() == initial)
        }
    }

    @Test("Receipt replay rejects invalid stored times without failing sibling commands",
          arguments: ["direct", "group", "group-owner", "mixed-batch", "group-batch", "owner-batch"])
    func receiptReplayStoredTimestampBounds(path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let store = PostgresV2ReadReceiptStore(database: database)
            let targetRoom: RoomID
            if path == "direct" || path == "mixed-batch" {
                let room = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: forwardImportTestProfile(),
                    roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { base }).openedIdentity(
                    actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                targetRoom = room.roomID
            } else { targetRoom = roomID }
            let targetUUID = try #require(UUID(uuidString: targetRoom.rawValue))
            try await sql.raw("UPDATE im_v2.rooms SET room_sequence = 2 WHERE room_id = \(bind: targetUUID)").run()
            let command = try V2RecordReadReceiptCommand(roomID: targetRoom, actorUserID: senderID,
                operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
            let operation = try #require(UUID(uuidString: command.operationID.rawValue))
            let route = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
            func batch(_ requests: [V2ReadReceiptRecordRequest]) async throws -> [V2ReadReceiptRecordResult] {
                let result: [V2GroupReadReceiptBatchResult]
                if path == "owner-batch" || path == "group-owner" {
                    result = try await store.recordGroupsOwnerValidated(requests.map { .init(request: $0, ownerRoute: route) })
                } else if path == "group-batch" {
                    result = try await store.recordGroups(requests)
                } else { return try await store.recordBatch(requests) }
                return try result.map {
                    switch $0 {
                    case .success(.handled(let outcome)): return .success(outcome)
                    case .failure(let error): return .failure(error)
                    case .success(.notGroup): throw CancellationError()
                    }
                }
            }
            func invoke(_ input: V2RecordReadReceiptCommand) async throws -> V2ReadReceiptOutcome {
                if path.hasSuffix("batch") {
                    let results = try await batch([.init(command: input, now: base)])
                    #expect(results.count == 1)
                    switch try #require(results.first) {
                    case .success(let outcome): return outcome
                    case .failure(let error): throw error
                    }
                }
                if path == "group" || path == "group-owner" {
                    let result = path == "group" ? try await store.recordGroup(command: input, now: base)
                        : try await store.recordGroupOwnerValidated(command: input, ownerRoute: route, now: base)
                    guard case .handled(let outcome) = result else { throw CancellationError() }
                    return outcome
                }
                return try await store.record(command: input, now: base)
            }
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["rooms", "room_memberships", "read_receipt_operations", "room_read_receipts", "user_sync_sequences", "user_sync_log",
                    "room_events", "read_receipt_preference_propagation_outbox"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    values.append(try #require(row).value)
                }
                return values
            }
            let saved = try V2ReadReceipt(roomID: targetRoom, userID: senderID, readThroughRoomSequence: 1, recordedAt: base)
            #expect(try await invoke(command) == .recorded(saved))
            #expect(try await invoke(command) == .idempotent(saved))
            let conflict = try V2RecordReadReceiptCommand(roomID: targetRoom, actorUserID: senderID,
                operationID: command.operationID, readThroughRoomSequence: 2)
            for (index, literal) in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"].enumerated() {
                try await sql.raw("UPDATE im_v2.read_receipt_operations SET recorded_at = \(bind: literal)::timestamptz WHERE user_id = \(bind: senderUUID) AND operation_id = \(bind: operation)").run()
                let before = try await snapshot()
                await #expect(throws: V2ReadReceiptStoreError.corruptPersistenceState) { try await invoke(command) }
                #expect(try await invoke(conflict) == .idempotencyConflict)
                #expect(try await snapshot() == before)
                let sibling = try V2RecordReadReceiptCommand(roomID: targetRoom, actorUserID: .init(uuid: memberTwoUUID),
                    operationID: .init(uuid: UUID()), readThroughRoomSequence: 2)
                let siblingReceipt = try V2ReadReceipt(roomID: targetRoom, userID: sibling.actorUserID, readThroughRoomSequence: 2, recordedAt: base)
                let bad = V2ReadReceiptRecordRequest(command: command, now: base)
                let good = V2ReadReceiptRecordRequest(command: sibling, now: base)
                let ordered = index.isMultiple(of: 2) ? [bad, good] : [good, bad]
                let expected: [V2ReadReceiptRecordResult] = index.isMultiple(of: 2)
                    ? [.failure(.corruptPersistenceState), .success(.recorded(siblingReceipt))]
                    : [.success(.recorded(siblingReceipt)), .failure(.corruptPersistenceState)]
                #expect(try await batch(ordered) == expected)
                #expect(try await count("im_v2.read_receipt_operations", on: sql) == Int64(index + 2))
                #expect(try await sql.raw("SELECT read_through_room_sequence AS value FROM im_v2.room_read_receipts WHERE room_id = \(bind: targetUUID) AND user_id = \(bind: senderUUID)").first(decoding: CountRow.self)?.value == 1)
                // Retrying the valid sibling must observe the already committed
                // result even though the adjacent replay returned an error.
                #expect(try await invoke(sibling) == .idempotent(siblingReceipt))
                let after = try await snapshot()
                await #expect(throws: V2ReadReceiptStoreError.corruptPersistenceState) { try await invoke(command) }
                #expect(try await snapshot() == after)
            }
            for date in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10), base] {
                try await sql.raw("UPDATE im_v2.read_receipt_operations SET recorded_at = \(bind: date) WHERE user_id = \(bind: senderUUID) AND operation_id = \(bind: operation)").run()
                let before = try await snapshot()
                let expected = try V2ReadReceipt(roomID: targetRoom, userID: senderID, readThroughRoomSequence: 1, recordedAt: date)
                #expect(try await invoke(command) == .idempotent(expected))
                #expect(try await snapshot() == before)
            }
        }
    }

    @Test("Moderation replay validates saved time without recomputing audit retention",
          arguments: ["redact", "mute", "remove", "freeze", "unfreeze"])
    func moderationReplayTimestampBounds(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let store = PostgresV2ModerationStore(database: database)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { base })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "Moderation timestamp fixture")) else { throw CancellationError() }
            if kind == "unfreeze" {
                try await sql.raw("UPDATE im_v2.rooms SET frozen_at = \(bind: base), frozen_by_user_id = \(bind: senderUUID) WHERE room_id = \(bind: roomUUID)").run()
            }
            if kind == "mute" || kind == "remove" {
                try await verifyMemberClockFixture(database:database,sql:sql,profile:profile,kind:kind)
                return
            }
            if kind == "redact" {
                let store = PostgresV2MessageModerationOperationStore(database: database, clock: { base })
                try await withRoomActivation(database: database, roomID: roomID) { token in
                    let baseline = try await store.baseline(.init(roomID: roomID, actorUserID: senderID, messageID: message.messageID), token: token)
                    func intent(_ operation: UUID, reason: String = "abuse_spam") throws -> V2MessageModerationIntent {
                        try .init(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: operation), messageID: message.messageID,
                            reasonCode: .init(reason), expectedMessageRevision: baseline.messageRevision,
                            expectedMembershipRevision: baseline.membershipRevision, confirmedUntilMilliseconds: 1_750_000_120_000)
                    }
                    let original = try intent(UUID())
                    guard case .admitted(let gate) = try await store.admit(original, token: token) else { throw CancellationError() }
                    let command = try V2MessageModerationCommand(intent: original, admission: gate)
                    guard case .receipt(let receipt) = try await store.submit(command, token: token, capacityProfile: profile, eventID: .init(uuid: UUID())),
                          case .redacted(_, _, let sequence, let event) = receipt.outcome else { throw CancellationError() }
                    #expect(receipt.validates(intent: original) && sequence == 2 && receipt.resolvedAtMilliseconds == 1_750_000_000_000)
                    let eventTime = try #require(try await sql.raw("SELECT created_at AS value FROM im_v2.room_events WHERE event_id=\(bind:event.uuidValue!)").first(decoding: RevocationClockDateRow.self)).value
                    let auditTime = try #require(try await sql.raw("SELECT occurred_at AS value FROM im_v2.moderation_audit_entries WHERE actor_user_id=\(bind:senderUUID) AND operation_id=\(bind:original.operationID.uuidValue!)").first(decoding: RevocationClockDateRow.self)).value
                    #expect(eventTime == base && auditTime == eventTime)
                    func snapshot() async throws -> [String] {
                        var rows: [String] = []
                        for table in ["message_moderation_receipts", "message_moderation_admissions", "messages", "moderation_audit_entries", "room_events", "room_admission", "shard_admission_pools"] {
                            let value = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw:table) r").first(decoding: StringValueRow.self)
                            rows.append(try #require(value).value)
                        }
                        return rows
                    }
                    let saved = try await snapshot()
                    let changed = try intent(original.operationID.uuidValue!, reason: "other_reason")
                    for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12, 946_684_800 + 9_223_371_331_200 - 10] {
                        let invalidClock = PostgresV2MessageModerationOperationStore(database: database, clock: { Date(timeIntervalSince1970: seconds) })
                        #expect(try await invalidClock.submit(command, token: token, capacityProfile: profile, eventID: .init(uuid: UUID())) == .receipt(receipt))
                        #expect(try await invalidClock.recover(.init(intent: changed, action: .query), token: token) == .fingerprintConflict)
                        let fresh = try V2MessageModerationIntent(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()),
                            messageID: message.messageID, reasonCode: .init("abuse_spam"), expectedMessageRevision: baseline.messageRevision + 1,
                            expectedMembershipRevision: baseline.membershipRevision, confirmedUntilMilliseconds: 1_750_000_120_000)
                        if seconds.isFinite && seconds > 0 && seconds <= Double(Int64.max) / 1_000 {
                            #expect(try await invalidClock.admit(fresh, token: token) == .currentUnavailable(.confirmationExpired))
                        } else {
                            await #expect(throws: (any Error).self) { try await invalidClock.admit(fresh, token: token) }
                        }
                        #expect(try await snapshot() == saved)
                    }
                    // Permanent proofs reject corruption rather than exposing a
                    // mutable historical timestamp through the retired ledger.
                    await #expect(throws: (any Error).self) {
                        try await sql.raw("UPDATE im_v2.message_moderation_receipts SET receipt=jsonb_set(receipt,'{resolvedAtMilliseconds}','0') WHERE actor_user_id=\(bind:senderUUID) AND operation_id=\(bind:original.operationID.uuidValue!)").run()
                    }
                    #expect(try await store.recover(.init(intent: original, action: .query), token: token) == .receipt(receipt))
                    #expect(try await snapshot() == saved)
                }
                return
            }
            let operation = UUID()
            let action: V2ModerationAction = switch kind {
            case "redact": .redactMessage
            case "mute": .muteMember
            case "remove": .removeMember
            case "freeze": .freezeRoom
            default: .unfreezeRoom
            }
            func invoke(_ id: UUID, at now: Date, ownerValidated: Bool = false, conflict: Bool = false) async throws -> V2ModerationOutcome {
                let command = try V2ModerationCommand(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: id), action: action,
                    targetUserID: kind == "mute" || kind == "remove" ? .init(uuid: memberTwoUUID) : nil,
                    messageID: kind == "redact" ? message.messageID : nil, muteUntil: kind == "mute" ? base.addingTimeInterval(60) : nil,
                    reasonCode: .init(conflict ? "other_reason" : "abuse_spam"))
                let event = EventID(uuid: UUID())
                let route = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
                if ownerValidated {
                    return try await store.applyTrustedSafetyOwnerValidated(command: command, ownerRoute: route, capacityProfile: profile, eventID: event, now: now)
                }
                return try await store.applyTrustedSafety(command: command, capacityProfile: profile, eventID: event, now: now)
            }

            func snapshot() async throws -> [String] {
                var result: [String] = []
                for table in ["rooms", "room_memberships", "room_member_mutes", "messages", "message_media_references", "moderation_operations",
                    "moderation_audit_entries", "room_events", "room_admission", "shard_admission_pools"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    result.append(try #require(row).value)
                }
                return result
            }
            guard case .applied(let accepted) = try await invoke(operation, at: base) else { throw CancellationError() }
            #expect(accepted.createdAt == base && accepted.roomSequence == 2 && accepted.action == action)
            let initial = try await snapshot()
            // The last clock is itself representable, but adding the required
            // audit retention would exceed PostgreSQL's finite timestamp range.
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                            1e14, -1e14, -1e12, 946_684_800 + 9_223_371_331_200 - 10] {
                let invalid = Date(timeIntervalSince1970: seconds)
                for ownerValidated in [false, true] {
                    #expect(try await invoke(operation, at: invalid, ownerValidated: ownerValidated) == .idempotent(accepted))
                    #expect(try await invoke(operation, at: invalid, ownerValidated: ownerValidated, conflict: true) == .idempotencyConflict)
                    await #expect(throws: V2ModerationStoreError.corruptPersistenceState) { try await invoke(UUID(), at: invalid, ownerValidated: ownerValidated) }
                    #expect(try await snapshot() == initial)
                }
            }
            for column in kind == "mute" ? ["created_at", "mute_until"] : ["created_at"] {
                for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                    try await sql.raw("UPDATE im_v2.moderation_operations SET \(unsafeRaw: column) = \(bind: literal)::timestamptz WHERE operation_id = \(bind: operation)").run()
                    let before = try await snapshot()
                    for ownerValidated in [false, true] {
                        await #expect(throws: V2ModerationStoreError.corruptPersistenceState) { try await invoke(operation, at: base, ownerValidated: ownerValidated) }
                        #expect(try await invoke(operation, at: base, ownerValidated: ownerValidated, conflict: true) == .idempotencyConflict)
                    }
                    #expect(try await snapshot() == before)
                }
                let restored = column == "mute_until" ? base.addingTimeInterval(60) : base
                try await sql.raw("UPDATE im_v2.moderation_operations SET \(unsafeRaw: column) = \(bind: restored) WHERE operation_id = \(bind: operation)").run()
            }
            for date in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10), base] {
                try await sql.raw("UPDATE im_v2.moderation_operations SET created_at = \(bind: date) WHERE operation_id = \(bind: operation)").run()
                let before = try await snapshot()
                let expected = try V2ModerationResult(roomID: accepted.roomID, operationID: accepted.operationID, action: accepted.action,
                    targetUserID: accepted.targetUserID, messageID: accepted.messageID, messageRevision: accepted.messageRevision,
                    membershipRevision: accepted.membershipRevision, muteUntil: accepted.muteUntil, roomSequence: accepted.roomSequence,
                    eventID: accepted.eventID, createdAt: date)
                for ownerValidated in [false, true] {
                    #expect(try await invoke(operation, at: base, ownerValidated: ownerValidated) == .idempotent(expected))
                }
                #expect(try await snapshot() == before)
            }
            #expect(try await snapshot() == initial)
        }
    }

    @Test("Member mute milliseconds and immutable proof preserve canonical replay")
    func moderationMuteReplayPrecision() async throws {
        try await withForwardOwnerDatabases(mode:.standard) { database,_,sql,_,_ in
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
            try await verifyMemberClockFixture(database:database,sql:sql,profile:forwardImportTestProfile(),kind:"mute")
        }
    }

}

private struct MutationPrecisionTimestamp:Decodable { let createdAt:Date;enum CodingKeys:String,CodingKey {case createdAt="created_at"} }
