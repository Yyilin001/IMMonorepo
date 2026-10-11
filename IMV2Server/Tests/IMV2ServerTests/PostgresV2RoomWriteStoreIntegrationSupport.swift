@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import HTTPTypes
#if os(macOS)
import Darwin
#endif
import IMV2Core
import IMV2ServerHTTP
import PostgresNIO
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing
import Vapor
import VaporTesting


internal struct RevocationClockDateRow: Decodable {
    let value: Date
}
enum SummaryFixtureStorage {
    case roomEvent
    case messageRow
}

func insertSummaryFixtureRoom(
    on sql: any SQLDatabase,
    room: UUID,
    kind: String,
    sequence: Int64,
    revision: Int64,
    lastEventAt: Date,
    createdAt: Date
) async throws {
    try await sql.raw("""
        INSERT INTO im_v2.rooms
            (room_id, room_kind, room_shard_id, room_sequence, membership_revision,
             capacity_profile_id, created_at, last_event_at)
        VALUES (\(bind: room), \(bind: kind), 'room-a', \(bind: sequence), \(bind: revision),
                'standard', \(bind: createdAt), \(bind: lastEventAt))
        """).run()
}

func insertSummaryFixtureMembership(
    on sql: any SQLDatabase,
    room: UUID,
    user: UUID,
    joined: Int64,
    left: Int64?
) async throws {
    try await sql.raw("""
        INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision, left_revision)
        VALUES (\(bind: room), \(bind: user), 'member', \(bind: joined), \(bind: left))
        """).run()
}

func insertSummaryFixtureReadReceipt(
    on sql: any SQLDatabase,
    room: UUID,
    user: UUID,
    readThrough: Int64,
    at: Date
) async throws {
    try await sql.raw("""
        INSERT INTO im_v2.room_read_receipts (room_id, user_id, read_through_room_sequence, updated_at)
        VALUES (\(bind: room), \(bind: user), \(bind: readThrough), \(bind: at))
        """).run()
}

func insertSummaryFixtureMediaObject(
    on sql: any SQLDatabase,
    media: UUID,
    owner: UUID,
    at: Date
) async throws {
    try await sql.raw("""
        INSERT INTO im_v2.media_objects
            (media_id, owner_user_id, content_type, byte_count, state,
             upload_session_id, expires_at, state_updated_at, created_at)
        VALUES (\(bind: media), \(bind: owner), 'image/jpeg', 1, 'available',
                \(bind: UUID()), \(bind: at), \(bind: at), \(bind: at))
        """).run()
}

func insertSummaryFixtureRoomEvent(
    on sql: any SQLDatabase,
    room: UUID,
    sequence: Int64,
    revision: Int64,
    message: UUID,
    createdAt: Date
) async throws {
    try await sql.raw("""
        INSERT INTO im_v2.room_events
            (event_id, room_id, room_sequence, event_type, actor_user_id, payload,
             committed_membership_revision, created_at)
        VALUES (\(bind: UUID()), \(bind: room), \(bind: sequence), 'message.accepted', \(bind: UUID()),
                jsonb_build_object('event_type', 'message.accepted',
                                   'message_id', \(bind: message.uuidString)),
                \(bind: revision), \(bind: createdAt))
        """).run()
}

/// 插入一条消息行。
///
/// - Returns: 该行使用的客户端消息标识；构造接受完成记录时必须复用它，
///   否则共享的可见性谓词无法把完成事实与实际消息行对上。
@discardableResult
func insertSummaryFixtureMessage(
    on sql: any SQLDatabase,
    room: UUID,
    message: UUID,
    sender: UUID,
    roomSequence: Int64,
    timelineSequence: Int64,
    text: String,
    createdAt: Date,
    storage: SummaryFixtureStorage,
    revision: Int64?,
    withdrawnAt: Date? = nil
) async throws -> UUID {
    let acceptedEventID: UUID? = storage == .messageRow ? UUID() : nil
    let withdrawnBy: UUID? = withdrawnAt == nil ? nil : sender
    let clientMessageID = UUID()
    try await sql.raw("""
        INSERT INTO im_v2.messages
            (message_id, room_id, room_sequence, sender_user_id, client_message_id, text_body,
             created_at, timeline_sequence, accepted_event_id, accepted_event_storage,
             accepted_membership_revision, withdrawn_at, withdrawn_by_user_id)
        VALUES (\(bind: message), \(bind: room), \(bind: roomSequence), \(bind: sender), \(bind: clientMessageID),
                \(bind: text), \(bind: createdAt), \(bind: timelineSequence), \(bind: acceptedEventID),
                \(bind: storage == .messageRow ? "message_row" : "room_event"), \(bind: revision),
                \(bind: withdrawnAt), \(bind: withdrawnBy))
        """).run()
    return clientMessageID
}

func postgresStatements(in source: String) -> [String] {
    var statements: [String] = []
    var buffer = ""
    var dollarQuote: String?
    var quote: Character?
    var index = source.startIndex
    while index < source.endIndex {
        let character = source[index]
        let next = source.index(after: index)
        if let active = quote {
            buffer.append(character)
            if character == active {
                if next < source.endIndex, source[next] == active {
                    buffer.append(active)
                    index = source.index(after: next)
                    continue
                }
                quote = nil
            }
            index = next
            continue
        }
        if dollarQuote == nil {
            if source[index...].hasPrefix("--") {
                index = source[index...].firstIndex(of: "\n") ?? source.endIndex
                buffer.append("\n")
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                buffer.append(character)
                index = next
                continue
            }
        }
        if character == "$" {
            let remainder = source[index...]
            if let closing = remainder.dropFirst().firstIndex(of: "$") {
                let tag = String(remainder[...closing])
                let isDollarTag = tag.dropFirst().dropLast().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
                if isDollarTag && (dollarQuote == nil || dollarQuote == tag) {
                    dollarQuote = dollarQuote == nil ? tag : nil
                    buffer.append(contentsOf: tag)
                    index = source.index(after: closing)
                    continue
                }
            }
        }
        if character == ";", dollarQuote == nil {
            let statement = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !statement.isEmpty { statements.append(statement) }
            buffer = ""
        } else {
            buffer.append(character)
        }
        index = next
    }
    let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { statements.append(tail) }
    return statements
}

internal let roomUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
internal let senderUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
internal let clientUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
internal let leaseUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
internal let memberTwoUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
internal let memberThreeUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000016")!
internal let roomID = try! RoomID(roomUUID.uuidString)
internal let senderID = try! UserID(senderUUID.uuidString)
internal let clientMessageID = try! ClientMessageID(clientUUID.uuidString)
internal let deviceID = try! DeviceID("00000000-0000-0000-0000-000000000017")
internal let snapshotID = try! SnapshotID("00000000-0000-0000-0000-000000000018")
private struct ConcurrentRoomWriteAcceptanceResult: Sendable {
    let outcome: V2SendMessageOutcome
    let elapsedSeconds: TimeInterval
}

/// Coordinates the four test workers by durable commits rather than by a
/// fixed number of empty polls. This keeps the measured delivery wall time
/// comparable when the lease-claim budget changes.

/// One privacy-safe, machine-readable summary for the opt-in 100k drain.
/// It contains only aggregate stage duration and worker distribution facts;
/// no room, source event, target user or payload reaches test output.

/// Test-only aggregation for the cross-store ceiling profile. The production
/// store exposes only anonymous batch durations; this actor turns them into a
/// single machine-readable line without collecting room, event, user or
/// payload data.

internal func v2LocalElapsedMilliseconds(since startedAt: Date, now: Date = Date()) -> Int {
    max(0, Int((now.timeIntervalSince(startedAt) * 1_000).rounded()))
}

/// A compact local workload summary. Nearest-rank percentiles deliberately
/// avoid interpolation: this is a small 16-sample regression report, not a
/// statistically significant production latency distribution.
private struct V2LocalLatencySummary {
    let p50Milliseconds: Int
    let p95Milliseconds: Int
    let p99Milliseconds: Int

    init(samples: [TimeInterval]) {
        precondition(!samples.isEmpty)
        let sorted = samples.sorted()
        p50Milliseconds = Self.milliseconds(Self.nearestRank(sorted, percentile: 0.50))
        p95Milliseconds = Self.milliseconds(Self.nearestRank(sorted, percentile: 0.95))
        p99Milliseconds = Self.milliseconds(Self.nearestRank(sorted, percentile: 0.99))
    }

    private static func nearestRank(_ sorted: [TimeInterval], percentile: Double) -> TimeInterval {
        let index = max(0, min(sorted.count - 1, Int(ceil(percentile * Double(sorted.count))) - 1))
        return sorted[index]
    }

    private static func milliseconds(_ value: TimeInterval) -> Int {
        Int((value * 1_000).rounded())
    }
}

/// Deliberately broad local regression limits for the isolated Docker
/// baseline. They catch order-of-magnitude regressions while remaining
/// overrideable on a differently provisioned local machine; they are never a
/// production SLO or admission policy.
private struct V2LocalCapacityRegressionLimits {
    let maximumAcceptanceP99Milliseconds: Int
    let maximumPipelineWallMilliseconds: Int

    init() throws {
        maximumAcceptanceP99Milliseconds = try Self.read(
            "IMV2_LOCAL_CAPACITY_MAX_ACCEPTANCE_P99_MS", defaultValue: 250
        )
        maximumPipelineWallMilliseconds = try Self.read(
            "IMV2_LOCAL_CAPACITY_MAX_PIPELINE_WALL_MS", defaultValue: 60_000
        )
    }

    private static func read(_ name: String, defaultValue: Int) throws -> Int {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return defaultValue }
        guard let value = Int(raw), value > 0 else {
            throw TestConfigurationError.invalidLocalCapacityLimit(name)
        }
        return value
    }
}

/// Bounded shape controls for the opt-in concurrent-room capacity regression.
/// A standard group is intentionally capped at 5,000 members by the product
/// design, so a local test must not silently exercise a different delivery
/// mode by accepting a larger value here. The default remains the fast 16k
/// projection smoke workload; the 5,000-member case is explicitly opt-in.
private struct V2ConcurrentRoomWorkloadConfiguration {
    let messageCount: Int
    let memberCount: Int
    let plannerPageSize: Int
    let deliveryClaimBatchSize: Int
    let deliveryWorkerCount: Int
    /// Test-only body size used to measure the cost of copying an immutable
    /// event payload into each recipient's durable sync log. Zero keeps the
    /// ordinary short-message workload.
    let eventPayloadBytes: Int
    let forceGenericProjectionSequenceReservation: Bool

    init() throws {
        messageCount = try Self.read(
            "IMV2_CONCURRENT_ROOM_MESSAGE_COUNT", defaultValue: 16, range: 1...64
        )
        memberCount = try Self.read(
            "IMV2_CONCURRENT_ROOM_MEMBER_COUNT", defaultValue: 1_000, range: 1...5_000
        )
        plannerPageSize = try Self.read(
            "IMV2_CONCURRENT_ROOM_PLANNER_PAGE_SIZE", defaultValue: 1_000, range: 1...5_000
        )
        deliveryClaimBatchSize = try Self.read(
            "IMV2_CONCURRENT_ROOM_DELIVERY_CLAIM_BATCH_SIZE", defaultValue: 2_000, range: 1...2_000
        )
        deliveryWorkerCount = try Self.read(
            "IMV2_CONCURRENT_ROOM_DELIVERY_WORKER_COUNT", defaultValue: 4, range: 1...16
        )
        eventPayloadBytes = try Self.read(
            "IMV2_CONCURRENT_ROOM_EVENT_PAYLOAD_BYTES", defaultValue: 0, range: 0...16_384
        )
        forceGenericProjectionSequenceReservation = ProcessInfo.processInfo.environment["IMV2_FORCE_GENERIC_PROJECTION_SEQUENCE_RESERVATION"] == "1"
    }

    private static func read(_ name: String, defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return defaultValue }
        guard let value = Int(raw), range.contains(value) else {
            throw TestConfigurationError.invalidConcurrentRoomWorkloadValue(name)
        }
        return value
    }
}

/// Produces deterministic printable ASCII with low repetition, so a payload
/// profile measures the stored event-copy path rather than benefiting from an
/// artificial all-zero string's compression ratio. This is test-only and
/// never accepts a payload from an environment variable directly.
private func v2ConcurrentRoomMessageText(index: Int, payloadBytes: Int) -> String {
    guard payloadBytes > 0 else { return "burst-\(index)" }
    var state = UInt64(index) &+ 1
    var bytes: [UInt8] = []
    bytes.reserveCapacity(payloadBytes)
    for _ in 0..<payloadBytes {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        bytes.append(33 + UInt8(truncatingIfNeeded: state >> 57) % 94)
    }
    // The generated range is printable ASCII, so this conversion cannot fail.
    return String(bytes: bytes, encoding: .ascii)!
}

/// Optional PostgreSQL attribution for the concurrent-room regression. It is
/// deliberately a test-only diagnostic: production code neither requires the
/// extension nor has permission to reset its shared statement statistics.
///
/// Enable it only with the local `capacity-profile` compose overlay and
/// `IMV2_CAPTURE_POSTGRES_DELIVERY_PROFILE=1`. The output uses stable
/// categories rather than SQL text, keeping it both privacy-safe and easy to
/// compare between local runs.
private struct V2LocalPostgresDatabaseCounters: Decodable {
    let xactCommit: Int64
    let xactRollback: Int64
    let tempBytes: Int64
    let blkReadTime: Double
    let blkWriteTime: Double

    enum CodingKeys: String, CodingKey {
        case xactCommit = "xact_commit"
        case xactRollback = "xact_rollback"
        case tempBytes = "temp_bytes"
        case blkReadTime = "blk_read_time"
        case blkWriteTime = "blk_write_time"
    }

    func subtracting(_ other: Self) -> Self {
        .init(
            xactCommit: xactCommit - other.xactCommit,
            xactRollback: xactRollback - other.xactRollback,
            tempBytes: tempBytes - other.tempBytes,
            blkReadTime: blkReadTime - other.blkReadTime,
            blkWriteTime: blkWriteTime - other.blkWriteTime
        )
    }

    var blkReadMilliseconds: Int { Int(blkReadTime.rounded()) }
    var blkWriteMilliseconds: Int { Int(blkWriteTime.rounded()) }
}

private struct V2LocalPostgresWALCounters: Decodable {
    let walRecords: Int64
    let walFPI: Int64
    let walBytes: Int64
    let walLSN: String

    enum CodingKeys: String, CodingKey {
        case walRecords = "wal_records"
        case walFPI = "wal_fpi"
        case walBytes = "wal_bytes"
        case walLSN = "wal_lsn"
    }

    func subtracting(_ other: Self) -> Self {
        .init(
            walRecords: walRecords - other.walRecords,
            walFPI: walFPI - other.walFPI,
            walBytes: walBytes - other.walBytes,
            walLSN: walLSN
        )
    }
}

private struct V2LocalPostgresStatementProfile: Decodable {
    let category: String
    let calls: Int64
    let totalExecMilliseconds: Double
    let meanExecMilliseconds: Double
    let rows: Int64
    let sharedBlocksHit: Int64
    let sharedBlocksRead: Int64
    let sharedBlocksDirtied: Int64
    let sharedBlocksWritten: Int64
    let tempBlocksRead: Int64
    let tempBlocksWritten: Int64
    let walBytes: Int64

    enum CodingKeys: String, CodingKey {
        case category, calls, rows
        case totalExecMilliseconds = "total_exec_ms"
        case meanExecMilliseconds = "mean_exec_ms"
        case sharedBlocksHit = "shared_blks_hit"
        case sharedBlocksRead = "shared_blks_read"
        case sharedBlocksDirtied = "shared_blks_dirtied"
        case sharedBlocksWritten = "shared_blks_written"
        case tempBlocksRead = "temp_blks_read"
        case tempBlocksWritten = "temp_blks_written"
        case walBytes = "wal_bytes"
    }
}

private enum PlannerInterruption: Error { case afterFirstCheckpoint }

/// Deterministically fails on the second UUID-sorted seeded member. The first
/// page therefore commits before this throws, which models a planner process
/// disappearing between independently durable enumeration transactions.
private struct FailsOnSecondPageRouter: V2UserShardRouter {
    let blockedUserID: UserID

    func routes(for users: [UserID]) async throws -> [V2UserShardRoute] {
        if users.contains(blockedUserID) { throw PlannerInterruption.afterFirstCheckpoint }
        return Array(repeating: try .init(bucket: "test-users", observedRouterEpoch: 9), count: users.count)
    }
}

internal final class TestSequenceClock: Sendable {
    private let state: Mutex<([Date], Int)>
    init(_ values: [Date]) {
        precondition(!values.isEmpty)
        state = Mutex((values, 0))
    }
    func set(_ values: [Date]) {
        precondition(!values.isEmpty)
        state.withLock { $0 = (values, 0) }
    }
    func now() -> Date {
        state.withLock { value in
            let result = value.0[value.1]
            value.1 = min(value.1 + 1, value.0.count - 1)
            return result
        }
    }
}


private struct TransferCursorAssertionRow: Decodable {
    let acknowledgedSequence: Int64
    enum CodingKeys: String, CodingKey { case acknowledgedSequence = "acknowledged_sequence" }
}
internal struct ExistsRow: Decodable { let exists: Bool }

private struct BatchReplayAuditRow: Decodable {
    let targetUserID: UUID?
    let projectionKind: String?
    let outcome: String
    enum CodingKeys: String, CodingKey {
        case targetUserID = "target_user_id", projectionKind = "projection_kind", outcome
    }
}

internal struct StringValueRow: Decodable { let value: String }

internal struct CountRow: Decodable { let value: Int64 }
internal struct DirectPairProjectionStateAssertionRow: Decodable, Equatable {
    let lowerProfileVisibleToHigher: Bool
    let higherProfileVisibleToLower: Bool
    let lowerCanSend: Bool?
    let higherCanSend: Bool?
    enum CodingKeys: String, CodingKey {
        case lowerProfileVisibleToHigher = "lower_profile_visible_to_higher"
        case higherProfileVisibleToLower = "higher_profile_visible_to_lower"
        case lowerCanSend = "lower_can_send"
        case higherCanSend = "higher_can_send"
    }
}
internal actor PostgreSQLTransactionGate {
    private var isHeld = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilHeld() async {
        guard !isHeld else { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func holdTransaction() async {
        isHeld = true
        let waiters = heldWaiters
        heldWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func releaseTransaction() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

internal func waitForAdvisoryWaiters(_ expected: Int64, on sql: any SQLDatabase) async throws {
    try await waitForPostgreSQLLockWaiters(expected, lockType: "advisory", on: sql)
}

internal func waitForPostgreSQLLockWaiters(
    _ expected: Int64,
    lockType: String,
    on sql: any SQLDatabase
) async throws {
    for _ in 0 ..< 300 {
        let count = try await sql.raw("""
            SELECT COUNT(*)::bigint AS value
            FROM pg_locks
            WHERE locktype = \(bind: lockType) AND NOT granted
            """).first(decoding: CountRow.self)?.value ?? 0
        if count >= expected { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestConfigurationError.lockWaiterTimeout(lockType)
}

private struct FanoutTerminalLatencyRow: Decodable {
    let elapsedSeconds: TimeInterval
    enum CodingKeys: String, CodingKey { case elapsedSeconds = "elapsed_seconds" }
}
private struct HybridPlanAssertionRow: Decodable, Equatable {
    let roomSequence: Int64
    let state: String
    let targetCount: Int
    let reservedFanoutCost: Int
    enum CodingKeys: String, CodingKey {
        case roomSequence = "source_room_sequence"
        case state
        case targetCount = "target_count"
        case reservedFanoutCost = "reserved_fanout_cost"
    }
}
private struct FanoutScaleAccountingRow: Decodable {
    let completionUnits: Int64
    let completionTargets: Int64
    let deliveries: Int64
    let distinctDeliveries: Int64
    let planState: String
    enum CodingKeys: String, CodingKey {
        case completionUnits = "completion_units"
        case completionTargets = "completion_targets"
        case deliveries
        case distinctDeliveries = "distinct_deliveries"
        case planState = "plan_state"
    }
}

private struct FanoutDeliveryScaleAccountingRow: Decodable {
    let syncRecords: Int64
    let distinctSyncRecipients: Int64
    let inboxRecords: Int64
    let terminalDeliveries: Int64
    let releasedCompletionUnits: Int64
    let planState: String
    enum CodingKeys: String, CodingKey {
        case syncRecords = "sync_records"
        case distinctSyncRecipients = "distinct_sync_recipients"
        case inboxRecords = "inbox_records"
        case terminalDeliveries = "terminal_deliveries"
        case releasedCompletionUnits = "released_completion_units"
        case planState = "plan_state"
    }
}
private struct FanoutDeliveryRetryAccountingRow: Decodable {
    let retriedDeliveries: Int64
    let maximumRetryCount: Int64
    enum CodingKeys: String, CodingKey {
        case retriedDeliveries = "retried_deliveries"
        case maximumRetryCount = "maximum_retry_count"
    }
}
internal struct CapacityRow: Decodable {
    let commandWindowUsed: Int
    enum CodingKeys: String, CodingKey { case commandWindowUsed = "command_window_used" }
}
private struct PlanningCheckpointAssertionRow: Decodable {
    let state: String
    let afterUserID: String?
    enum CodingKeys: String, CodingKey {
        case state
        case afterUserID = "after_user_id"
    }
}
private struct FanoutRouteAssertionRow: Decodable {
    let bucket: String
    let epoch: Int64
    enum CodingKeys: String, CodingKey {
        case bucket = "target_shard_bucket"
        case epoch = "observed_router_epoch"
    }
}
private struct DeliveryRouteRow: Decodable, Equatable {
    let bucket: String
    let epoch: Int64
    enum CodingKeys: String, CodingKey { case bucket = "target_shard_bucket", epoch = "observed_router_epoch" }
}
private struct HandoffRouteRow: Decodable {
    let bucket: String
    let epoch: Int64
    let unclaimed: Bool
    enum CodingKeys: String, CodingKey {
        case bucket = "target_shard_bucket"
        case epoch = "observed_router_epoch"
        case unclaimed
    }
}

internal struct EditMessageStateRow: Decodable {
    let text: String; let revision: Int64
    enum CodingKeys: String, CodingKey { case text = "text_body", revision = "content_revision" }
}
internal struct PushStateRow: Decodable { let state: String }
internal struct HousekeepingCursorAssertionRow: Decodable {
    let state: String
    let acknowledgedSequence: Int64
    let pendingSnapshotID: UUID?
    enum CodingKeys: String, CodingKey {
        case state
        case acknowledgedSequence = "acknowledged_sequence"
        case pendingSnapshotID = "pending_snapshot_id"
    }
}
private struct PayloadLaneCountRow: Decodable, Equatable {
    let payloadLane: String
    let entryCount: Int64

    enum CodingKeys: String, CodingKey {
        case payloadLane = "payload_lane"
        case entryCount = "entry_count"
    }
}
internal struct ProfilePropagationProjectionRow: Decodable {
    let userID: UUID
    let roomID: String
    let displayName: String
    let revision: Int64
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case roomID = "room_id"
        case displayName = "display_name"
        case revision
    }
}
internal struct SuccessfulProjectionDelivery: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(
        userID _: UserID,
        sourceEventID _: EventID,
        projectionKinds _: Set<String>
    ) async throws -> UInt64? { 1 }
}
private actor RecordingProjectionDelivery: V2UserShardProjectionDelivering {
    private var requests = 0

    func deliverToCurrentShard(
        userID _: UserID,
        sourceEventID _: EventID,
        projectionKinds _: Set<String>
    ) async throws -> UInt64? {
        requests += 1
        return 1
    }

    func requestCount() -> Int { requests }
}
internal enum ProfilePropagationShadowFailure: Error, Equatable, Sendable { case interrupted }
private struct TerminalOutboxStateRow: Decodable {
    let state: String
    let terminalized: Bool
}
private struct SyncedMessagePayloadRow: Decodable {
    let roomID: String
    let messageID: String
    let senderUserID: String
    let text: String
    let eventType: String
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case messageID = "message_id"
        case senderUserID = "sender_user_id"
        case text
        case eventType = "event_type"
    }
}
internal struct MediaReferenceAssertionRow: Decodable {
    let messageID: UUID
    let mediaID: UUID
    let ordinal: Int
    enum CodingKeys: String, CodingKey { case messageID = "message_id", mediaID = "media_id", ordinal }
}
internal struct ModerationAuditAssertionRow: Decodable { let action: String; let reasonCode: String; enum CodingKeys: String, CodingKey { case action; case reasonCode = "reason_code" } }
private struct FreezeProjectionRow: Decodable { let projectionKind: String; let eventType: String; enum CodingKeys: String, CodingKey { case projectionKind = "projection_kind", eventType = "event_type" } }
private struct ModerationDeliveredEventRow: Decodable { let eventType: String; enum CodingKeys: String, CodingKey { case eventType = "event_type" } }
internal enum TestConfigurationError: Error {
    case schemaAlreadyExists
    case invalidLocalCapacityLimit(String)
    case invalidFanoutCommitBatchSize(String)
    case invalidFanoutDeliveryClaimBatchSize(String)
    case invalidFanoutPlannerPageSize(String)
    case invalidConcurrentRoomWorkloadValue(String)
    case invalidCrossStoreDeliveryConcurrency(String)
    case invalidCrossStoreCommitBatchSize(String)
    case invalidCrossStoreBatchCommitConcurrency(String)
    case invalidCrossStoreEventPayloadBytes(String)
    case postgresProfileUnavailable
    case lockWaiterTimeout(String)
}

internal struct ForwardInboxUUIDAssertion: Decodable { let value: UUID }

internal struct ForwardImportDigestAssertion: Decodable { let value: String }
internal actor ForwardMediaFailOnceScanner: V2MediaScanProvider {
    let scanner: any V2MediaScanProvider
    /// 首次扫描抛出确定性失败，使导入工作进入暂停而不是持续重试。
    ///
    /// 瞬时失败在新契约下不再因预算耗尽而暂停，因此需要构造暂停行的场景
    /// 必须注入一个重试无法改变结论的失败。
    let deterministicFailure: Bool
    private var fail = true
    init(scanner: any V2MediaScanProvider, deterministicFailure: Bool = false) {
        self.scanner = scanner
        self.deterministicFailure = deterministicFailure
    }
    func scan(mediaID: MediaID) async throws -> V2MediaScanResult {
        if fail {
            fail = false
            if deterministicFailure { throw V2ForwardInboxError.corruptPersistenceState }
            throw V2ForwardMediaCopyError.sourceUnavailable
        }
        return try await scanner.scan(mediaID: mediaID)
    }
}

internal actor InviteImportTestBarrier {
    private var held = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    func hold() async {
        held = true; heldWaiter?.resume(); heldWaiter = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitUntilHeld() async {
        if !held { await withCheckedContinuation { heldWaiter = $0 } }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}

internal func verifyDurableReplayClockRecovery(
    _ command: V2DurableWorkReplayCommand,
    store: PostgresV2DurableWorkReplayStore,
    sql: any SQLDatabase,
    operatorPrincipal: String,
    now: Date,
    expected: V2DurableWorkReplayOutcome = .requeued
) async throws -> V2DurableWorkReplayResult {
    func snapshot() async throws -> String {
        try #require(try await sql.raw("""
            SELECT jsonb_build_object(
                'audit', (SELECT jsonb_agg(to_jsonb(r) ORDER BY operation_id) FROM im_v2.durable_work_replay_audit r),
                'personal_events', (SELECT jsonb_agg(to_jsonb(r) ORDER BY source_event_id, user_id, projection_kind) FROM im_v2.user_state_event_outbox r),
                'reviews', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id) FROM im_v2.content_review_jobs r),
                'scan', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.media_scan_outbox r),
                'purge', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.media_purge_outbox r),
                'receipts', (SELECT jsonb_agg(to_jsonb(r) ORDER BY actor_user_id, operation_id) FROM im_v2.read_receipt_preference_propagation_outbox r),
                'checkpoints', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id) FROM im_v2.user_projection_checkpoints r),
                'ready', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id) FROM im_v2.user_projection_ready r)
            )::text AS value
            """).first(decoding: StringValueRow.self)).value
    }
    let sourceShardID = command.target.kind == .userStateEvent ? "room-a" : nil
    let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
    let initial = try await snapshot()
    for bad in badDates {
        let service = V2DurableWorkOperatorReplayService(store: store, roomOwnerStores: ["room-a": store], operatorPrincipal: operatorPrincipal, now: { bad })
        await #expect(throws: V2DurableWorkReplayStoreError.corruptPersistenceState) { _ = try await service.replay(command, sourceShardID: sourceShardID) }
        #expect(try await snapshot() == initial)
    }
    let service = V2DurableWorkOperatorReplayService(store: store, roomOwnerStores: ["room-a": store], operatorPrincipal: operatorPrincipal, now: { now })
    let results = try await withThrowingTaskGroup(of: V2DurableWorkReplayResult.self) { group in
        for _ in 0..<8 { group.addTask { try await service.replay(command, sourceShardID: sourceShardID) } }
        var results: [V2DurableWorkReplayResult] = []
        for try await result in group { results.append(result) }
        return results
    }
    #expect(results.count == 8 && results.allSatisfy { $0.outcome == expected })
    #expect(results.filter { !$0.wasIdempotent }.count == 1)
    let result = try #require(results.first { !$0.wasIdempotent })
    let committed = try await snapshot()
    let conflict = V2DurableWorkReplayCommand(operationID: command.operationID, target: command.target, reason: command.reason == .dataRepaired ? .dependencyRecovered : .dataRepaired)
    for bad in badDates {
        let service = V2DurableWorkOperatorReplayService(store: store, roomOwnerStores: ["room-a": store], operatorPrincipal: operatorPrincipal, now: { bad })
        #expect(try await service.replay(command, sourceShardID: sourceShardID) == .init(operationID: command.operationID, outcome: expected, wasIdempotent: true))
        await #expect(throws: V2DurableWorkReplayStoreError.idempotencyConflict) { _ = try await service.replay(conflict, sourceShardID: sourceShardID) }
        #expect(try await snapshot() == committed)
    }
    return result
}

internal final class PreferenceReplayClockDelivery: V2UserShardProjectionDelivering, Sendable {
    struct Call: Equatable, Sendable {
        let userID: UserID
        let sourceEventID: EventID
        let kinds: Set<String>
    }
    private let recorded = Mutex<[Call]>([])
    private let fails = Mutex(false)
    var calls: [Call] { recorded.withLock { $0 } }
    func setFailure(_ value: Bool) { fails.withLock { $0 = value } }
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? {
        recorded.withLock { $0.append(.init(userID: userID, sourceEventID: sourceEventID, kinds: projectionKinds)) }
        if fails.withLock({ $0 }) { throw PreferenceReplayClockDeliveryError.unavailable }
        return nil
    }
}

internal enum PreferenceReplayClockDeliveryError: Error { case unavailable }
