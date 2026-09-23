import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("message mutations fence before replay and preserve successor operations",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"),
          arguments: ["edit", "withdraw", "reaction"])
    func activationMessageMutation(_ kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let request = try activationWriteRequest(text: "before", now: now)
            let seed = try await PostgresV2RoomWriteStore(database: database).accept(command: request.command,
                capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: now)
            guard case .accepted(let message) = seed else { Issue.record("seed"); return }
            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let host = V2ActorHostIdentity(hostID: try .init("mutation-host"), incarnationID: UUID())
            guard case .acquired(let first) = try await leases.acquire(roomID: roomID,
                owner: owner, host: host, duration: .init(30_000)) else { Issue.record("lease"); return }
            let operation = UUID(), event = EventID(uuid: UUID())
            let execute: @Sendable (V2RoomActivationWriteScope) async throws -> Void = { scope in
                let executor = try V2RoomMessagingExecutor(token: scope.token(for: roomUUID),
                    writes: .init(database: database),
                    edits: .init(database: database, contentReviewMode: .disabled),
                    withdrawals: .init(database: database), reactions: .init(database: database),
                    capacityProfile: request.capacityProfile, limits: .init(maxUTF8Bytes: 64),
                    maximumEditBytes: 64, editIdentifiers: .init(makeUUID: { event.uuidValue! }),
                    withdrawalIdentifiers: .init(makeUUID: { event.uuidValue! }),
                    reactionIdentifiers: .init(makeUUID: { event.uuidValue! }), now: { now })
                let result: V2RoomMessagingResult
                switch kind {
                case "edit":
                    result = try await executor.execute(.edit(.init(roomID: roomID, actorUserID: senderID,
                            operationID: .init(uuid: operation), messageID: message.messageID,
                            expectedMessageRevision: 1, text: "after")))
                case "withdraw":
                    result = try await executor.execute(.withdraw(.init(roomID: roomID, actorUserID: senderID,
                            operationID: .init(uuid: operation), messageID: message.messageID,
                            expectedMessageRevision: 1)))
                default:
                    result = try await executor.execute(.reaction(.init(roomID: roomID, actorUserID: senderID,
                            operationID: .init(uuid: operation), messageID: message.messageID,
                            reaction: "👍", action: .add)))
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
            let table = kind == "edit" ? "message_edit_operations"
                : kind == "withdraw" ? "message_withdrawal_operations" : "message_reaction_operations"
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
            let old = base.usingActivationScope(try .init(tokens: [first.token]))
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
            let successor = base.usingActivationScope(try .init(tokens: [next.token]))
            let replay = try await successor.accept(command: request.command, capacityProfile: request.capacityProfile,
                identifiers: request.identifiers, now: now)
            guard case .idempotent(let recovered) = replay else { Issue.record("replay not recovered"); return }
            #expect(recovered.messageID == original.messageID)
            #expect(try await count("im_v2.messages", on: sql) == 1)
            #expect(try await leases.release(token: next.token))
        }
    }

    @Test("room credits are bound to activation and unknown credits are never refunded",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func activationRoomCreditIsolation() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let host = V2ActorHostIdentity(hostID: try .init("credits-host"), incarnationID: UUID())
            guard case .acquired(let first) = try await leases.acquire(roomID: roomID,
                owner: owner, host: host, duration: .init(30_000)) else { Issue.record("lease"); return }
            let state = try ShardAdmissionState(lease: .init(id: .init(uuid: leaseUUID), generation: 1,
                validUntil: now.addingTimeInterval(100), commandWindow: .init(limit: 10, used: 0)))
            let pool = V2RoomAdmissionCommandCreditPool(database: database, batchSize: 4)
            guard case .granted(let firstCredit) = try await pool.acquire(roomID: roomUUID,
                shardState: state, now: now, activation: first.token) else { Issue.record("first credit"); return }
            #expect(try await leases.release(token: first.token))
            guard case .acquired(let next) = try await leases.acquire(roomID: roomID,
                owner: owner, host: host, duration: .init(30_000)) else { Issue.record("successor"); return }
            guard case .granted(let nextCredit) = try await pool.acquire(roomID: roomUUID,
                shardState: state, now: now, activation: next.token) else { Issue.record("next credit"); return }
            #expect(await pool.snapshot().databaseCreditsReserved == 8)
            await pool.discard(firstCredit)
            await pool.release(firstCredit, now: now)
            await pool.retire(activation: first.token)
            await pool.release(nextCredit, now: now)
            await pool.release(nextCredit, now: now)
            let snapshot = await pool.snapshot()
            #expect(snapshot.activeCredits == 4)
            #expect(snapshot.inFlightCredits == 0)
            #expect(snapshot.returnedCredits == 1)
            #expect(snapshot.expiredCreditsDiscarded == 4)
            struct Used: Decodable { let used: Int }
            #expect(try await sql.raw("SELECT command_window_used AS used FROM im_v2.room_admission WHERE room_id = \(bind: roomUUID)")
                .first(decoding: Used.self)?.used == 8)
            await pool.retire(activation: next.token)
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
