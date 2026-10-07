import Foundation
import FluentKit
import SQLKit
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2Core
import IMV2ActorContracts

/// A room-side decision bound to the exact command and activation. Ordinary
/// persistence uses runtime state; conditional writes reject a stale cursor.
struct V2AcceptedDirectSend: Sendable {
    let command: V2SendMessageCommand
    let activation: V2RoomActivationToken
    let membershipRevision: Int64
    let context: DirectMessageAcceptanceContext
}

actor V2DirectRoomSendAcceptanceMemory {
    private struct Load { let id: UUID; let task: Task<State?, any Error> }
    private var initializedGroups: Set<V2RoomActivationToken> = []
    private var states: [V2RoomActivationToken: State] = [:]
    private var loads: [V2RoomActivationToken: Load] = [:]
    private var order: [V2RoomActivationToken] = []
    private var policies: [V2RoomActivationToken: [UUID: V2DirectSendControlPolicy]] = [:]

    func accept(command: V2SendMessageCommand, token: V2RoomActivationToken,
        policy: V2DirectSendControlPolicy, now: Date) async throws -> V2AcceptedDirectSend? {
        if let previous = policies[token]?[policy.sender.userID], previous != policy {
            invalidate(token)
        }
        // Unanswered stranger quota and special accounts retain their durable
        // workflows. Established conversations reuse the recipient's reply fact.
        guard !policy.blocked, policy.sender.isActive, policy.recipient.isActive,
              policy.sender.specialKind == nil, policy.recipient.specialKind == nil else { return nil }
        let state = states[token]
        guard let state else { return nil }
        policies[token, default: [:]][policy.sender.userID] = policy
        return try decision(command: command, token: token, policy: policy, state: state, now: now)
    }

    func needsInitialization(token: V2RoomActivationToken) -> Bool {
        states[token] == nil && !initializedGroups.contains(token)
    }

    func initializeIfNeeded(token: V2RoomActivationToken, database: any Database) async throws {
        guard !initializedGroups.contains(token) else { return }
        try Task.checkCancellation()
        let state: State?
        if let existing = states[token] { state = existing }
        else {
            let load: Load
            if let existing = loads[token] { load = existing }
            else {
                let task = Task<State?, any Error> {
                    return try await database.withConnection { connection in
                        connection.eventLoop.makeFutureWithTask {
                            guard let sql = connection as? any SQLDatabase else {
                                throw V2RoomWriteStoreError.corruptPersistenceState
                            }
                            return try await Self.readInitialization(sql: sql, token: token).directState
                        }
                    }.get()
                }
                load = .init(id: UUID(), task: task); loads[token] = load
            }
            do {
                state = try await load.task.value
                if loads[token]?.id == load.id {
                    loads.removeValue(forKey: token)
                    if let state {
                        states[token] = state; order.append(token)
                        if order.count > 8192 {
                            let evicted = order.removeFirst(); states.removeValue(forKey: evicted); policies.removeValue(forKey: evicted)
                        }
                    } else { initializedGroups.insert(token) }
                } else { return } // A concurrent mutation invalidated this initialization.
            } catch {
                if loads[token]?.id == load.id { loads.removeValue(forKey: token) }
                throw error
            }
        }
        _ = state
    }

    func install(_ initialization: V2RoomSendInitialization) {
        invalidate(initialization.token)
        if let state = initialization.directState {
            states[initialization.token] = state
            order.append(initialization.token)
        } else if initialization.kind == "group" { initializedGroups.insert(initialization.token) }
    }

    static func readInitialization(sql: any SQLDatabase, token: V2RoomActivationToken) async throws -> V2RoomSendInitialization {
        guard let room = token.roomID.uuidValue else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        guard let row = try await sql.raw("""
            /* imv2_room_send_initialization */
            SELECT r.room_kind, r.membership_revision, r.frozen_at, r.room_sequence, r.timeline_sequence,
                   r.room_shard_id, r.capacity_profile_id, r.capacity_class,
                   p.direct_policy_revision,
                   p.lower_user_id, p.higher_user_id,
                   p.lower_has_replied, p.higher_has_replied,
                   p.lower_profile_visible_to_higher, p.higher_profile_visible_to_lower,
                   p.lower_can_send, p.higher_can_send,
                   CASE WHEN r.room_kind='direct' THEN (SELECT count(*) FROM im_v2.room_memberships m WHERE m.room_id=r.room_id
                      AND m.joined_revision<=r.membership_revision
                      AND (m.left_revision IS NULL OR m.left_revision>r.membership_revision)
                      AND m.user_id IN (p.lower_user_id,p.higher_user_id)) ELSE 0 END AS members,
                   CASE WHEN r.room_kind='direct' THEN (SELECT count(*) FROM im_v2.room_memberships m WHERE m.room_id=r.room_id
                      AND m.joined_revision<=r.membership_revision
                      AND (m.left_revision IS NULL OR m.left_revision>r.membership_revision)) ELSE 0 END AS total_members,
                   (SELECT max(mute_until) FROM im_v2.room_member_mutes m
                      WHERE m.room_id=r.room_id AND m.user_id=p.lower_user_id) AS lower_mute,
                   (SELECT max(mute_until) FROM im_v2.room_member_mutes m
                      WHERE m.room_id=r.room_id AND m.user_id=p.higher_user_id) AS higher_mute
            FROM im_v2.rooms r LEFT JOIN im_v2.direct_room_pairs p ON p.room_id=r.room_id
            WHERE r.room_id=\(bind: room)
            """).first() else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        let kind = try row.decode(column: "room_kind", as: String.self)
        guard kind == "direct" || kind == "group" else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        return .init(token: token, kind: kind, directState: kind == "direct" ? try row.decode(model: State.self) : nil)
    }

    private func decision(command: V2SendMessageCommand, token: V2RoomActivationToken,
        policy: V2DirectSendControlPolicy, state: State, now: Date) throws -> V2AcceptedDirectSend? {
        guard !policy.blocked, policy.sender.isActive, policy.recipient.isActive,
              policy.sender.specialKind == nil, policy.recipient.specialKind == nil else { return nil }
        guard state.members == 2, state.totalMembers == 2 else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard state.frozenAt == nil, let sender = command.senderUserID.uuidValue,
              (sender == state.lower || sender == state.higher),
              policy.recipient.userID == (sender == state.lower ? state.higher : state.lower) else { return nil }
        let lower = sender == state.lower
        guard policy.isFriend || (lower ? state.higherReplied : state.lowerReplied) else { return nil }
        guard (lower ? state.lowerMute : state.higherMute).map({ $0 > now }) != true else { return nil }
        return .init(command: command, activation: token, membershipRevision: state.membershipRevision,
            context: .init(recipientID: policy.recipient.userID, restriction: nil, requiresStrangerQuota: false,
                senderProfileVisibleToRecipient: lower ? state.lowerVisible : state.higherVisible,
                senderCanSend: lower ? state.lowerCanSend : state.higherCanSend,
                senderHasReplied: lower ? state.lowerReplied : state.higherReplied, supportAccountID: nil))
    }

    /// Execution obtains the latest committed room state, not the snapshot
    /// captured by an earlier preparation. The room turn owns serialization.
    func preflight(command: V2SendMessageCommand, token: V2RoomActivationToken,
        policy: V2DirectSendControlPolicy,
        ordinal: Int, now: Date) throws -> PlainDirectRoomLogBatchPreflightRow? {
        // This runs with the write connection held. Cold/revoked state must
        // fall back to the transaction's existing durable preflight, never
        // start another pool loan while occupying the message connection.
        if let previous = policies[token]?[policy.sender.userID], previous != policy {
            invalidate(token); return nil
        }
        guard let state = states[token], state.cursorIsValid else {
            invalidate(token); return nil
        }
        guard let decision = try decision(command: command, token: token, policy: policy, state: state, now: now) else { return nil }
        let room = RoomRow(kind: "direct", roomShardID: state.roomShardID,
            roomSequence: state.roomSequence, timelineSequence: state.timelineSequence,
            membershipRevision: state.membershipRevision, capacityProfileID: state.capacityProfileID,
            capacityClass: state.capacityClass, frozenAt: state.frozenAt)
        return .init(ordinal: ordinal, room: room,
            context: decision.context, policy: policy, directPolicyRevision: state.directPolicyRevision,
            recipientHasReplied: policy.sender.userID == state.lower ? state.higherReplied : state.lowerReplied)
    }

    func committed(commands: [V2MessageSendOperationCommand], results: [V2RoomMessagingResult], token: V2RoomActivationToken) {
        guard commands.count == results.count, var state = states[token] else { return }
        for (command, result) in zip(commands, results) {
            guard case .sendOperation(.receipt(let receipt)) = result, case .accepted(let accepted) = receipt.outcome else { continue }
            guard let sequence = Int64(exactly: accepted.roomSequence), sequence > state.roomSequence else { continue }
            let delta = sequence - state.roomSequence
            guard state.timelineSequence <= Int64.max - delta else {
                invalidate(token); return
            }
            state.roomSequence = sequence
            state.timelineSequence += delta
            if command.command.senderUserID.uuidValue == state.lower {
                if !state.lowerReplied { state.directPolicyRevision += 1 }
                state.lowerReplied = true; state.lowerVisible = true; state.lowerCanSend = true
            } else if command.command.senderUserID.uuidValue == state.higher {
                if !state.higherReplied { state.directPolicyRevision += 1 }
                state.higherReplied = true; state.higherVisible = true; state.higherCanSend = true
            }
        }
        states[token] = state
    }

    /// Compatibility appends can change private timeline facts. Keep immutable
    /// membership/reply eligibility for preparation, but reload cursors before
    /// a later optimized write. These facts never authorize persistence alone.
    func invalidateCursor(_ token: V2RoomActivationToken) {
        guard var state = states[token] else { return }
        state.cursorIsValid = false; states[token] = state
    }

    func invalidate(_ token: V2RoomActivationToken) {
        initializedGroups.remove(token)
        states.removeValue(forKey: token); loads.removeValue(forKey: token); policies.removeValue(forKey: token)
        order.removeAll { $0 == token }
    }

    struct State: Decodable, Sendable {
        var cursorIsValid = true
        let membershipRevision: Int64
        let frozenAt: Date?
        var roomSequence: Int64
        var timelineSequence: Int64
        let roomShardID: String
        let capacityProfileID: String
        let capacityClass: V2GroupCapacityClass
        var directPolicyRevision: Int64
        let lower: UUID
        let higher: UUID
        var lowerReplied: Bool
        var higherReplied: Bool
        var lowerVisible: Bool
        var higherVisible: Bool
        var lowerCanSend: Bool?
        var higherCanSend: Bool?
        let members: Int
        let totalMembers: Int
        let lowerMute: Date?
        let higherMute: Date?
        enum CodingKeys: String, CodingKey {
            case membershipRevision = "membership_revision", frozenAt = "frozen_at"
            case roomSequence = "room_sequence", timelineSequence = "timeline_sequence"
            case roomShardID = "room_shard_id", capacityProfileID = "capacity_profile_id", capacityClass = "capacity_class"
            case directPolicyRevision = "direct_policy_revision"
            case lower = "lower_user_id", higher = "higher_user_id"
            case lowerReplied = "lower_has_replied", higherReplied = "higher_has_replied"
            case lowerVisible = "lower_profile_visible_to_higher", higherVisible = "higher_profile_visible_to_lower"
            case lowerCanSend = "lower_can_send", higherCanSend = "higher_can_send"
            case members, totalMembers = "total_members", lowerMute = "lower_mute", higherMute = "higher_mute"
        }
    }
}
