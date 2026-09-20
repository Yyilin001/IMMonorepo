import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 面向固定受众私聊房间日志快速路径的房间命令额度池。
///
/// 它只批量处理房间准入中的命令窗口部分。PostgreSQL 仍是权威：在签发进程内令牌之前，
/// 整批额度会原子计入该房间既有的 `room_admission` 行。因此网关崩溃最多保守地浪费
/// 一个房间批次中未使用的额度，但绝不会让该房间超出持久化窗口的准入量。
/// 分片租约栅栏则防止陈旧额度在房间分片租约被替换后继续存活。
public actor V2RoomAdmissionCommandCreditPool {
  /// 一次追加微批预留的不可变输入。
  ///
  /// 分片状态是权威的预检快照。额度池仍会把每个已签发令牌栅栏到其精确的持久化分片租约；
  /// 该包装只是从热路径上减少每条消息一次跨 actor 调用。
  struct BatchRequest: Sendable {
    let roomID: UUID
    let shardState: ShardAdmissionState
    let now: Date
  }

  /// 一次已签发额度的令牌。
  ///
  /// 令牌标识与键都只在模块内部可见：调用方只能原样持有并交回令牌，
  /// 无法自行构造或改写其归属。
  public struct Token: Hashable, Sendable {
    fileprivate let id: UInt64
    fileprivate let key: Key
  }

  /// 仅包含聚合值的进程内指标。
  ///
  /// 房间标识与租约身份被刻意排除，避免监控本身变成高基数信息的侧信道。
  public struct Snapshot: Equatable, Sendable {
    /// 当前可用额度。
    public let activeCredits: Int
    /// 已签发但尚未提交的额度。
    public let inFlightCredits: Int
    /// 批次预留次数。
    public let batchReservations: Int
    /// 已向数据库预留的额度总数。
    public let databaseCreditsReserved: Int
    /// 已提交的额度数。
    public let committedCredits: Int
    /// 归还的额度数。
    public let returnedCredits: Int
    /// 因过期被丢弃的额度数。
    public let expiredCreditsDiscarded: Int
    /// 因容量不足被拒绝的次数。
    public let capacityRejections: Int
    /// 被提升为热路径的房间数。
    public let promotedHotRooms: Int
  }

  /// 额度获取结果。
  public enum Acquisition: Sendable {
    /// 已签发一个可直接使用的令牌。
    case granted(Token)
    /// 当前被限流。
    case rateLimited
    /// 准入当前不可用，附带原因。
    case unavailable(V2CommandAdmissionUnavailableReason)
  }

  fileprivate struct Key: Hashable, Sendable {
    let roomID: UUID
    let shardLeaseID: UUID
    let shardLeaseGeneration: Int64
  }

  private struct Credits: Sendable {
    let reservationID: UInt64
    var available: Int
    var inFlight: Set<UInt64>
    let validUntil: Date
  }

  private struct Heat: Sendable {
    var committedCount: Int
    var lastCommittedAt: ContinuousClock.Instant
  }

  private let database: any Database
  private let batchSize: Int
  private let monotonicNow: @Sendable () -> ContinuousClock.Instant
  /// 晋升为「已预扣」路径所需的、刚刚提交的普通追加次数阈值。
  ///
  /// 稀疏的单聊会话绝不应为了缓存永远不会用到的额度而多付一次预留事务。
  /// 只有短期窗口内达到该数量的*此前已提交*普通追加的房间，才有资格走预扣路径。
  private let promotionCommitCount = 4
  private let promotionWindow: Duration = .seconds(5)
  private let maximumTrackedRooms = 8_192
  private var credits: [Key: Credits] = [:]
  private var heatByRoom: [UUID: Heat] = [:]
  private var tokenKeys: [UInt64: Key] = [:]
  private var pendingReservations: [Key: Task<Reservation?, Error>] = [:]
  private var nextInternalID: UInt64 = 0
  private var batchReservations = 0
  private var databaseCreditsReserved = 0
  private var committedCredits = 0
  private var returnedCredits = 0
  private var expiredCreditsDiscarded = 0
  private var capacityRejections = 0

  /// 组合数据库、批量大小与单调时钟。
  ///
  /// - Parameters:
  ///   - database: 执行批量预扣的数据库。
  ///   - batchSize: 单批额度大小，需落在 `1...32`。
  ///   - monotonicNow: 可注入的单调时钟读取函数。
  ///
  /// 批量大小越界时直接失败，避免出现越界预扣。
  public init(database: any Database, batchSize: Int,
              monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
    precondition((1...32).contains(batchSize))
    self.database = database
    self.batchSize = batchSize
    self.monotonicNow = monotonicNow
  }

  /// 判断该房间是否已被确认为本进程内的热房间。
  ///
  /// 该判断在 SQL 预检之前执行，使冷房间仍走原有的单事务路径
  /// （`rooms → room_admission`），不产生额外数据库往返。
  /// 热度只依据此前成功提交的消息，绝不依据不可信的请求尝试。
  ///
  /// - Parameters:
  ///   - roomID: 目标房间。
  ///   - now: 当前时刻。
  /// - Returns: 达到提升阈值且热度未过期时为 `true`。
  public func shouldUseCredits(roomID: UUID, now: Date) -> Bool {
    guard v2PostgresTimestampCanEncode(now) else { return false }
    guard let heat = heatByRoom[roomID] else { return false }
    let age = heat.lastCommittedAt.duration(to: monotonicNow())
    guard age >= .zero, age <= promotionWindow else {
      heatByRoom.removeValue(forKey: roomID)
      return false
    }
    return heat.committedCount >= promotionCommitCount
  }

  /// 以一次 actor 进入解析一批房间的热度。
  ///
  /// 结果仍只是进程内热度提示：每条被选中的命令在 PostgreSQL 预检之后
  /// 仍需获取带修订栅栏的持久化房间额度。
  ///
  /// - Parameters:
  ///   - roomIDs: 目标房间列表。
  ///   - now: 当前时刻。
  /// - Returns: 与输入顺序对应的判断结果。
  func shouldUseCredits(roomIDs: [UUID], now: Date) -> [Bool] {
    roomIDs.map { shouldUseCredits(roomID: $0, now: now) }
  }

  /// 记录一次成功提交的普通私聊追加。
  ///
  /// 它与 `commit(_:)` 刻意分开：后者只作用于已预扣的令牌。
  /// 失败、被拒绝与幂等命中的命令都不能提升房间热度。
  ///
  /// - Parameters:
  ///   - roomID: 目标房间。
  ///   - now: 提交时刻。
  public func recordNormalAdmissionCommit(roomID: UUID, now: Date) {
    guard v2PostgresTimestampCanEncode(now) else { return }
    // Heat measures elapsed process time. Wall-clock corrections must not
    // restart or prolong this optimization window.
    let observed = monotonicNow()
    if var heat = heatByRoom[roomID],
       heat.lastCommittedAt.duration(to: observed) >= .zero,
       heat.lastCommittedAt.duration(to: observed) <= promotionWindow {
      heat.committedCount = min(promotionCommitCount, heat.committedCount + 1)
      heat.lastCommittedAt = observed
      heatByRoom[roomID] = heat
      return
    }
    if heatByRoom.count >= maximumTrackedRooms,
       let evicted = heatByRoom.keys.first {
      heatByRoom.removeValue(forKey: evicted)
    }
    heatByRoom[roomID] = .init(committedCount: 1, lastCommittedAt: observed)
  }

  /// 为一次追加获取房间命令额度。
  ///
  /// 获取一个已扣费的房间命令额度。`shardState` 来自同一份为分片额度池服务的持久预检，
  /// 因此房间预留被精确围栏到当前活跃的分片租约上。
  ///
  /// 分片状态必须携带可解析的租约与有效代次，否则视为状态损坏。获取过程会按房间与租约
  /// 复用已预扣的批次额度；无可复用额度时按批量向数据库预扣，
  /// 容量或准入不允许时返回限流或不可用结论。
  ///
  /// - Parameters:
  ///   - roomID: 目标房间。
  ///   - shardState: 权威的分片准入预检快照。
  ///   - now: 服务端统一授时时刻。
  /// - Returns: 获取结果。
  /// - Throws: 分片租约或时刻不可解析时抛出
  ///   ``V2RoomAdmissionCommandCreditError/corruptShardState``；
  ///   数据库不支持 SQL 时抛出 ``V2RoomAdmissionCommandCreditError/nonSQLDatabase``。
  public func acquire(
    roomID: UUID,
    shardState: ShardAdmissionState,
    now: Date
  ) async throws -> Acquisition {
    guard let lease = shardState.lease,
      let leaseID = UUID(uuidString: lease.id.rawValue),
      let generation = Int64(exactly: lease.generation)
    else {
      throw V2RoomAdmissionCommandCreditError.corruptShardState
    }
    guard v2PostgresTimestampCanEncode(now), v2PostgresTimestampCanEncode(lease.validUntil) else {
      throw V2RoomAdmissionCommandCreditError.corruptShardState
    }
    guard lease.validUntil > now else {
      return .unavailable(.expiredShardLease)
    }

    let key = Key(
      roomID: roomID,
      shardLeaseID: leaseID,
      shardLeaseGeneration: generation
    )
    discardExpiredCredits(now: now)

    while (credits[key]?.available ?? 0) == 0 {
      let grant = try await reserveBatchIfNeeded(for: key)
      guard let grant else {
        let rejection = try await rejection(for: key)
        if case .rateLimited = rejection { capacityRejections += 1 }
        return rejection
      }
      // More than one command may await the same database reservation. Never
      // reinstall a grant after a resumed sibling has spent from it.
      if credits[key]?.reservationID != grant.id {
        credits[key] = .init(
          reservationID: grant.id,
          available: grant.count,
          inFlight: [],
          validUntil: lease.validUntil
        )
      }
    }

    guard var entry = credits[key], entry.validUntil > now, entry.available > 0 else {
      throw V2RoomAdmissionCommandCreditError.corruptCreditState
    }
    let token = Token(id: makeInternalID(), key: key)
    entry.available -= 1
    entry.inFlight.insert(token.id)
    credits[key] = entry
    tokenKeys[token.id] = key
    return .granted(token)
  }

  /// 通过一次跨 actor 调用发放一具有界房间额度。
  ///
  /// 若尾部元素抛出，会归还此前本地已发放前缀中的每个令牌。
  /// 持久预留刻意保持已扣费，以保留标量 API 保守的崩溃与重试语义。
  ///
  /// - Parameter requests: 本批次待获取额度的请求，数量上限为 128。
  /// - Returns: 与 `requests` 顺序一致的额度获取结果。
  /// - Throws: 时钟非法或持久预留失败时抛出。
  func acquire(_ requests: [BatchRequest]) async throws -> [Acquisition] {
    precondition(requests.count <= 128)
    guard !requests.isEmpty else { return [] }
    // Reject every invalid clock before a prefix can reserve credits or a
    // cleanup pass can discard a different request's live reservation.
    guard requests.allSatisfy({ request in
      v2PostgresTimestampCanEncode(request.now)
        && request.shardState.lease.map { v2PostgresTimestampCanEncode($0.validUntil) } == true
    }) else {
      throw V2RoomAdmissionCommandCreditError.corruptShardState
    }

    var acquisitions: [Acquisition] = []
    acquisitions.reserveCapacity(requests.count)
    do {
      for request in requests {
        acquisitions.append(try await acquire(
          roomID: request.roomID,
          shardState: request.shardState,
          now: request.now
        ))
      }
      return acquisitions
    } catch {
      for (acquisition, request) in zip(acquisitions, requests) {
        guard case .granted(let token) = acquisition else { continue }
        release(token, now: request.now)
      }
      throw error
    }
  }

  /// 将令牌标记为已提交。
  ///
  /// 只有在包含它的规范消息事务提交之后才可调用。
  /// 未知令牌会被忽略，因此重复提交不会影响额度统计。
  ///
  /// - Parameter token: 已签发的令牌。
  public func commit(_ token: Token) {
    guard tokenKeys.removeValue(forKey: token.id) != nil,
      var entry = credits[token.key]
    else { return }
    entry.inFlight.remove(token.id)
    credits[token.key] = entry
    committedCredits += 1
  }

  /// 批量将令牌标记为已提交。
  ///
  /// 通过一次 actor 跳转收尾一个已提交的房间日志微批。
  ///
  /// - Parameter tokens: 本批令牌。
  public func commit(_ tokens: [Token]) {
    for token in tokens { commit(token) }
  }

  /// 记录一批普通准入提交。
  ///
  /// 在保持已提交消息顺序的同时，避免每次冷房间观察都发生一次 actor 跳转。
  /// 它仍然只是热度提示，绝不授予额度。
  ///
  /// - Parameter observations: 房间标识与其提交时刻组成的观察列表。
  public func recordNormalAdmissionCommits(_ observations: [(UUID, Date)]) {
    for (roomID, now) in observations {
      recordNormalAdmissionCommit(roomID: roomID, now: now)
    }
  }

  /// 归还令牌对应的额度。
  ///
  /// 仅当规范事务未提交时才归还令牌。这仅在进程本地生效；
  /// 持久预留刻意保持已扣费，使崩溃/重试绝不会超卖房间窗口。
  ///
  /// 未知令牌会被忽略。当前时刻不可编码时，事务已回滚，因此会直接退休该批次额度
  /// 而不尝试重新计时。
  ///
  /// - Parameters:
  ///   - token: 已签发的令牌。
  ///   - now: 归还时刻。
  public func release(_ token: Token, now: Date) {
    guard tokenKeys.removeValue(forKey: token.id) != nil,
      var entry = credits[token.key]
    else { return }
    entry.inFlight.remove(token.id)
    if !v2PostgresTimestampCanEncode(now) {
      // The transaction already rolled back. Without a usable clock, retire
      // only its token and leave unrelated credits for a later valid check.
      expiredCreditsDiscarded += 1
      credits[token.key] = entry
    } else if entry.validUntil > now {
      entry.available += 1
      returnedCredits += 1
      credits[token.key] = entry
    } else {
      expiredCreditsDiscarded += 1 + entry.available + entry.inFlight.count
      for tokenID in entry.inFlight { tokenKeys.removeValue(forKey: tokenID) }
      credits.removeValue(forKey: token.key)
    }
  }

  /// 归还一批失败的追加微批，只发生一次 actor 跳转。
  ///
  /// 每个令牌都保留各自的时间，因此即便批次跨越了计时器边界拼装，
  /// 过期行为也与标量路径完全一致。
  ///
  /// - Parameter tokens: 由令牌与其归还时刻组成的列表。
  func release(_ tokens: [(token: Token, now: Date)]) {
    for item in tokens { release(item.token, now: item.now) }
  }

  /// 读取当前额度池快照。
  ///
  /// 读取时会顺带修剪已过期的热度记录。
  ///
  /// - Returns: 仅含聚合值的统计快照。
  public func snapshot() -> Snapshot {
    let observed = monotonicNow()
    heatByRoom = heatByRoom.filter {
      let age = $0.value.lastCommittedAt.duration(to: observed)
      return age >= .zero && age <= promotionWindow
    }
    return .init(
      activeCredits: credits.values.reduce(into: 0) { $0 += $1.available },
      inFlightCredits: tokenKeys.count,
      batchReservations: batchReservations,
      databaseCreditsReserved: databaseCreditsReserved,
      committedCredits: committedCredits,
      returnedCredits: returnedCredits,
      expiredCreditsDiscarded: expiredCreditsDiscarded,
      capacityRejections: capacityRejections,
      promotedHotRooms: heatByRoom.values.filter {
        $0.committedCount >= promotionCommitCount
      }.count
    )
  }

  private func reserveBatchIfNeeded(
    for key: Key
  ) async throws -> Reservation? {
    if let pending = pendingReservations[key] { return try await pending.value }
    let reservationID = makeInternalID()
    let task: Task<Reservation?, Error> = Task { [database, batchSize] in
      guard let grant = try await Self.reserveBatch(
        database: database, key: key, batchSize: batchSize
      ) else { return nil }
      return Reservation(id: reservationID, count: grant)
    }
    pendingReservations[key] = task
    defer { pendingReservations.removeValue(forKey: key) }
    let grant = try await task.value
    if let grant {
      batchReservations += 1
      databaseCreditsReserved += grant.count
    }
    return grant
  }

  private func discardExpiredCredits(now: Date) {
    for (key, entry) in credits where entry.validUntil <= now {
      expiredCreditsDiscarded += entry.available + entry.inFlight.count
      for tokenID in entry.inFlight { tokenKeys.removeValue(forKey: tokenID) }
      credits.removeValue(forKey: key)
    }
  }

  private func makeInternalID() -> UInt64 {
    nextInternalID &+= 1
    precondition(nextInternalID != 0, "room admission identity exhausted")
    return nextInternalID
  }

  private func rejection(for key: Key) async throws -> Acquisition {
    guard let sql = database as? any SQLDatabase else {
      throw V2RoomAdmissionCommandCreditError.nonSQLDatabase
    }
    guard let current = try await sql.raw(
      """
      SELECT admission.shard_lease_id, admission.shard_lease_generation, room.migration_fence_id
      FROM im_v2.room_admission AS admission
      JOIN im_v2.rooms AS room ON room.room_id = admission.room_id
      WHERE admission.room_id = \(bind: key.roomID)
      """
    ).first(decoding: CurrentRoomAdmissionFence.self) else {
      return .unavailable(.missingShardLease)
    }
    guard current.migrationFenceID == nil else { throw V2RoomOwnerFenceError.ownerChanged }
    guard current.shardLeaseID == key.shardLeaseID,
      current.shardLeaseGeneration == key.shardLeaseGeneration
    else { return .unavailable(.missingShardLease) }
    return .rateLimited
  }

  private static func reserveBatch(
    database: any Database,
    key: Key,
    batchSize: Int
  ) async throws -> Int? {
    guard let sql = database as? any SQLDatabase else {
      throw V2RoomAdmissionCommandCreditError.nonSQLDatabase
    }
    // The caller may already hold FOR NO KEY UPDATE while awaiting this
    // independent reservation. KEY SHARE remains compatible with that lock,
    // but conflicts with the migration installer's explicit FOR UPDATE.
    return try await sql.raw(
      """
      WITH writable_room AS MATERIALIZED (
          SELECT room_id FROM im_v2.rooms
          WHERE room_id = \(bind: key.roomID) AND migration_fence_id IS NULL
          FOR KEY SHARE
      ), candidate AS MATERIALIZED (
          SELECT admission.room_id,
                 LEAST(\(bind: batchSize), command_window_limit - command_window_used)::bigint AS grant_count
          FROM im_v2.room_admission AS admission
          JOIN writable_room ON writable_room.room_id = admission.room_id
          WHERE admission.room_id = \(bind: key.roomID)
            AND shard_lease_id = \(bind: key.shardLeaseID)
            AND shard_lease_generation = \(bind: key.shardLeaseGeneration)
            AND command_window_used < command_window_limit
          FOR UPDATE OF admission
      ), updated AS (
          UPDATE im_v2.room_admission AS admission
          SET command_window_used = admission.command_window_used + candidate.grant_count
          FROM candidate
          WHERE admission.room_id = candidate.room_id
          RETURNING candidate.grant_count
      )
      SELECT grant_count FROM updated
      """
    ).first(decoding: RoomAdmissionCreditGrant.self)?.count
  }
}

/// 房间命令额度池错误。
public enum V2RoomAdmissionCommandCreditError: Error, Sendable {
  /// 数据库句柄不支持 SQL。
  case nonSQLDatabase
  /// 分片租约或时刻无法解析。
  case corruptShardState
  /// 额度内部状态不一致。
  case corruptCreditState
}

private struct Reservation: Sendable {
  let id: UInt64
  let count: Int
}

private struct CurrentRoomAdmissionFence: Decodable, Sendable {
  let migrationFenceID: UUID?
  let shardLeaseID: UUID
  let shardLeaseGeneration: Int64

  enum CodingKeys: String, CodingKey {
    case migrationFenceID = "migration_fence_id"
    case shardLeaseID = "shard_lease_id"
    case shardLeaseGeneration = "shard_lease_generation"
  }
}

private struct RoomAdmissionCreditGrant: Decodable, Sendable {
  let count: Int

  enum CodingKeys: String, CodingKey {
    case count = "grant_count"
  }
}
