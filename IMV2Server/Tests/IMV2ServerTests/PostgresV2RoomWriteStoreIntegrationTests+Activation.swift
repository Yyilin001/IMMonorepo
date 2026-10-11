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
    @Test("special account audit rejects old activation before replay or new audit writes",
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
            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let host = V2ActorHostIdentity(hostID: try .init("audit-host"), incarnationID: UUID())
            guard case .acquired(let first) = try await leases.acquire(roomID: roomID, owner: owner,
                host: host, duration: .init(30_000)) else { Issue.record("first lease"); return }
            let old = try V2RoomSpecialAccountAuditExecutor(token: first.token,
                store: .init(database: database), now: { now })
            #expect(try await old.execute(wire) == .recorded)
            #expect(try await leases.release(token: first.token))
            guard case .acquired(let next) = try await leases.acquire(roomID: roomID, owner: owner,
                host: host, duration: .init(30_000)) else { Issue.record("successor lease"); return }
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                try await old.execute(wire)
            }
            let current = try V2RoomSpecialAccountAuditExecutor(token: next.token,
                store: .init(database: database), now: { now })
            #expect(try await current.execute(wire) == .recorded)
            #expect(try await count("im_v2.special_account_message_operations", on: sql) == 1)
            #expect(try await count("im_v2.special_account_message_audit", on: sql) == 1)
            #expect(try await leases.release(token: next.token))
        }
    }

    @Test("message mutations fence before replay and preserve successor operations",
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
            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let host = V2ActorHostIdentity(hostID: try .init("mutation-host"), incarnationID: UUID())
            guard case .acquired(let first) = try await leases.acquire(roomID: roomID,
                owner: owner, host: host, duration: .init(30_000)) else { Issue.record("lease"); return }
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
            let firstScope = try V2RoomActivationWriteScope(tokens: [first.token])
            try await execute(firstScope)
            #expect(try await leases.release(token: first.token))
            guard case .acquired(let next) = try await leases.acquire(roomID: roomID,
                owner: owner, host: host, duration: .init(30_000)) else { Issue.record("successor"); return }
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) { try await execute(firstScope) }
            try await execute(.init(tokens: [next.token]))
            let table = kind == "reaction" ? "message_reaction_receipts" : "message_mutation_receipts"
            #expect(try await count("im_v2." + table, on: sql) == 1)
            #expect(try await leases.release(token: next.token))
        }
    }

    @Test("activation-fenced sender rejects old writes and replay after successor acquires",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func activationFencedSendAndReplay() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let host = V2ActorHostIdentity(hostID: try .init("sender-host"), incarnationID: UUID())
            guard case .acquired(let first) = try await leases.acquire(roomID: roomID,
                owner: owner, host: host, duration: .init(30_000)) else {
                Issue.record("initial activation unavailable"); return
            }
            let base = PostgresV2RoomWriteStore(database: database)
            let old = V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: base, shardID: "room-a", epoch: 0, activationToken: first.token)
            let request = try activationWriteRequest(text: "first", now: now)
            let accepted = try await old.accept(command: request.command, capacityProfile: request.capacityProfile,
                identifiers: request.identifiers, now: now)
            guard case .accepted(let original) = accepted else { Issue.record("send not accepted"); return }
            #expect(try await leases.release(token: first.token))
            guard case .acquired(let next) = try await leases.acquire(roomID: roomID,
                owner: owner, host: host, duration: .init(30_000)) else {
                Issue.record("successor unavailable"); return
            }
            let fresh = try activationWriteRequest(text: "stale", now: now)
            for input in [request, fresh] {
                await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                    try await old.accept(command: input.command, capacityProfile: input.capacityProfile,
                        identifiers: input.identifiers, now: now)
                }
            }
            let successor = V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: base, shardID: "room-a", epoch: 0, activationToken: next.token)
            let replay = try await successor.accept(command: request.command, capacityProfile: request.capacityProfile,
                identifiers: request.identifiers, now: now)
            guard case .idempotent(let recovered) = replay else { Issue.record("replay not recovered"); return }
            #expect(recovered.messageID == original.messageID)
            #expect(try await count("im_v2.messages", on: sql) == 1)
            #expect(try await leases.release(token: next.token))
        }
    }

    private func activationWriteRequest(text: String, now: Date) throws -> V2RoomWriteRequest {
        .init(command: try .init(roomID: roomID, senderUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: text, limits: .init(maxUTF8Bytes: 64)),
              capacityProfile: try forwardImportTestProfile(),
              identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())), now: now)
    }
}
