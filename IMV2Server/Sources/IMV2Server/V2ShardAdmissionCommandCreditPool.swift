import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 面向固定双人私聊房间日志路径的分片准入命令窗口额度池。
///
/// PostgreSQL 仍是权威：在该 actor 签发任何令牌之前，整批额度会被原子且不可逆地
/// 计入 `shard_admission_pools`。因此进程崩溃最多保守地浪费一个批次中剩余额度，
/// 绝不会超卖分片窗口。该 actor 刻意不适用于扇出、未完成单元或计划额度，
/// 那些额度的释放生命周期需要按工作项持久化记账。
public actor V2ShardAdmissionCommandCreditPool {
  /// 一次有界微批预留的不可变输入。
  ///
  /// 其中的取值仍只是进程内的建议性状态。每个已签发令牌都已由本 actor 持久化计费，
  /// 且外层消息 SQL 仍会校验租约代次与全部授权修订。
  struct BatchRequest: Sendable {
    let roomShardID: String
    let capacityProfileID: String
    let shardState: ShardAdmissionState
    let now: Date
  }

  /// 一次已签发额度的令牌。
  ///
  /// 标识与键只在模块内部可见，调用方只能原样持有并交回。
  public struct Token: Hashable, Sendable {
    fileprivate let id: UInt64
    fileprivate let key: Key
  }

  /// 额度池运行快照。
  public struct Snapshot: Equatable, Sendable {
    /// 当前可用额度。
    public let activeCredits: Int
    /// 已签发但尚未终结的额度。
    public let inFlightCredits: Int
    /// 批次预留次数。
    public let batchReservations: Int
    /// 已向数据库预留的额度总数。
    public let databaseCreditsReserved: Int
    /// 已提交的额度数。
    public let committedCredits: Int
    /// 已归还的额度数。
    public let returnedCredits: Int
    /// 因过期被丢弃的额度数。
    public let expiredCreditsDiscarded: Int
    /// 因容量不足被拒绝的次数。
    public let capacityRejections: Int
  }

  /// 额度获取结果。
  public enum Acquisition: Sendable {
    /// 已签发额度，并给出扣除在途额度后的有效分片状态。
    case granted(token: Token, effectiveShardState: ShardAdmissionState)
    /// 当前被限流。
    case rateLimited
    /// 准入当前不可用，附带原因。
    case unavailable(V2CommandAdmissionUnavailableReason)
  }

  fileprivate struct Key: Hashable, Sendable {
    let roomShardID: String
    let capacityProfileID: String
    let leaseID: UUID
    let generation: Int64
  }

  private struct Credits: Sendable {
    let reservationID: UInt64
    var available: Int
    var inFlight: Set<UInt64>
    var databaseCommandWindowUsed: Int
    let validUntil: Date
  }

  private struct PendingReservation: Sendable {
    let id: UInt64
    let task: Task<Reservation?, Error>
  }

  private let database: any Database
  private let batchSize: Int
  private var credits: [Key: Credits] = [:]
  private var tokenKeys: [UInt64: Key] = [:]
  private var pendingReservations: [Key: PendingReservation] = [:]
  private var nextInternalID: UInt64 = 0
  private var batchReservations = 0
  private var databaseCreditsReserved = 0
  private var committedCredits = 0
  private var returnedCredits = 0
  private var expiredCreditsDiscarded = 0
  private var capacityRejections = 0

  /// 组合数据库与批量大小。
  ///
  /// - Parameters:
  ///   - database: 执行批量预扣的分片准入数据库。
  ///   - batchSize: 单批额度大小，需落在 `1...128`。
  ///
  /// 批量大小越界时直接失败，避免出现越界预扣。
  public init(database: any Database, batchSize: Int) {
    precondition((1...128).contains(batchSize))
    self.database = database
    self.batchSize = batchSize
  }

  /// 签发一个已计费的分片命令额度。
  ///
  /// 返回的分片状态会扣除本进程尚未提交的额度，使纯计算式的准入评估在不重复计费的前提下
  /// 仍按同一命令窗口不变量判断。
  ///
  /// - Parameters:
  ///   - roomShardID: 目标分片标识。
  ///   - capacityProfileID: 容量档位标识。
  ///   - shardState: 权威的分片准入状态预检快照。
  ///   - now: 服务端统一授时时刻。
  /// - Returns: 额度获取结果。
  /// - Throws: 分片租约或时刻不可解析时抛出
  ///   ``V2ShardAdmissionCommandCreditError/corruptShardState``；
  ///   数据库不支持 SQL 时抛出 ``V2ShardAdmissionCommandCreditError/nonSQLDatabase``。
  public func acquire(
    roomShardID: String,
    capacityProfileID: String,
    shardState: ShardAdmissionState,
    now: Date
  ) async throws -> Acquisition {
    guard let lease = shardState.lease,
      let leaseID = UUID(uuidString: lease.id.rawValue),
      let generation = Int64(exactly: lease.generation)
    else {
      throw V2ShardAdmissionCommandCreditError.corruptShardState
    }
    guard v2PostgresTimestampCanEncode(now), v2PostgresTimestampCanEncode(lease.validUntil) else {
      throw V2ShardAdmissionCommandCreditError.corruptShardState
    }
    guard lease.validUntil > now else {
      return .unavailable(.expiredShardLease)
    }

    let key = Key(
      roomShardID: roomShardID,
      capacityProfileID: capacityProfileID,
      leaseID: leaseID,
      generation: generation
    )
    discardExpiredCredits(now: now)
    if (credits[key]?.available ?? 0) == 0 {
      if let rejection = try await replenishIfNeeded(
        for: key,
        validUntil: lease.validUntil,
        now: now
      ) {
        return rejection
      }
    }
    return try issueCredit(for: key, shardState: shardState, now: now)
  }

  /// 通过一次跨 actor 调用发放一具有界额度。
  ///
  /// 已在 actor 上同步校验并发放预留好的额度。只有当某个键确实需要新的持久批次时，
  /// 该方法才会挂起，而不是每条消息挂起一次。这一区别在持续负载下很重要：
  /// 即使 64 条消息中有 63 条无需任何数据库操作，`await acquire(...)` 循环
  /// 也会为每条消息创建一个串行执行器作业。
  ///
  /// - Parameter requests: 本批次待获取额度的请求，数量上限为 128。
  /// - Returns: 与 `requests` 顺序一致的额度获取结果。
  /// - Throws: 时钟非法或持久预留失败时抛出。
  func acquire(_ requests: [BatchRequest]) async throws -> [Acquisition] {
    precondition(requests.count <= 128)
    guard !requests.isEmpty else { return [] }
    // 在此前的请求预留额度，或清理过程丢弃其他请求的有效预留前，
    // 先拒绝所有无效时钟值。
    guard requests.allSatisfy({ request in
      v2PostgresTimestampCanEncode(request.now)
        && request.shardState.lease.map { v2PostgresTimestampCanEncode($0.validUntil) } == true
    }) else {
      throw V2ShardAdmissionCommandCreditError.corruptShardState
    }
    if let cleanupTime = requests.map(\.now).max() {
      discardExpiredCredits(now: cleanupTime)
    }
    var acquisitions: [Acquisition] = []
    acquisitions.reserveCapacity(requests.count)
    do {
      for request in requests {
        guard let lease = request.shardState.lease,
          let leaseID = UUID(uuidString: lease.id.rawValue),
          let generation = Int64(exactly: lease.generation)
        else {
          throw V2ShardAdmissionCommandCreditError.corruptShardState
        }
        guard lease.validUntil > request.now else {
          acquisitions.append(.unavailable(.expiredShardLease))
          continue
        }
        let key = Key(
          roomShardID: request.roomShardID,
          capacityProfileID: request.capacityProfileID,
          leaseID: leaseID,
          generation: generation
        )
        if (credits[key]?.available ?? 0) == 0 {
          if let rejection = try await replenishIfNeeded(
            for: key,
            validUntil: lease.validUntil,
            now: request.now
          ) {
            acquisitions.append(rejection)
            continue
          }
        }
        acquisitions.append(try issueCredit(
          for: key,
          shardState: request.shardState,
          now: request.now
        ))
      }
      return acquisitions
    } catch {
      // 后续请求抛错时，不能遗留此前已获准请求的进程内执行中令牌。
      // 持久化预留仍保守地保持扣费，与逐条回滚路径一致。
      for (acquisition, request) in zip(acquisitions, requests) {
        guard case .granted(let token, _) = acquisition else { continue }
        release(token, now: request.now)
      }
      throw error
    }
  }

  /// 仅在外层消息事务提交之后终结该令牌。
  ///
  /// 缺失或已过期的条目刻意视为无害：持久化批次已经计费，
  /// 因此容量安全并不依赖这条进程内确认能否跨越进程重启。
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

  /// 以一次 actor 跳转终结一个已提交的消息微批。
  ///
  /// 缺失令牌与 `commit(_:)` 具有同样刻意无害的语义：其持久化容量在签发之前已经计费。
  ///
  /// - Parameter tokens: 本批令牌。
  public func commit(_ tokens: [Token]) {
    for token in tokens { commit(token) }
  }

  /// 结果不明的 COMMIT 可能已消耗此分片额度。
  /// 保留持久化扣费，不退还，也不计为已确认提交。
  func discard(_ token: Token) {
    guard tokenKeys.removeValue(forKey: token.id) != nil,
          var entry = credits[token.key] else { return }
    entry.inFlight.remove(token.id)
    credits[token.key] = entry
    expiredCreditsDiscarded += 1
  }

  /// 归还一个外层事务未提交的令牌。
  ///
  /// 归还是进程内行为；数据库侧整批额度仍保持安全计费。
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
      // 事务已回滚。没有可用时钟时只退役其令牌，
      // 无关额度留待之后有效的检查处理。
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

  /// 批量归还令牌的兼容实现。
  ///
  /// 通过一次 actor 跳转归还一个已回滚的微批。与单令牌路径相同，
  /// 持久预留仍保守地保持已扣费状态。
  ///
  /// - Parameters:
  ///   - tokens: 本批令牌。
  ///   - now: 归还时刻。
  func release(_ tokens: [Token], now: Date) {
    for token in tokens { release(token, now: now) }
  }

  /// 读取当前额度池快照。
  ///
  /// - Returns: 仅含聚合值的统计快照。
  public func snapshot() -> Snapshot {
    .init(
      activeCredits: credits.values.reduce(into: 0) { $0 += $1.available },
      inFlightCredits: tokenKeys.count,
      batchReservations: batchReservations,
      databaseCreditsReserved: databaseCreditsReserved,
      committedCredits: committedCredits,
      returnedCredits: returnedCredits,
      expiredCreditsDiscarded: expiredCreditsDiscarded,
      capacityRejections: capacityRejections
    )
  }

  private func reserveBatchIfNeeded(
    for key: Key,
    now: Date
  ) async throws -> Reservation? {
    let pending: PendingReservation
    if let existing = pendingReservations[key] {
      pending = existing
    } else {
      let reservationID = makeInternalID()
      pending = .init(
        id: reservationID,
        task: Task { [database, batchSize] in
          guard
            let grant = try await Self.reserveBatch(
              database: database,
              key: key,
              batchSize: batchSize,
              now: now
            )
          else { return nil }
          return Reservation(id: reservationID, grant: grant)
        }
      )
      pendingReservations[key] = pending
    }
    do {
      let grant = try await pending.task.value
      finishPendingReservation(pending, for: key, grant: grant)
      return grant
    } catch {
      finishPendingReservation(pending, for: key, grant: nil)
      throw error
    }
  }

  /// 收尾一个已完成的共享预留任务。
  ///
  /// 先恢复执行的等待者必须先注销已完成的共享任务，再返回自己的授予结果。
  /// 若缺少这一交接，另一个等待者可能消耗掉最后一个额度，重新进入
  /// `reserveBatchIfNeeded`，观察到同一个已完成任务并在其旧预留 ID 上同步自旋。
  /// 该自旋会独占本 actor，使最初创建者的 `defer` 永远无法移除该任务——
  /// 在持续负载下形成活锁。
  ///
  /// - Parameters:
  ///   - pending: 待收尾的共享预留任务。
  ///   - key: 该预留所属的键。
  private func finishPendingReservation(
    _ pending: PendingReservation,
    for key: Key,
    grant: Reservation?
  ) {
    guard pendingReservations[key]?.id == pending.id else { return }
    pendingReservations.removeValue(forKey: key)
    if let grant {
      batchReservations += 1
      databaseCreditsReserved += grant.grant.count
    }
  }

  /// 确保 `key` 至少存在一个进程本地额度。
  ///
  /// 常规路径是同步的；actor 每个持久预留批次只让出一次。
  /// 由于可重入调用方可能先消耗掉一个共享授予，
  /// 该循环刻意在每次挂起之后重新检查可用性。
  ///
  /// - Parameters:
  ///   - key: 目标键。
  ///   - validUntil: 本次额度的有效截止时刻。
  ///   - now: 当前时间。
  private func replenishIfNeeded(
    for key: Key,
    validUntil: Date,
    now: Date
  ) async throws -> Acquisition? {
    while (credits[key]?.available ?? 0) == 0 {
      let grant = try await reserveBatchIfNeeded(for: key, now: now)
      guard let grant else {
        let rejection = try await rejection(for: key, now: now)
        if case .rateLimited = rejection { capacityRejections += 1 }
        return rejection
      }
      // 此 Actor 等待共享预留任务时，其他调用方可能先恢复。
      // 绝不能重新安装同一授权，或重置已从中签发的令牌。
      if credits[key]?.reservationID != grant.id {
        credits[key] = .init(
          reservationID: grant.id,
          available: grant.count,
          inFlight: [],
          databaseCommandWindowUsed: grant.databaseCommandWindowUsed,
          validUntil: validUntil
        )
      }
    }
    return nil
  }

  /// 消费一个已预留的额度，且不产生任何挂起点。
  ///
  /// - Parameters:
  ///   - key: 目标键。
  ///   - shardState: 与该额度绑定的分片准入状态。
  ///   - now: 当前时间。
  /// - Returns: 本次额度获取结果。
  /// - Throws: 状态非法或额度不可用时抛出。
  private func issueCredit(
    for key: Key,
    shardState: ShardAdmissionState,
    now: Date
  ) throws -> Acquisition {
    guard var entry = credits[key], entry.validUntil > now, entry.available > 0 else {
      throw V2ShardAdmissionCommandCreditError.corruptCreditState
    }
    let token = Token(id: makeInternalID(), key: key)
    entry.available -= 1
    entry.inFlight.insert(token.id)
    credits[key] = entry
    tokenKeys[token.id] = key
    let effectiveShardState = try effectiveState(
      from: shardState,
      key: key,
      databaseCommandWindowUsed: entry.databaseCommandWindowUsed
    )
    return .granted(token: token, effectiveShardState: effectiveShardState)
  }

  private func discardExpiredCredits(now: Date) {
    let expired = credits.filter { $0.value.validUntil <= now }
    for (key, entry) in expired {
      expiredCreditsDiscarded += entry.available + entry.inFlight.count
      for tokenID in entry.inFlight { tokenKeys.removeValue(forKey: tokenID) }
      credits.removeValue(forKey: key)
    }
  }

  private func makeInternalID() -> UInt64 {
    nextInternalID &+= 1
    precondition(nextInternalID != 0, "shard admission identity exhausted")
    return nextInternalID
  }

  private func effectiveState(
    from shardState: ShardAdmissionState,
    key: Key,
    databaseCommandWindowUsed: Int
  ) throws -> ShardAdmissionState {
    guard let lease = shardState.lease, var entry = credits[key] else {
      throw V2ShardAdmissionCommandCreditError.corruptCreditState
    }
    entry.databaseCommandWindowUsed = max(
      entry.databaseCommandWindowUsed,
      lease.commandWindow.used,
      databaseCommandWindowUsed
    )
    credits[key] = entry
    let uncommitted = entry.available + entry.inFlight.count
    let effectiveUsed = entry.databaseCommandWindowUsed - uncommitted
    guard effectiveUsed >= 0, effectiveUsed <= lease.commandWindow.limit else {
      throw V2ShardAdmissionCommandCreditError.corruptCreditState
    }
    let effectiveLease = try ShardAdmissionLease(
      id: lease.id,
      generation: lease.generation,
      validUntil: lease.validUntil,
      commandWindow: .init(limit: lease.commandWindow.limit, used: effectiveUsed))
    return try .init(
      lease: effectiveLease)
  }

  private func rejection(for key: Key, now: Date) async throws -> Acquisition {
    guard let sql = database as? any SQLDatabase else {
      throw V2ShardAdmissionCommandCreditError.nonSQLDatabase
    }
    guard
      let current = try await sql.raw(
        """
        SELECT lease_id, generation, valid_until
        FROM im_v2.shard_admission_pools
        WHERE room_shard_id = \(bind: key.roomShardID)
          AND capacity_profile_id = \(bind: key.capacityProfileID)
        """
      ).first(decoding: CurrentShardCreditLeaseRow.self)
    else { return .unavailable(.missingShardLease) }
    guard current.leaseID == key.leaseID, current.generation == key.generation else {
      return .unavailable(.missingShardLease)
    }
    guard current.validUntil > now else { return .unavailable(.expiredShardLease) }
    return .rateLimited
  }

  private static func reserveBatch(
    database: any Database,
    key: Key,
    batchSize: Int,
    now: Date
  ) async throws -> DatabaseCreditGrant? {
    guard let sql = database as? any SQLDatabase else {
      throw V2ShardAdmissionCommandCreditError.nonSQLDatabase
    }
    return try await sql.raw(
      """
      WITH candidate AS MATERIALIZED (
          SELECT room_shard_id, capacity_profile_id,
                 LEAST(\(bind: batchSize), command_window_limit - command_window_used)::bigint AS grant_count
          FROM im_v2.shard_admission_pools
          WHERE room_shard_id = \(bind: key.roomShardID)
            AND capacity_profile_id = \(bind: key.capacityProfileID)
            AND lease_id = \(bind: key.leaseID)
            AND generation = \(bind: key.generation)
            AND valid_until > \(bind: now)
            AND command_window_used < command_window_limit
          FOR UPDATE
      ), updated AS (
          UPDATE im_v2.shard_admission_pools AS pool
          SET command_window_used = pool.command_window_used + candidate.grant_count
          FROM candidate
          WHERE pool.room_shard_id = candidate.room_shard_id
            AND pool.capacity_profile_id = candidate.capacity_profile_id
          RETURNING candidate.grant_count, pool.command_window_used
      )
      SELECT grant_count, command_window_used FROM updated
      """
    ).first(decoding: DatabaseCreditGrant.self)
  }
}

/// 分片命令额度池错误。
public enum V2ShardAdmissionCommandCreditError: Error, Sendable {
  /// 数据库句柄不支持 SQL。
  case nonSQLDatabase
  /// 分片租约或时刻无法解析。
  case corruptShardState
  /// 额度内部状态不一致。
  case corruptCreditState
}

private struct DatabaseCreditGrant: Decodable, Sendable {
  let count: Int
  let databaseCommandWindowUsed: Int

  enum CodingKeys: String, CodingKey {
    case count = "grant_count"
    case databaseCommandWindowUsed = "command_window_used"
  }
}

private struct Reservation: Sendable {
  let id: UInt64
  let grant: DatabaseCreditGrant

  var count: Int { grant.count }
  var databaseCommandWindowUsed: Int { grant.databaseCommandWindowUsed }
}

private struct CurrentShardCreditLeaseRow: Decodable, Sendable {
  let leaseID: UUID
  let generation: Int64
  let validUntil: Date

  enum CodingKeys: String, CodingKey {
    case leaseID = "lease_id"
    case generation
    case validUntil = "valid_until"
  }
}
