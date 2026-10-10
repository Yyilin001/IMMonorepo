import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 一次保留裁剪的结论。
public struct V2RoomLogTrimReport: Equatable, Sendable {
    /// 本次检查的房间数。
    public let scannedRooms: Int
    /// 实际推进了下界、删除了历史的房间数。
    public let trimmedRooms: Int
    /// 删除的事件行数。
    public let deletedEvents: Int

    /// 保存保留裁剪结论。
    ///
    /// - Parameters:
    ///   - scannedRooms: 本次检查的房间数。
    ///   - trimmedRooms: 实际裁剪的房间数。
    ///   - deletedEvents: 删除的事件行数。
    public init(scannedRooms: Int, trimmedRooms: Int, deletedEvents: Int) {
        self.scannedRooms = scannedRooms
        self.trimmedRooms = trimmedRooms
        self.deletedEvents = deletedEvents
    }
}

/// 房间日志保留裁剪的 PostgreSQL 实现。
///
/// 下界取"仍然钉住历史的读者的已读线最小值"：窗口模式只看窗口内更新过已读线的读者，
/// 永久模式看全部历史读者。没有任何读者钉住时，下界就是房间头——此时该房间的日志不再
/// 承担送达义务，返回的客户端会通过下界标记得知历史不完整。
///
/// 删除是本项目里**唯一**允许移除房间事件的路径，由触发器双重约束：语句必须显式声明
/// 这是保留裁剪，且被删事件序号必须已经低于房间的裁剪下界。
public actor PostgresV2RoomLogRetentionStore {
    private let database: any Database
    /// 每个获准房间事务最多删除的事件数。
    private let eventLimit: Int
    // 稳定主键轮转；事务成功后才推进。重启从头开始，不影响裁剪安全性。
    private var lastScannedRoomID: UUID?
    private var isTrimming = false

    /// 组合数据库。
    ///
    /// - Parameters:
    ///   - database: 存放房间、房间事件与已读线的数据库。
    ///   - eventLimit: 每个事务的事件删除预算，需在 1...10_000 内。
    public init(database: any Database, eventLimit: Int = 512) {
        self.database = database
        self.eventLimit = eventLimit
    }

    /// 发现结果只是只读提示，不授予裁剪权限；
    /// 每个候选房间都必须单独进入获准的房间维护轮次。
    public func scanCandidateRoomIDs(limit: Int) async throws -> [RoomID] {
        guard (1...1_000).contains(limit) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard !isTrimming else { return [] }
        isTrimming = true
        defer { isTrimming = false }
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let afterRoomID = lastScannedRoomID
        let cursorPredicate: SQLQueryString = if let afterRoomID {
            "room_id > \(bind: afterRoomID)"
        } else { "TRUE" }
        var rows = try await sql.raw("""
            SELECT room_id FROM im_v2.rooms WHERE \(cursorPredicate)
              AND (room_sequence > log_trimmed_through_room_sequence OR EXISTS (
                  SELECT 1 FROM im_v2.room_events AS event
                  WHERE event.room_id = rooms.room_id
                    AND event.room_sequence < rooms.log_trimmed_through_room_sequence))
            ORDER BY room_id LIMIT \(bind: limit)
            """).all(decoding: RoomLogLockedRow.self)
        if rows.isEmpty, afterRoomID != nil {
            rows = try await sql.raw("""
                SELECT room_id FROM im_v2.rooms
                WHERE room_sequence > log_trimmed_through_room_sequence OR EXISTS (
                    SELECT 1 FROM im_v2.room_events AS event
                    WHERE event.room_id = rooms.room_id
                      AND event.room_sequence < rooms.log_trimmed_through_room_sequence)
                ORDER BY room_id LIMIT \(bind: limit)
                """).all(decoding: RoomLogLockedRow.self)
        }
        lastScannedRoomID = rows.last?.roomID
        return rows.map { RoomID(uuid: $0.roomID) }
    }

    /// 在房间的精确激活下执行已获准的裁剪。下界计算、下界更新
    /// 和触发器授权的删除共用受围栏保护的事务；
    /// 新纪元出现后，旧宿主不能再提交。
    public func trimRoomLog(
        token: V2RoomActivationToken, mode: V2RoomLogRetentionMode,
        window: TimeInterval, now: Date,
        timeouts: V2RoomActivationSQLTimeouts = .default
    ) async throws -> V2RoomLogTrimReport {
        guard (1...10_000).contains(eventLimit),
              window.isFinite, window > 0, v2PostgresTimestampCanEncode(now),
              let activeSince = v2PostgresPastTimestamp(now: now, interval: window),
              let roomID = token.roomID.uuidValue else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let eventLimit = self.eventLimit
        let attempt = V2RoomTransactionAttempt()
        do {
            return try await v2WithRoomScopedTransaction(database: database, timeouts: timeouts) { transaction in
                try await attempt.body {
                    guard let sql = transaction as? any SQLDatabase else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    try await v2RequireRoomActivations(tokens: [token], sql: sql, timeouts: timeouts)
                    let candidates = try await roomLogRetentionCandidates(
                        roomIDs: [roomID], mode: mode, activeSince: activeSince, sql: sql)
                    guard let candidate = candidates.first, candidates.count == 1 else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    let outcome = try await trimRoomLogCandidate(candidate, eventLimit: eventLimit, sql: sql)
                    return .init(scannedRooms: 1, trimmedRooms: outcome.trimmed ? 1 : 0,
                        deletedEvents: outcome.deletedEvents)
                }
            }
        } catch { throw error }
    }
}

private struct RoomLogLockedRow: Decodable {
    let roomID: UUID
    enum CodingKeys: String, CodingKey { case roomID = "room_id" }
}

private struct RoomLogRetentionCandidateRow: Decodable {
    let roomID: UUID
    let floorSequence: Int64
    let trimmedThrough: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", floorSequence = "floor_sequence", trimmedThrough = "trimmed_through"
    }
}

private struct RoomLogTrimmedRow: Decodable {
    let count: Int64?
    let roomID: UUID?
    enum CodingKeys: String, CodingKey { case count, roomID = "room_id" }
}

private struct RoomLogDeletionCandidateRow: Decodable {
    let eventID: UUID
    let roomSequence: Int64
    enum CodingKeys: String, CodingKey {
        case eventID = "event_id", roomSequence = "room_sequence"
    }
}

private func roomLogRetentionCandidates(
    roomIDs: [UUID], mode: V2RoomLogRetentionMode,
    activeSince: Date, sql: any SQLDatabase
) async throws -> [RoomLogRetentionCandidateRow] {
    try await sql.raw("""
        SELECT room.room_id, room.log_trimmed_through_room_sequence AS trimmed_through,
               GREATEST(
                   COALESCE(
                       (
                           SELECT MIN(reader.read_sequence)
                           FROM (
                               SELECT receipt.read_through_room_sequence AS read_sequence
                               FROM im_v2.room_read_receipts AS receipt
                               WHERE receipt.room_id = room.room_id
                                 AND (\(bind: mode.rawValue) = 'permanent'
                                      OR receipt.updated_at >= \(bind: activeSince))
                               UNION ALL
                               -- An active member without a receipt still pins the floor.
                               SELECT 0::bigint
                               FROM im_v2.room_memberships AS member
                               WHERE member.room_id = room.room_id
                                 AND member.left_revision IS NULL
                                 AND NOT EXISTS (
                                     SELECT 1 FROM im_v2.room_read_receipts AS receipt
                                     WHERE receipt.room_id = member.room_id
                                       AND receipt.user_id = member.user_id
                                 )
                           ) AS reader
                       ),
                       room.room_sequence
                   ),
                   0
               )::bigint AS floor_sequence
        FROM im_v2.rooms AS room
        WHERE room.room_id = ANY(\(bind: roomIDs)::uuid[])
        ORDER BY room.room_id
        """).all(decoding: RoomLogRetentionCandidateRow.self)
}

private func trimRoomLogCandidate(
    _ candidate: RoomLogRetentionCandidateRow, eventLimit: Int, sql: any SQLDatabase
) async throws -> (trimmed: Bool, deletedEvents: Int) {
    // 序号从一开始；下界不大于一时不能删除真实事件。
    // 已经宣布裁剪的历史不会因后续读者变化而重新承担送达义务。
    let targetFloor = max(candidate.floorSequence, candidate.trimmedThrough)
    guard targetFloor > 1 else { return (false, 0) }
    // 先固定有界事件集，投影还原和删除共用这些 ID。
    // 同一序号可有多个事件类型；若预算在该序号内耗尽，未删除的行由后续批次处理，
    // 不能要求每轮都推进下界，否则同一序号的大批事件会永久停滞。
    let events = try await sql.raw("""
        SELECT event_id, room_sequence FROM im_v2.room_events
        WHERE room_id = \(bind: candidate.roomID)
          AND room_sequence < \(bind: targetFloor)
        ORDER BY room_sequence, event_type LIMIT \(bind: eventLimit + 1)
        """).all(decoding: RoomLogDeletionCandidateRow.self)
    let selected = Array(events.prefix(eventLimit))
    let batchFloor = events.count > eventLimit
        ? selected[selected.count - 1].roomSequence + 1 : targetFloor
    let advanced = try await sql.raw("""
        UPDATE im_v2.rooms
        SET log_trimmed_through_room_sequence = GREATEST(
                log_trimmed_through_room_sequence, \(bind: batchFloor))
        WHERE room_id = \(bind: candidate.roomID)
          AND log_trimmed_through_room_sequence < \(bind: batchFloor)
        RETURNING room_id
        """).first(decoding: RoomLogTrimmedRow.self) != nil
    guard !selected.isEmpty else { return (advanced, 0) }
    let eventIDs = selected.map(\.eventID)
    // 锁定来源事件将被删除的每项状态，包括此语句快照中仍内联的状态。
    // 压缩器可能正并发地把内联状态改为 room_event；若只过滤 room_event，
    // 就可能跳过尚未提交的更新并删除事件。
    // 更新每条被引用的记录会等待该写入方，并在其提交后恢复内联载荷。
    // 后续压缩器会跳过我们锁定的记录，提交后也找不到已删除的源事件。
    // schema 只允许 variant_key=0 使用 room_event；每事件至多匹配一项状态，
    // 其他变体必定内联，无需更新，投影还原因此也受同一个事件预算约束。
    try await sql.raw("""
        UPDATE im_v2.message_projection_states AS state
        SET payload = CASE WHEN state.payload_storage = 'room_event'
                           THEN event.payload ELSE state.payload END,
            payload_storage = 'inline'
        FROM im_v2.room_events AS event
        WHERE state.room_id = \(bind: candidate.roomID)
          AND state.variant_key = 0
          AND state.state_event_id = event.event_id
          AND event.room_id = state.room_id
          AND event.event_id = ANY(\(bind: eventIDs)::uuid[])
        """).run()
    // 触发器会独立检查，确保只删除低于下界的记录。
    try await sql.raw("SET LOCAL im_v2.retention_trim = 'on'").run()
    let removed = try await sql.raw("""
        WITH removed AS (
            DELETE FROM im_v2.room_events
            WHERE room_id = \(bind: candidate.roomID)
              AND event_id = ANY(\(bind: eventIDs)::uuid[])
            RETURNING event_id
        )
        SELECT count(*)::bigint AS count FROM removed
        """).first(decoding: RoomLogTrimmedRow.self)
    try await sql.raw("SET LOCAL im_v2.retention_trim = 'off'").run()
    return (advanced, Int(removed?.count ?? 0))
}
