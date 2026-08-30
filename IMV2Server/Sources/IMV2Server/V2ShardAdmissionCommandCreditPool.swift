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
  /// Immutable input for one bounded micro-batch reservation pass.
  ///
  /// The values remain advisory process-local state. Every issued token was
  /// already durably charged by this actor and the enclosing message SQL still
  /// verifies the lease generation and every authorization revision.
  struct BatchRequest: Sendable {
    let roomShardID: String
    let capacityProfileID: String
    let shardState: ShardAdmissionState
    let now: Date
  }

  public struct Token: Hashable, Sendable {
    fileprivate let id: UInt64
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

  /// Issues a bounded set of credits with one cross-actor call.
  ///
  /// Validates and issues already-reserved credits synchronously on the actor.
  /// The method suspends only when a key actually needs another durable batch,
  /// rather than once per message. This distinction is important at sustained
  /// load: an `await acquire(...)` loop creates one serial-executor job for
  /// every message even when 63 of 64 messages need no database work.
  func acquire(_ requests: [BatchRequest]) async throws -> [Acquisition] {
    precondition(requests.count <= 128)
    guard !requests.isEmpty else { return [] }
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
      // A throwing suffix must not strand process-local in-flight tokens from
      // an already granted prefix. Durable reservations remain conservatively
      // charged, exactly like the scalar rollback path.
      for (acquisition, request) in zip(acquisitions, requests) {
        guard case .granted(let token, _) = acquisition else { continue }
        release(token, now: request.now)
      }
      throw error
    }
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

  /// Returns a rolled-back micro-batch with one actor hop. As with the
  /// single-token path, durable reservations remain conservatively charged.
  func release(_ tokens: [Token], now: Date) {
    for token in tokens { release(token, now: now) }
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

  /// Whichever waiter resumes first retires the completed shared task before
  /// returning its grant. Without this hand-off, another waiter can consume
  /// the last credit, re-enter `reserveBatchIfNeeded`, observe the same
  /// already-completed task and spin synchronously on its old reservation ID.
  /// That spin monopolizes this actor and prevents the original creator's
  /// `defer` from ever removing the task — a sustained-load livelock.
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

  /// Ensures at least one process-local credit exists for `key`. The common
  /// path is synchronous; the actor yields only once per durable reservation
  /// batch. Reentrant callers may consume a shared grant first, so the loop
  /// deliberately rechecks availability after every suspension.
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
      // Another caller can resume first while this actor awaits the shared
      // reservation task. Never reinstall the same grant or reset tokens that
      // have already been issued from it.
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

  /// Consumes one already-reserved credit without any suspension point.
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
