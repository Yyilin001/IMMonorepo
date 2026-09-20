import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 房间日志的保留模式。
///
/// 两种模式共用同一条代码路径，差别只是"读者什么时候不再钉住下界"：
/// 窗口模式只计入窗口内仍活跃的读者，永久模式计入全部历史读者。
public enum V2RoomLogRetentionMode: String, Equatable, Sendable {
    /// 读者超出宽限窗口后不再钉住下界；历史会被裁剪，返回时显式标记不完整。
    case window
    /// 计入全部历史读者的已读线，没有人追上则下界不推进（默认，与既有行为一致）。
    case permanent
}

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

/// 房间日志保留裁剪的持久化能力。
public protocol V2RoomLogRetentionStore: Sendable {
    /// 按保留模式推进一批房间的裁剪下界并删除其下的历史事件。
    ///
    /// - Parameters:
    ///   - mode: 保留模式。
    ///   - window: 窗口模式下读者不再钉住下界的宽限秒数；永久模式忽略该值。
    ///   - now: 服务端统一授时时刻。
    ///   - limit: 本轮最多检查的房间数。
    /// - Returns: 本轮裁剪结论。
    /// - Throws: 参数非法或持久化失败时抛出。
    func trimRoomLogs(
        mode: V2RoomLogRetentionMode,
        window: TimeInterval,
        now: Date,
        limit: Int
    ) async throws -> V2RoomLogTrimReport
}

/// 房间日志保留裁剪的 PostgreSQL 实现。
///
/// 下界取"仍然钉住历史的读者的已读线最小值"：窗口模式只看窗口内更新过已读线的读者，
/// 永久模式看全部历史读者。没有任何读者钉住时，下界就是房间头——此时该房间的日志不再
/// 承担送达义务，返回的客户端会通过下界标记得知历史不完整。
///
/// 删除是本项目里**唯一**允许移除房间事件的路径，由触发器双重约束：语句必须显式声明
/// 这是保留裁剪，且被删事件序号必须已经低于房间的裁剪下界。
public actor PostgresV2RoomLogRetentionStore: V2RoomLogRetentionStore {
    private let database: any Database
    // 稳定主键轮转；事务成功后才推进。重启从头开始，不影响裁剪安全性。
    private var lastScannedRoomID: UUID?
    private var isTrimming = false

    /// 组合数据库。
    ///
    /// - Parameter database: 存放房间、房间事件与已读线的数据库。
    public init(database: any Database) {
        self.database = database
    }

    /// 按保留模式推进一批房间的裁剪下界并删除其下的历史事件。
    ///
    /// - Parameters:
    ///   - mode: 保留模式。
    ///   - window: 窗口模式下读者不再钉住下界的宽限秒数，需大于零。
    ///   - now: 服务端统一授时时刻。
    ///   - limit: 本轮最多检查的房间数，需大于零。
    /// - Returns: 本轮裁剪结论。
    /// - Throws: 参数非法、时刻不可编码或持久化失败时抛出。
    public func trimRoomLogs(
        mode: V2RoomLogRetentionMode,
        window: TimeInterval,
        now: Date,
        limit: Int
    ) async throws -> V2RoomLogTrimReport {
        guard limit > 0, window > 0, v2PostgresTimestampCanEncode(now) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let activeSince = v2PostgresPastTimestamp(now: now, interval: window) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        // actor 在等待数据库时可重入；同一实例只允许一轮更新游标。
        guard !isTrimming else { return .init(scannedRooms: 0, trimmedRooms: 0, deletedEvents: 0) }
        isTrimming = true
        defer { isTrimming = false }
        let afterRoomID = lastScannedRoomID
        let result = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let cursorPredicate: SQLQueryString = if let afterRoomID {
                "room_id > \(bind: afterRoomID)"
            } else { "TRUE" }
            // 与房间写入争用同一房间锁；忙碌房间跳过，下轮继续。
            // 先锁定有界房间集，再在新语句快照中计算已读下界，避免并发入群被漏算。
            var locked = try await sql.raw("""
                SELECT room_id FROM im_v2.rooms
                WHERE \(cursorPredicate)
                  AND room_sequence > log_trimmed_through_room_sequence

                ORDER BY room_id
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
                """).all(decoding: RoomLogLockedRow.self)
            if locked.isEmpty, afterRoomID != nil {
                locked = try await sql.raw("""
                    SELECT room_id FROM im_v2.rooms
                    WHERE room_sequence > log_trimmed_through_room_sequence

                    ORDER BY room_id LIMIT \(bind: limit) FOR UPDATE SKIP LOCKED
                    """).all(decoding: RoomLogLockedRow.self)
            }
            let roomIDs = locked.map(\.roomID)
            guard !roomIDs.isEmpty else {
                return (V2RoomLogTrimReport(scannedRooms: 0, trimmedRooms: 0, deletedEvents: 0), UUID?.none)
            }
            let candidates = try await sql.raw("""
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
                                       -- 缺少回执不能证明已读或已过宽限；新单聊和旧成员均需保护。
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
            var trimmedRooms = 0
            var deletedEvents = 0
            for candidate in candidates {
                // 房间序号从 1 开始，因此下界 ≤ 1 意味着"没有任何事件可裁剪"：
                // 此时不推进、也不计入报告，报告里的每一次裁剪都对应真实删除。
                guard candidate.floorSequence > 1,
                      candidate.floorSequence > candidate.trimmedThrough
                else { continue }
                let didAdvance = try await sql.raw("""
                    UPDATE im_v2.rooms
                    SET log_trimmed_through_room_sequence = GREATEST(
                            log_trimmed_through_room_sequence, \(bind: candidate.floorSequence)
                        )
                    WHERE room_id = \(bind: candidate.roomID)
                      AND log_trimmed_through_room_sequence < \(bind: candidate.floorSequence)
                    RETURNING room_id
                    """).first(decoding: RoomLogTrimmedRow.self) != nil
                guard didAdvance else { continue }
                // 只在本事务内声明这是保留裁剪；触发器仍会核对下界。
                try await sql.raw("SET LOCAL im_v2.retention_trim = 'on'").run()
                let removed = try await sql.raw("""
                    WITH removed AS (
                        DELETE FROM im_v2.room_events
                        WHERE room_id = \(bind: candidate.roomID)
                          AND room_sequence < \(bind: candidate.floorSequence)
                        RETURNING event_id
                    )
                    SELECT count(*)::bigint AS count FROM removed
                    """).first(decoding: RoomLogTrimmedRow.self)
                try await sql.raw("SET LOCAL im_v2.retention_trim = 'off'").run()
                trimmedRooms += 1
                deletedEvents += Int(removed?.count ?? 0)
            }
            return (V2RoomLogTrimReport(scannedRooms: candidates.count, trimmedRooms: trimmedRooms, deletedEvents: deletedEvents), roomIDs.last)
        }
        lastScannedRoomID = result.1
        return result.0
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

/// 周期运行房间日志保留裁剪的工作器。
///
/// 永久模式下全部已知读者钉住下界；窗口模式下仅窗口内的回执钉住下界。
/// 当前成员缺少回执时，两种模式都保守地保留历史。两种模式共用同一条路径，避免"配置切换后跑的是另一段代码"。
public struct V2RoomLogRetentionWorker: Sendable {
    private let store: any V2RoomLogRetentionStore
    private let mode: V2RoomLogRetentionMode
    private let window: TimeInterval
    private let now: @Sendable () -> Date

    /// 组合保留存储与判定参数。
    ///
    /// - Parameters:
    ///   - store: 执行裁剪的存储。
    ///   - mode: 保留模式。
    ///   - window: 窗口模式的宽限秒数，需大于零。
    ///   - now: 可注入的当前时刻读取函数。
    public init(
        store: any V2RoomLogRetentionStore,
        mode: V2RoomLogRetentionMode,
        window: TimeInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.mode = mode
        self.window = window
        self.now = now
    }

    /// 运行一轮有界裁剪。
    ///
    /// - Parameter limit: 本轮最多检查的房间数，需大于零。
    /// - Returns: 本轮裁剪结论。
    /// - Throws: 存储实现抛出的错误。
    public func runOnce(limit: Int) async throws -> V2RoomLogTrimReport {
        try await store.trimRoomLogs(mode: mode, window: window, now: now(), limit: limit)
    }
}
