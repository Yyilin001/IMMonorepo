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
  /// Immutable input for one append micro-batch reservation pass.
  ///
  /// The shard state remains an authoritative preflight snapshot. The pool
  /// still fences every issued token to its exact durable shard lease; this
  /// wrapper only removes one cross-actor job per message from the hot path.
  struct BatchRequest: Sendable {
    let roomID: UUID
    let shardState: ShardAdmissionState
    let now: Date
  }

  public struct Token: Hashable, Sendable {
    fileprivate let id: UInt64
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
    public let promotedHotRooms: Int
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
  /// Sparse direct conversations must never pay an extra reservation
  /// transaction just to cache credits they will never use. Only a room with
  /// this many *previously committed* plain appends in the short window is
  /// eligible for the precharged path.
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

  public init(database: any Database, batchSize: Int,
              monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
    precondition((1...32).contains(batchSize))
    self.database = database
    self.batchSize = batchSize
    self.monotonicNow = monotonicNow
  }

  /// Returns true only for a proven locally hot room. This method is called
  /// before the SQL preflight so cold rooms retain the original single
  /// transaction (`rooms -> room_admission`) path with no extra database
  /// round-trip. Heat is based only on prior committed messages, never on
  /// untrusted request attempts.
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

  /// Resolves one append micro-batch with a single actor entry. This remains
  /// only a process-local heat hint: every selected command still has to
  /// acquire a revision-fenced durable room credit after PostgreSQL preflight.
  func shouldUseCredits(roomIDs: [UUID], now: Date) -> [Bool] {
    roomIDs.map { shouldUseCredits(roomID: $0, now: now) }
  }

  /// Records a successfully committed normal direct append. It is deliberately
  /// separate from `commit(_:)`, which applies only to an already precharged
  /// token. Failed, denied, and idempotent commands cannot promote a room.
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

  /// Issues a bounded set of room credits with one cross-actor call.
  ///
  /// A throwing suffix returns every locally issued prefix token. Durable
  /// reservations intentionally remain charged, preserving the conservative
  /// crash and retry semantics of the scalar API.
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

  /// Call only after the enclosing canonical message transaction commits.
  public func commit(_ token: Token) {
    guard tokenKeys.removeValue(forKey: token.id) != nil,
      var entry = credits[token.key]
    else { return }
    entry.inFlight.remove(token.id)
    credits[token.key] = entry
    committedCredits += 1
  }

  /// Finalizes one already-committed room-log micro-batch in one actor hop.
  public func commit(_ tokens: [Token]) {
    for token in tokens { commit(token) }
  }

  /// Preserves committed message order while avoiding one actor hop per cold
  /// room observation. This remains a heat hint only; it never grants credit.
  public func recordNormalAdmissionCommits(_ observations: [(UUID, Date)]) {
    for (roomID, now) in observations {
      recordNormalAdmissionCommit(roomID: roomID, now: now)
    }
  }

  /// Returns a token if its canonical transaction did not commit. This is
  /// process-local only; the durable reservation intentionally remains
  /// charged so a crash/retry can never oversell the room window.
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

  /// Returns a failed append micro-batch with one actor hop. A distinct time
  /// is retained for every token so expiry behavior exactly matches the scalar
  /// path even when a batch was assembled across a timer boundary.
  func release(_ tokens: [(token: Token, now: Date)]) {
    for item in tokens { release(item.token, now: item.now) }
  }

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
  let id: UInt64
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
