import Foundation
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

@Suite("Global join quota ledger", .serialized)
struct PostgresV2GroupJoinQuotaTests {
    @Test("different rooms and invites share one atomic applicant limit")
    func concurrentReservations() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let store = try PostgresV2GroupJoinQuotaStore(database: database, schema: schema)
            let applicant = UserID(uuid: UUID()), now = Date(timeIntervalSince1970: 1_750_000_000)
            let inputs = (0..<40).map { _ in candidate(applicant: applicant, limit: 20) }
            let outcomes = try await withThrowingTaskGroup(of: V2GroupJoinQuotaReservation.self) { group in
                for input in inputs {
                    group.addTask { try await store.reserve(input, roomID: .init(uuid: UUID()), inviteID: .init(uuid: UUID()), now: now) }
                }
                var values: [V2GroupJoinQuotaReservation] = []
                for try await value in group { values.append(value) }
                return values
            }
            #expect(outcomes.filter { if case .reserved = $0 { true } else { false } }.count == 20)
            #expect(outcomes.filter { $0 == .limited }.count == 20)
            #expect(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).group_join_quota_intents").first(decoding: QuotaTestCount.self)?.value == 20)
            // A failed caller/expired lease has no release API. Reopening the
            // store even a year later still counts every uncertain reservation.
            let reopened = try PostgresV2GroupJoinQuotaStore(database: database, schema: schema)
            #expect(try await reopened.reserve(candidate(applicant: applicant, limit: 20), roomID: .init(uuid: UUID()), inviteID: .init(uuid: UUID()), now: now.addingTimeInterval(31_536_000)) == .limited)
            guard case .reserved = try await reopened.reserve(candidate(applicant: .init(uuid: UUID()), limit: 1), roomID: .init(uuid: UUID()), inviteID: .init(uuid: UUID()), now: now) else { Issue.record("Other applicant must have its own capacity"); return }
        }
    }

    @Test("same active invite shares one reservation while operation bindings stay immutable")
    func retriesAndBindings() async throws {
        try await withUserEventDatabase { database, _, schema in
            let store = try PostgresV2GroupJoinQuotaStore(database: database, schema: schema)
            let applicant = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), invite = GroupInviteID(uuid: UUID()), now = Date(timeIntervalSince1970: 1_750_000_000)
            let first = candidate(applicant: applicant)
            let intent = try requireIntent(await store.reserve(first, roomID: room, inviteID: invite, now: now))
            let sameOperation = candidate(applicant: applicant, operation: first.operationID)
            #expect(try await store.reserve(sameOperation, roomID: room, inviteID: invite, now: now.addingTimeInterval(1)) == .reserved(intent))
            async let a = store.reserve(candidate(applicant: applicant), roomID: room, inviteID: invite, now: now)
            async let b = store.reserve(candidate(applicant: applicant), roomID: room, inviteID: invite, now: now)
            let (left, right) = try await (a, b)
            #expect(left == .reserved(intent) && right == left)
            for kind in ["room", "invite", "note", "digest"] {
                await #expect(throws: V2GroupInvitationServiceError.conflict) {
                    _ = try await store.reserve(candidate(applicant: applicant, operation: first.operationID,
                        note: kind == "note" ? "changed" : nil, digest: kind == "digest" ? 2 : 1),
                        roomID: kind == "room" ? .init(uuid: UUID()) : room,
                        inviteID: kind == "invite" ? .init(uuid: UUID()) : invite, now: now)
                }
            }
        }
    }

    @Test("terminal evidence frees the slot and late observations cannot resurrect it", arguments: [V2GroupJoinQuotaOutcome.approved, .rejected, .cancelled, .alreadyMember])
    func terminalRelease(_ outcome: V2GroupJoinQuotaOutcome) async throws {
        try await withUserEventDatabase { database, _, schema in
            let store = try PostgresV2GroupJoinQuotaStore(database: database, schema: schema)
            let applicant = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), invite = GroupInviteID(uuid: UUID()), now = Date(timeIntervalSince1970: 1_750_000_000)
            let request = candidate(applicant: applicant)
            let intent = try requireIntent(await store.reserve(request, roomID: room, inviteID: invite, now: now))
            let target: UUID? = outcome.requiresRequest ? intent.requestID : nil
            if outcome.requiresRequest {
                #expect(try await store.resolve(intent, outcome: .pending, targetRequestID: target, now: now))
                #expect(try await store.reserve(candidate(applicant: applicant), roomID: room, inviteID: .init(uuid: UUID()), now: now) == .limited)
                await #expect(throws: V2GroupInvitationServiceError.conflict) {
                    try await store.resolve(intent, outcome: outcome, targetRequestID: UUID(), now: now)
                }
            }
            #expect(try await store.resolve(intent, outcome: outcome, targetRequestID: target, now: now))
            #expect(try await store.resolve(intent, outcome: outcome, targetRequestID: target, now: now.addingTimeInterval(1)))
            #expect(try await !store.resolve(intent, outcome: .pending, targetRequestID: intent.requestID, now: now))
            let replay = try requireIntent(await store.reserve(request, roomID: room, inviteID: invite, now: now))
            #expect(replay.phase == .terminal && replay.outcome == outcome && replay.updatedAt == now)
            guard case .reserved = try await store.reserve(candidate(applicant: applicant), roomID: room, inviteID: .init(uuid: UUID()), now: now) else { Issue.record("Terminal receipt must release capacity"); return }
        }
    }

    @Test("temporary pressure preserves the original attempt while definite rejection seals it", arguments: [V2GroupJoinQuotaOutcome.unavailable, .rateLimited, .permissionDenied])
    func deniedAttemptRetry(_ outcome: V2GroupJoinQuotaOutcome) async throws {
        try await withUserEventDatabase { database, _, schema in
            let store = try PostgresV2GroupJoinQuotaStore(database: database, schema: schema)
            let applicant = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), invite = GroupInviteID(uuid: UUID()), now = Date(timeIntervalSince1970: 1_750_000_000)
            let request = candidate(applicant: applicant)
            let original = try requireIntent(await store.reserve(request, roomID: room, inviteID: invite, now: now))
            #expect(try await store.resolve(original, outcome: outcome, targetRequestID: nil, now: now))
            if outcome == .rateLimited {
                let retry = try requireIntent(await store.reserve(request, roomID: room, inviteID: invite, now: now.addingTimeInterval(2)))
                #expect(retry.generation == original.generation && retry.requestID == original.requestID && retry.phase == .held)
                #expect(retry.createdAt == original.createdAt && retry.attemptCreatedAt == original.attemptCreatedAt && retry.outcome == nil)
                #expect(retry.nextCheckAt == now.addingTimeInterval(30))
                #expect(try await store.reserve(candidate(applicant: applicant), roomID: room, inviteID: .init(uuid: UUID()), now: now) == .limited)
                #expect(try await store.resolve(retry, outcome: .pending, targetRequestID: retry.requestID, now: now))
                #expect(try await !store.resolve(original, outcome: .rateLimited, targetRequestID: nil, now: now))
            } else {
                #expect(try await store.reserve(request, roomID: room, inviteID: invite, now: now.addingTimeInterval(2)) == .limited)
                #expect(try await store.resolve(original, outcome: outcome, targetRequestID: nil, now: now.addingTimeInterval(3)))
                // A new user confirmation gets a new identity, never a new generation of the denied operation.
                let fresh = try requireIntent(await store.reserve(candidate(applicant: applicant), roomID: room, inviteID: invite, now: now))
                #expect(fresh.operationID != original.operationID && fresh.requestID != original.requestID && fresh.generation == 1)
                #expect(try await store.reserve(request, roomID: room, inviteID: invite, now: now) == .limited)
                #expect(try await store.resolve(fresh, outcome: .pending, targetRequestID: fresh.requestID, now: now))
            }
        }
    }

    @Test("ledger schema rejects missing fences and weakened outcome checks", arguments: ["outcome", "generation", "unique", "recovery"])
    func schemaFences(_ scenario: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            if scenario == "outcome" || scenario == "generation" {
                let name = scenario == "outcome" ? "group_join_quota_outcome_check" : "group_join_quota_intents_generation_check"
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).group_join_quota_intents DROP CONSTRAINT \(unsafeRaw: name)").run()
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).group_join_quota_intents ADD CONSTRAINT \(unsafeRaw: name) CHECK (true)").run()
            } else {
                let name = scenario == "unique" ? "group_join_quota_active_invite_idx" : "group_join_quota_recovery_idx"
                try await sql.raw("DROP INDEX \(unsafeRaw: schema).\(unsafeRaw: name)").run()
            }
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".group_join_quota_intents[reservation-contract]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    @Test("sealed identities never increment an exhausted generation or borrow another slot")
    func generationLimit() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let store = try PostgresV2GroupJoinQuotaStore(database: database, schema: schema)
            let applicant = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), invite = GroupInviteID(uuid: UUID()), now = Date(timeIntervalSince1970: 1_750_000_000)
            let request = candidate(applicant: applicant)
            let intent = try requireIntent(await store.reserve(request, roomID: room, inviteID: invite, now: now))
            try await store.resolve(intent, outcome: .unavailable, targetRequestID: nil, now: now)
            try await sql.raw("UPDATE \(unsafeRaw: schema).group_join_quota_intents SET generation = \(bind: Int64.max)").run()
            #expect(try await store.reserve(request, roomID: room, inviteID: invite, now: now) == .limited)
            #expect(try await sql.raw("SELECT generation AS value FROM \(unsafeRaw: schema).group_join_quota_intents WHERE operation_id = \(bind: intent.operationID)").first(decoding: QuotaGeneration.self)?.value == Int64.max)
            let fresh = try requireIntent(await store.reserve(candidate(applicant: applicant), roomID: room, inviteID: invite, now: now))
            #expect(fresh.generation == 1 && fresh.operationID != intent.operationID)
        }
    }

    @Test("expired leases can be reclaimed without releasing reservations or accepting old deferrals")
    func recoveryLeases() async throws {
        try await withUserEventDatabase { database, _, schema in
            let store = try PostgresV2GroupJoinQuotaStore(database: database, schema: schema)
            let applicant = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), invite = GroupInviteID(uuid: UUID()), now = Date(timeIntervalSince1970: 1_750_000_000)
            let intent = try requireIntent(await store.reserve(candidate(applicant: applicant), roomID: room, inviteID: invite, now: now))
            async let a = store.claim(limit: 1, now: now, lease: 1)
            async let b = store.claim(limit: 1, now: now, lease: 1)
            let (first, competing) = try await (a, b)
            let old = try #require((first + competing).first)
            #expect(first.count + competing.count == 1)
            #expect(try await store.claim(limit: 1, now: now.addingTimeInterval(0.5)).isEmpty)
            let reclaimed = try #require(try await store.claim(limit: 1, now: now.addingTimeInterval(2)).first)
            #expect(reclaimed.generation == intent.generation && reclaimed.leaseToken != old.leaseToken)
            try await store.deferClaim(old, now: now.addingTimeInterval(3))
            #expect(try await store.claim(limit: 1, now: now.addingTimeInterval(4)).isEmpty)
            #expect(try await store.reserve(candidate(applicant: applicant), roomID: room, inviteID: .init(uuid: UUID()), now: now) == .limited)
            try await store.resolve(reclaimed, outcome: .pending, targetRequestID: intent.requestID, now: now.addingTimeInterval(5))
            #expect(try await store.claim(limit: 1, now: now.addingTimeInterval(34)).isEmpty)
            let poll = try #require(try await store.claim(limit: 1, now: now.addingTimeInterval(35)).first)
            try await store.resolve(poll, outcome: .cancelled, targetRequestID: intent.requestID, now: now.addingTimeInterval(35))
            #expect(try await store.claim(limit: 1, now: now.addingTimeInterval(100)).isEmpty)
        }
    }

    @Test("owner receipt readiness rejects missing bindings and weakened result shapes", arguments: ["result", "target", "generation"])
    func receiptSchemaFences(_ scenario: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            let name = scenario == "result" ? "group_join_submission_receipt_result_check" : scenario == "target" ? "group_join_receipt_target_fkey" : "group_join_submission_receipts_generation_check"
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).group_join_submission_receipts DROP CONSTRAINT \(unsafeRaw: name)").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".group_join_submission_receipts[admission-receipt]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    @Test("duplicate operation bindings survive cancellation and reject changed payloads")
    func duplicateOperationTerminalReplay() async throws {
        try await withUserEventDatabase { database, _, schema in
            let store = try PostgresV2GroupJoinQuotaStore(database: database, schema: schema)
            let applicant = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), invite = GroupInviteID(uuid: UUID())
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let original = candidate(applicant: applicant)
            let duplicate = candidate(applicant: applicant, note: "second submission")
            let intent = try requireIntent(await store.reserve(original, roomID: room, inviteID: invite, now: now))
            #expect(try await store.reserve(duplicate, roomID: room, inviteID: invite, now: now) == .reserved(intent))
            try await store.resolve(intent, outcome: .cancelled, targetRequestID: intent.requestID, now: now)
            let replay = try requireIntent(await store.reserve(duplicate, roomID: room, inviteID: invite, now: now))
            #expect(replay.operationID == intent.operationID && replay.outcome == .cancelled)
            for kind in ["room", "invite", "note", "digest"] {
                await #expect(throws: V2GroupInvitationServiceError.conflict) {
                    _ = try await store.reserve(candidate(applicant: applicant, operation: duplicate.operationID,
                        note: kind == "note" ? "changed" : duplicate.note, digest: kind == "digest" ? 2 : 1),
                        roomID: kind == "room" ? .init(uuid: UUID()) : room,
                        inviteID: kind == "invite" ? .init(uuid: UUID()) : invite, now: now)
                }
            }
            let fresh = try requireIntent(await store.reserve(candidate(applicant: applicant), roomID: room, inviteID: invite, now: now))
            #expect(fresh.requestID != intent.requestID && fresh.phase == .held)
        }
    }

    @Test("denied canonical identities and aliases cannot rebind to competing admissions")
    func deniedOperationRebinding() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let store = try PostgresV2GroupJoinQuotaStore(database: database, schema: schema)
            let applicant = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), invite = GroupInviteID(uuid: UUID())
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let original = candidate(applicant: applicant), duplicate = candidate(applicant: applicant, note: "alias note")
            let first = try requireIntent(await store.reserve(original, roomID: room, inviteID: invite, now: now))
            _ = try await store.reserve(duplicate, roomID: room, inviteID: invite, now: now)
            try await store.resolve(first, outcome: .unavailable, targetRequestID: nil, now: now)
            #expect(try await store.reserve(duplicate, roomID: room, inviteID: invite, now: now) == .limited)
            let competing = try requireIntent(await store.reserve(candidate(applicant: applicant, note: "canonical note"), roomID: room, inviteID: invite, now: now))
            try await store.resolve(competing, outcome: .pending, targetRequestID: competing.requestID, now: now)
            #expect(try await store.reserve(duplicate, roomID: room, inviteID: invite, now: now) == .limited)
            #expect(try await store.reserve(original, roomID: room, inviteID: invite, now: now) == .limited)
            try await store.resolve(competing, outcome: .cancelled, targetRequestID: competing.requestID, now: now)
            #expect(try await store.reserve(duplicate, roomID: room, inviteID: invite, now: now) == .limited)
            #expect(try await store.resolve(first, outcome: .unavailable, targetRequestID: nil, now: now))
            #expect(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).group_join_quota_aliases WHERE operation_id = \(bind: duplicate.operationID.uuidValue!) AND canonical_operation_id = \(bind: first.operationID)").first(decoding: QuotaTestCount.self)?.value == 1)
        }
    }

    private func candidate(applicant: UserID, operation: GroupJoinRequestOperationID = .init(uuid: UUID()), limit: Int = 1, note: String? = nil, digest: UInt8 = 1) -> V2GroupJoinSubmissionPersistenceRequest {
        .init(requestID: .init(uuid: UUID()), applicantUserID: applicant, operationID: operation,
              tokenDigest: Data(repeating: digest, count: 32), note: note, createdAt: Date(timeIntervalSince1970: 1_750_000_000),
              maximumPendingRequestsPerApplicant: limit, maximumPendingRequestsPerInvite: 100)
    }
    private func requireIntent(_ value: V2GroupJoinQuotaReservation) throws -> V2GroupJoinQuotaIntent {
        guard case .reserved(let intent) = value else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        return intent
    }
}
private struct QuotaTestCount: Decodable { let value: Int }

private struct QuotaGeneration: Decodable { let value: Int64 }
