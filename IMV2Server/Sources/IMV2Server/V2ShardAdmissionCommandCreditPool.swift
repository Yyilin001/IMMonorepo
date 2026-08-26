import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Batches the command-window portion of shard admission for the fixed
/// two-member direct room-event-log path.
///
/// PostgreSQL remains the authority: a batch is atomically and irreversibly
/// charged to `shard_admission_pools` before this actor issues any token.
/// Consequently a process crash can only conservatively waste the remaining
/// credits in one batch; it can never oversell a shard window. The actor is
/// intentionally unsuitable for fan-out, outstanding-unit, or plan credits,
/// whose release lifecycle needs durable per-work accounting.
public actor V2ShardAdmissionCommandCreditPool {
  public struct Token: Hashable, Sendable {
    fileprivate let id: UUID
    fileprivate let key: Key
  }

  public struct Snapshot: Equatable, Sendable {
    public let activeCredits: Int
    public let inFlightCredits: Int
    public let batchReservations: Int
    public let databaseCreditsReserved: Int
    public let committedCredits: Int
    public let returnedCredits: Int
    public let expiredCreditsDiscarded: Int
    public let capacityRejections: Int
  }

  public enum Acquisition: Sendable {
    case granted(token: Token, effectiveShardState: ShardAdmissionState)
    case rateLimited
    case unavailable(FanoutAdmissionUnavailableReason)
  }

  fileprivate struct Key: Hashable, Sendable {
    let roomShardID: String
    let capacityProfileID: String
    let leaseID: UUID
    let generation: Int64
  }

  private struct Credits: Sendable {
    let reservationID: UUID
    var available: Int
    var inFlight: Set<UUID>
    var databaseCommandWindowUsed: Int
    let validUntil: Date
  }

  private let database: any Database
  private let batchSize: Int
  private var credits: [Key: Credits] = [:]
  private var tokenKeys: [UUID: Key] = [:]
  private var pendingReservations: [Key: Task<Reservation?, Error>] = [:]
  private var batchReservations = 0
  private var databaseCreditsReserved = 0
  private var committedCredits = 0
  private var returnedCredits = 0
  private var expiredCreditsDiscarded = 0
  private var capacityRejections = 0

  public init(database: any Database, batchSize: Int) {
    precondition((1...128).contains(batchSize))
    self.database = database
    self.batchSize = batchSize
  }

  /// Issues one already-charged command credit. The returned shard state
  /// subtracts this process's uncommitted credits so the pure reducer still
  /// evaluates the same command-window invariant without double charging.
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

    while (credits[key]?.available ?? 0) == 0 {
      let grant = try await reserveBatchIfNeeded(for: key, now: now)
      guard let grant else {
        let rejection = try await rejection(for: key, now: now)
        if case .rateLimited = rejection { capacityRejections += 1 }
        return rejection
      }
      // Another caller can resume first while this actor awaits the
      // shared reservation task. It owns the same grant, so never
      // install it twice or reset credits already issued from it.
      if credits[key]?.reservationID != grant.id {
        credits[key] = .init(
          reservationID: grant.id,
          available: grant.count,
          inFlight: [],
          databaseCommandWindowUsed: grant.databaseCommandWindowUsed,
          validUntil: lease.validUntil
        )
      }
      // If a simultaneous caller spent the whole shared one-credit
      // grant before this caller resumed, loop and reserve the next
      // batch instead of resetting that caller's state.
    }

    guard var entry = credits[key], entry.validUntil > now, entry.available > 0 else {
      throw V2ShardAdmissionCommandCreditError.corruptCreditState
    }
    let token = Token(id: UUID(), key: key)
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

  /// Finalizes a token only after the enclosing message transaction commits.
  /// A missing/expired entry is deliberately harmless: the durable batch was
  /// already charged, and therefore capacity safety does not depend on this
  /// in-memory acknowledgement surviving a process restart.
  public func commit(_ token: Token) {
    guard tokenKeys.removeValue(forKey: token.id) != nil,
      var entry = credits[token.key]
    else { return }
    entry.inFlight.remove(token.id)
    credits[token.key] = entry
    committedCredits += 1
  }

  /// Finalizes one already-committed message micro-batch with a single actor
  /// hop. Missing tokens retain the same deliberately harmless semantics as
  /// `commit(_:)` because their durable capacity was charged before issuance.
  public func commit(_ tokens: [Token]) {
    for token in tokens { commit(token) }
  }

  /// Returns a token whose surrounding transaction did not commit. Returning
  /// it is process-local only; the database batch remains safely charged.
  public func release(_ token: Token, now: Date) {
    guard tokenKeys.removeValue(forKey: token.id) != nil,
      var entry = credits[token.key]
    else { return }
    entry.inFlight.remove(token.id)
    if entry.validUntil > now {
      entry.available += 1
      returnedCredits += 1
      credits[token.key] = entry
    } else {
      expiredCreditsDiscarded += 1
      credits.removeValue(forKey: token.key)
    }
  }

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
    if let pending = pendingReservations[key] {
      return try await pending.value
    }
    let task: Task<Reservation?, Error> = Task { [database, batchSize] in
      guard
        let grant = try await Self.reserveBatch(
          database: database,
          key: key,
          batchSize: batchSize,
          now: now
        )
      else { return nil }
      return Reservation(id: UUID(), grant: grant)
    }
    pendingReservations[key] = task
    defer { pendingReservations.removeValue(forKey: key) }
    let grant = try await task.value
    if let grant {
      batchReservations += 1
      databaseCreditsReserved += grant.grant.count
    }
    return grant
  }

  private func discardExpiredCredits(now: Date) {
    let expired = credits.filter { $0.value.validUntil <= now }
    for (key, entry) in expired {
      expiredCreditsDiscarded += entry.available + entry.inFlight.count
      for tokenID in entry.inFlight { tokenKeys.removeValue(forKey: tokenID) }
      credits.removeValue(forKey: key)
    }
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
      commandWindow: .init(limit: lease.commandWindow.limit, used: effectiveUsed),
      fanoutWindow: lease.fanoutWindow,
      maxOutstandingFanoutUnits: lease.maxOutstandingFanoutUnits,
      maxOutstandingPlans: lease.maxOutstandingPlans
    )
    return try .init(
      lease: effectiveLease,
      outstandingFanoutUnits: shardState.outstandingFanoutUnits,
      outstandingPlans: shardState.outstandingPlans
    )
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

public enum V2ShardAdmissionCommandCreditError: Error, Sendable {
  case nonSQLDatabase
  case corruptShardState
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
  let id: UUID
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
