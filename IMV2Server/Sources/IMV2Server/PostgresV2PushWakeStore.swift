import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL implementation of the generic Push wake admission contract.
/// Campaign, exact budget window, and outbox row are locked together before a
/// provider can inspect any device-specific Push material. Missing budget data
/// fails closed by suppressing that wake only. Once that admission commits,
/// later provider retries and reclaimed leases reuse it rather than spending a
/// second device-key-work permit.
public struct PostgresV2PushWakeStore: V2PushWakeStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    public func claimAdmitted(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2PushWakeLease] {
        guard limit > 0, leaseDuration > 0 else { return [] }
        var leases: [V2PushWakeLease] = []
        for _ in 0..<limit {
            guard let lease = try await claimOne(now: now, leaseDuration: leaseDuration) else { break }
            leases.append(lease)
        }
        return leases
    }

    public func markSent(_ lease: V2PushWakeLease, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.push_wake_outbox
            SET state = 'sent', sent_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL
            WHERE dispatch_id = \(bind: lease.wake.dispatchID)
              AND state = 'claimed'
              AND claim_token = \(bind: lease.claimToken)
            """).run()
    }

    public func suppress(_ lease: V2PushWakeLease, reason: V2PushSuppressionReason) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.push_wake_outbox
            SET state = 'suppressed', suppression_reason = \(bind: suppressionCode(reason)),
                claim_token = NULL, lease_expires_at = NULL
            WHERE dispatch_id = \(bind: lease.wake.dispatchID)
              AND state = 'claimed'
              AND claim_token = \(bind: lease.claimToken)
            """).run()
    }

    public func release(_ lease: V2PushWakeLease) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.push_wake_outbox
            SET state = 'pending', claim_token = NULL, lease_expires_at = NULL
            WHERE dispatch_id = \(bind: lease.wake.dispatchID)
              AND state = 'claimed'
              AND claim_token = \(bind: lease.claimToken)
            """).run()
    }

    private func claimOne(now: Date, leaseDuration: TimeInterval) async throws -> V2PushWakeLease? {
        let token = makeUUID()
        let expiry = now.addingTimeInterval(leaseDuration)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            // Push carries only a generic wake hint, so suppressing it for a
            // muted room cannot affect durable user-sync correctness. Perform
            // this before admission so a muted wake never consumes device
            // budget. Expired leases are included because their provider work
            // is no longer active and they may otherwise be reclaimed.
            try await sql.raw("""
                UPDATE im_v2.push_wake_outbox AS wake
                SET state = 'suppressed', suppression_reason = 'conversation_muted',
                    claim_token = NULL, lease_expires_at = NULL
                FROM im_v2.room_events AS event,
                     im_v2.user_room_preferences AS preference
                WHERE wake.source_event_id = event.event_id
                  AND preference.user_id = wake.target_user_id
                  AND preference.room_id = event.room_id
                  AND preference.mute_until > \(bind: now)
                  AND (
                    wake.state = 'pending'
                    OR (wake.state = 'claimed' AND wake.lease_expires_at <= \(bind: now))
                  )
                """).run()
            guard let pending = try await sql.raw("""
                SELECT dispatch_id, target_device_id, campaign_id, budget_window_started_at,
                       requires_new_key_operation, admitted_at
                FROM im_v2.push_wake_outbox
                WHERE state = 'pending'
                   OR (state = 'claimed' AND lease_expires_at <= \(bind: now))
                ORDER BY created_at, dispatch_id
                LIMIT 1
                FOR UPDATE SKIP LOCKED
                """).first(decoding: PendingPushWakeRow.self) else { return nil }
            guard let campaign = try await sql.raw("""
                SELECT state FROM im_v2.push_campaigns WHERE campaign_id = \(bind: pending.campaignID) FOR UPDATE
                """).first(decoding: PushCampaignRow.self), campaign.state == "enabled" else {
                try await suppress(pending.dispatchID, reason: .campaignDisabled, on: sql)
                return nil
            }
            if pending.admittedAt == nil {
                guard let budget = try await sql.raw("""
                    SELECT max_work_units, used_work_units, max_new_key_operations, used_new_key_operations
                    FROM im_v2.push_device_budgets
                    WHERE device_id = \(bind: pending.deviceID)
                      AND campaign_id = \(bind: pending.campaignID)
                      AND window_started_at = \(bind: pending.budgetWindowStartedAt)
                    FOR UPDATE
                    """).first(decoding: PushBudgetRow.self) else {
                    try await suppress(pending.dispatchID, reason: .deviceBudgetUnavailable, on: sql)
                    return nil
                }
                let request = try V2PushAdmissionRequest(campaignID: .init(rawValue: pending.campaignID), requiresNewKeyOperation: pending.requiresNewKeyOperation)
                let current = try V2PushDeviceBudget(
                    maxWorkUnits: budget.maxWorkUnits,
                    usedWorkUnits: budget.usedWorkUnits,
                    maxNewKeyOperations: budget.maxNewKeyOperations,
                    usedNewKeyOperations: budget.usedNewKeyOperations
                )
                switch try V2PushAdmissionEvaluator.evaluate(campaignEnabled: true, request: request, budget: current) {
                case .suppressed(let reason):
                    try await suppress(pending.dispatchID, reason: reason, on: sql)
                    return nil
                case .allowed(let next):
                    try await sql.raw("""
                        UPDATE im_v2.push_device_budgets
                        SET used_work_units = \(bind: next.usedWorkUnits),
                            used_new_key_operations = \(bind: next.usedNewKeyOperations)
                        WHERE device_id = \(bind: pending.deviceID)
                          AND campaign_id = \(bind: pending.campaignID)
                          AND window_started_at = \(bind: pending.budgetWindowStartedAt)
                        """).run()
                }
            }
            try await sql.raw("""
                UPDATE im_v2.push_wake_outbox
                SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: expiry),
                    retry_count = retry_count + 1, admitted_at = COALESCE(admitted_at, \(bind: now))
                WHERE dispatch_id = \(bind: pending.dispatchID) AND state IN ('pending', 'claimed')
                """).run()
            return try .init(
                wake: .init(dispatchID: pending.dispatchID, deviceID: .init(pending.deviceID.uuidString), campaignID: .init(rawValue: pending.campaignID)),
                claimToken: token
            )
        }
    }

    private func suppress(_ dispatchID: UUID, reason: V2PushSuppressionReason, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE im_v2.push_wake_outbox
            SET state = 'suppressed', suppression_reason = \(bind: suppressionCode(reason)), claim_token = NULL, lease_expires_at = NULL
            WHERE dispatch_id = \(bind: dispatchID) AND state IN ('pending', 'claimed')
            """).run()
    }

    private func suppressionCode(_ reason: V2PushSuppressionReason) -> String {
        switch reason {
        case .campaignDisabled: return "campaign_disabled"
        case .conversationMuted: return "conversation_muted"
        case .deviceBudgetUnavailable: return "device_budget_unavailable"
        case .deviceWorkBudgetExhausted: return "device_work_budget_exhausted"
        case .deviceNewKeyBudgetExhausted: return "device_new_key_budget_exhausted"
        case .endpointUnavailable: return "endpoint_unavailable"
        case .endpointRejected: return "endpoint_rejected"
        }
    }
}

private struct PendingPushWakeRow: Decodable {
    let dispatchID: UUID
    let deviceID: UUID
    let campaignID: String
    let budgetWindowStartedAt: Date
    let requiresNewKeyOperation: Bool
    let admittedAt: Date?
    enum CodingKeys: String, CodingKey {
        case dispatchID = "dispatch_id"
        case deviceID = "target_device_id"
        case campaignID = "campaign_id"
        case budgetWindowStartedAt = "budget_window_started_at"
        case requiresNewKeyOperation = "requires_new_key_operation"
        case admittedAt = "admitted_at"
    }
}

private struct PushCampaignRow: Decodable { let state: String }

private struct PushBudgetRow: Decodable {
    let maxWorkUnits: Int
    let usedWorkUnits: Int
    let maxNewKeyOperations: Int
    let usedNewKeyOperations: Int
    enum CodingKeys: String, CodingKey {
        case maxWorkUnits = "max_work_units"
        case usedWorkUnits = "used_work_units"
        case maxNewKeyOperations = "max_new_key_operations"
        case usedNewKeyOperations = "used_new_key_operations"
    }
}
