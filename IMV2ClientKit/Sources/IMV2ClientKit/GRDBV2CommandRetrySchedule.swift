import Foundation
import GRDB

/// Select exactly the lanes installed in a runtime. An unsupported pending
/// table must never keep another runtime's worker in a ready-work loop.
public enum V2DurableCommandLane: Sendable, CaseIterable, Hashable {
    case messages, withdrawals, redactions, edits, reactions, readReceipts
    case membership, memberMutes, moderatedMemberRemovals, groupCapabilities
    case conversationCapabilities, social, groupCreation, forwardPlans, legacyForwardMessages
}

extension GRDBV2LocalSyncStore {
    public nonisolated func commandRetrySchedule(lanes: Set<V2DurableCommandLane>) -> V2CommandRetrySchedule {
        let query = Self.commandRetryScheduleQuery(lanes: lanes)
        let pool = databasePool
        return .init(
            nextAttemptAt: {
                try await pool.read { db in
                    try Double.fetchOne(db, sql: query).map(Date.init(timeIntervalSince1970:))
                }
            },
            updates: {
                AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                    let task = Task {
                        do {
                            let observation = ValueObservation.tracking { db in
                                try Double.fetchOne(db, sql: query)
                            }.removeDuplicates()
                            for try await _ in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) {
                                continuation.yield(())
                            }
                            continuation.finish()
                        } catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        )
    }

    static func commandRetryScheduleQuery(lanes: Set<V2DurableCommandLane>) -> String {
        var candidates: [String] = []
        func pending(_ table: String, states: String = "'pending'") {
            let predicate = states == "'pending'" ? "state = 'pending'" : "state IN (\(states))"
            candidates.append("SELECT MIN(next_attempt_at) AS due FROM \(table) WHERE \(predicate)")
        }
        // Fixed ordering makes both observation regions and query plans stable.
        for lane in V2DurableCommandLane.allCases where lanes.contains(lane) {
            switch lane {
            case .messages: pending("v2_pending_message_commands")
            case .withdrawals: pending("v2_pending_message_withdrawals")
            case .redactions: pending("v2_pending_message_redactions")
            case .edits: pending("v2_pending_message_edits")
            case .reactions: pending("v2_pending_message_reactions")
            case .readReceipts: pending("v2_pending_read_receipts")
            case .membership: pending("v2_pending_membership_commands")
            case .memberMutes: pending("v2_pending_member_mutes")
            case .moderatedMemberRemovals: pending("v2_pending_moderated_member_removals")
            case .groupCapabilities: pending("v2_pending_group_capabilities")
            case .conversationCapabilities:
                pending("v2_pending_conversation_states")
                pending("v2_pending_message_favorites")
            case .social: pending("v2_pending_social_commands")
            case .groupCreation: pending("v2_pending_group_room_creations", states: "'pending','finalizing','cancelling'")
            case .legacyForwardMessages: pending("v2_pending_forward_messages")
            case .forwardPlans:
                pending("v2_forward_message_chunks")
                candidates.append("""
                    SELECT 0.0 AS due FROM v2_forward_message_plans AS plan
                    WHERE plan.state = 'active' AND NOT EXISTS (
                        SELECT 1 FROM v2_forward_message_chunks AS chunk
                        WHERE chunk.plan_id = plan.plan_id AND chunk.chunk_index = plan.next_chunk_index
                    ) LIMIT 1
                    """)
            }
        }
        guard !candidates.isEmpty else { return "SELECT NULL" }
        // Each subquery reads an indexed minimum, never command payloads.
        return "SELECT MIN(due) FROM (" + candidates.map { "SELECT due FROM (\($0))" }.joined(separator: " UNION ALL ") + ")"
    }
}
