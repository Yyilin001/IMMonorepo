@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("special account audit rejects stale data owners before replay or new audit writes",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func activationSpecialAccountAudit() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let request = try activationWriteRequest(text: "notice", now: now)
            let outcome = try await V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0).accept(
                command: request.command, capacityProfile: request.capacityProfile,
                identifiers: request.identifiers, now: now)
            try await sql.raw("""
                INSERT INTO im_v2.special_accounts (account_user_id, stable_key, account_kind,
                    status, allows_customer_messages, allows_service_messages, created_at, updated_at)
                VALUES (\(bind: senderUUID), 'actor_notice', 'system', 'active', false, true,
                        \(bind: now), \(bind: now))
                """).run()
            let wire = try V2ActorSpecialAccountAuditWire(
                request: .init(stableAccountKey: "actor_notice", servicePrincipal: "test-service",
                    operationID: request.command.clientMessageID, requestFingerprint: "0123456789abcdef",
                    firstSubmissionDeadlineMilliseconds: UInt64(now.timeIntervalSince1970 * 1000) + 600_000,
                    customerUserID: .init(uuid: memberTwoUUID), text: "notice"),
                account: .init(userID: senderID, stableKey: "actor_notice", kind: .system),
                roomID: roomID, outcome: outcome)
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let old = try V2RoomSpecialAccountAuditExecutor(token: token,
                    store: .init(database: database), now: { now })
                #expect(try await old.execute(wire) == .recorded)
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: roomUUID)").run()
                await #expect(throws: V2RoomActorStateError.ownerChanged) {
                    try await old.execute(wire)
                }
            }
            try await withRoomActivation(database: database, roomID: roomID, epoch: 1) { token in
                let current = try V2RoomSpecialAccountAuditExecutor(token: token,
                    store: .init(database: database), now: { now })
                #expect(try await current.execute(wire) == .recorded)
                #expect(try await count("im_v2.special_account_message_operations", on: sql) == 1)
                #expect(try await count("im_v2.special_account_message_audit", on: sql) == 1)
            }
        }
    }

    @Test("message mutations check data ownership before replay and preserve successor operations",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"),
          arguments: ["edit", "withdraw", "reaction"])
    func activationMessageMutation(_ kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let request = try activationWriteRequest(text: "before", now: now)
            let seed = try await V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0).accept(command: request.command,
                capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: now)
            guard case .accepted(let message) = seed else { Issue.record("seed"); return }
            let operation = UUID()
            let execute: @Sendable (V2RoomActivationWriteScope) async throws -> Void = { scope in
                let executor = try V2RoomMessagingExecutor(token: scope.token(for: roomUUID),
                    capacityProfile: request.capacityProfile, limits: .init(maxUTF8Bytes: 64),
                    maximumEditBytes: 64, now: { now },
                    mutations:.init(database:database,contentReviewMode:.disabled,clock:{now}),reactionOperations:.init(database:database,clock:{now}))
                let result: V2RoomMessagingResult
                switch kind {
                case "edit":
                    result = try await executor.execute(.editOperation(.init(command:.init(roomID: roomID, actorUserID: senderID,
                            operationID: .init(uuid: operation), messageID: message.messageID,
                            expectedMessageRevision: 1, text: "after",maximumUTF8Bytes:64),firstSubmissionDeadlineMilliseconds:UInt64(now.timeIntervalSince1970*1000)+60_000)))
                case "withdraw":
                    result = try await executor.execute(.withdrawOperation(.init(command:.init(roomID: roomID, actorUserID: senderID,
                            operationID: .init(uuid: operation), messageID: message.messageID,
                            expectedMessageRevision: 1),firstSubmissionDeadlineMilliseconds:UInt64(now.timeIntervalSince1970*1000)+60_000)))
                default:
                    result = try await executor.execute(.reactionOperation(.init(command:.init(roomID: roomID, actorUserID: senderID,
                            operationID: .init(uuid: operation), messageID: message.messageID,
                            reaction: "👍", action: .add),expectedReactionRevision:0,firstSubmissionDeadlineMilliseconds:UInt64(now.timeIntervalSince1970*1000)+60_000)))
                }
                if case .failure(let failure) = result { Issue.record("unexpected domain failure: \(failure)") }
            }
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let oldScope = try V2RoomActivationWriteScope(tokens: [token])
                try await execute(oldScope)
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: roomUUID)").run()
                await #expect(throws: V2RoomActorStateError.ownerChanged) { try await execute(oldScope) }
            }
            try await withRoomActivation(database: database, roomID: roomID, epoch: 1) { token in
                try await execute(.init(tokens: [token]))
                let table = kind == "reaction" ? "message_reaction_receipts" : "message_mutation_receipts"
                #expect(try await count("im_v2." + table, on: sql) == 1)
            }
        }
    }

    @Test("native sender rejects stale data owners and recovers the durable result",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func activationFencedSendAndReplay() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let base = PostgresV2RoomWriteStore(database: database)
            let request = try activationWriteRequest(text: "first", now: now)
            let original = try await withRoomActivation(database: database, roomID: roomID) { token in
                let old = V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                    store: base, shardID: "room-a", epoch: 0, activationToken: token)
                let accepted = try await old.accept(command: request.command, capacityProfile: request.capacityProfile,
                    identifiers: request.identifiers, now: now)
                let original = try #require(accepted.acceptanceReceipt)
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: roomUUID)").run()
                let fresh = try activationWriteRequest(text: "stale", now: now)
                for input in [request, fresh] {
                    await #expect(throws: V2RoomActorStateError.ownerChanged) {
                        try await old.accept(command: input.command, capacityProfile: input.capacityProfile,
                            identifiers: input.identifiers, now: now)
                    }
                }
                return original
            }
            try await withRoomActivation(database: database, roomID: roomID, epoch: 1) { token in
                let successor = V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                    store: base, shardID: "room-a", epoch: 1, activationToken: token)
                let replay = try await successor.accept(command: request.command, capacityProfile: request.capacityProfile,
                    identifiers: request.identifiers, now: now)
                guard case .idempotent(let recovered) = replay else { Issue.record("replay not recovered"); return }
                #expect(recovered.messageID == original.messageID)
                #expect(try await count("im_v2.messages", on: sql) == 1)
            }
        }
    }

    private func activationWriteRequest(text: String, now: Date) throws -> V2RoomWriteRequest {
        .init(command: try .init(roomID: roomID, senderUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: text, limits: .init(maxUTF8Bytes: 64)),
              capacityProfile: try forwardImportTestProfile(),
              identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())), now: now)
    }
}
