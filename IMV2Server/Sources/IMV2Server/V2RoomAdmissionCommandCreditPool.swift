import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Batches only the command-window portion of per-room admission for the
/// fixed-audience direct room-event-log fast path.
///
/// PostgreSQL remains authoritative. A batch is charged atomically to the
/// room's existing `room_admission` row before a process-local token is
/// issued. A Gateway crash can therefore conservatively waste unused credits
/// from one room batch, but cannot admit more commands than that room's
/// durable window. The shard-lease fence prevents stale credits surviving a
/// room's shard lease replacement.
public actor V2RoomAdmissionCommandCreditPool {
  public struct Token: Hashable, Sendable {
    fileprivate let id: UUID
    fileprivate let key: Key
  }

  /// Aggregate-only process metrics. Room IDs and lease identities are
  /// intentionally excluded so monitoring cannot become a high-cardinality
  /// side channel.
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
    case granted(Token)
    case rateLimited
    case unavailable(FanoutAdmissionUnavailableReason)
  }

  fileprivate struct Key: Hashable, Sendable {
    let roomID: UUID
    let shardLeaseID: UUID
    let shardLeaseGeneration: Int64
  }

  private struct Credits: Sendable {
    let reservationID: UUID
    var available: Int
    var inFlight: Set<UUID>
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
    precondition((1...32).contains(batchSize))
    self.database = database
    self.batchSize = batchSize
  }

  /// Acquires one already-charged room command credit. `shardState` comes
  /// from the same durable preflight that feeds the shard credit pool, so the
  /// room reservation is fenced to the exact active shard lease.
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
    let token = Token(id: UUID(), key: key)
    entry.available -= 1
    entry.inFlight.insert(token.id)
    credits[key] = entry
    tokenKeys[token.id] = key
    return .granted(token)
  }

  /// Call only after the enclosing canonical message transaction commits.
  public func commit(_ token: Token) {
    guard tokenKeys.removeValue(forKey: token.id) != nil,
      var entry = credits[token.key]
    else { return }
    entry.inFlight.remove(token.id)
    credits[token.key] = entry
    committedCredits += 1
  }

  /// Returns a token if its canonical transaction did not commit. This is
  /// process-local only; the durable reservation intentionally remains
  /// charged so a crash/retry can never oversell the room window.
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
    for key: Key
  ) async throws -> Reservation? {
    if let pending = pendingReservations[key] { return try await pending.value }
    let task: Task<Reservation?, Error> = Task { [database, batchSize] in
      guard let grant = try await Self.reserveBatch(
        database: database, key: key, batchSize: batchSize
      ) else { return nil }
      return Reservation(id: UUID(), count: grant)
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

  private func rejection(for key: Key) async throws -> Acquisition {
    guard let sql = database as? any SQLDatabase else {
      throw V2RoomAdmissionCommandCreditError.nonSQLDatabase
    }
    guard let current = try await sql.raw(
      """
      SELECT shard_lease_id, shard_lease_generation
      FROM im_v2.room_admission
      WHERE room_id = \(bind: key.roomID)
      """
    ).first(decoding: CurrentRoomAdmissionFence.self) else {
      return .unavailable(.missingShardLease)
    }
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
    return try await sql.raw(
      """
      WITH candidate AS MATERIALIZED (
          SELECT room_id,
                 LEAST(\(bind: batchSize), command_window_limit - command_window_used)::bigint AS grant_count
          FROM im_v2.room_admission
          WHERE room_id = \(bind: key.roomID)
            AND shard_lease_id = \(bind: key.shardLeaseID)
            AND shard_lease_generation = \(bind: key.shardLeaseGeneration)
            AND command_window_used < command_window_limit
          FOR UPDATE
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

public enum V2RoomAdmissionCommandCreditError: Error, Sendable {
  case nonSQLDatabase
  case corruptShardState
  case corruptCreditState
}

private struct Reservation: Sendable {
  let id: UUID
  let count: Int
}

private struct CurrentRoomAdmissionFence: Decodable, Sendable {
  let shardLeaseID: UUID
  let shardLeaseGeneration: Int64

  enum CodingKeys: String, CodingKey {
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
