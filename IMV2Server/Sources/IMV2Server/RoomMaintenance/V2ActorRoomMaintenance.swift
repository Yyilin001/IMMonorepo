import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 仅在宿主批准维护房间轮次后运行。
/// 扫描器的观测不能作为写入物理所有者数据库的权限依据。
public struct V2ActorRoomMaintenanceExecutor: Sendable {
    private let retention: PostgresV2RoomLogRetentionStore
    private let bookkeeping: PostgresV2RoomBookkeepingStore
    private let timeouts: V2RoomActivationSQLTimeouts
    private let now: @Sendable () -> Date

    public init(database: any Database, timeouts: V2RoomActivationSQLTimeouts = .default,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.retention = .init(database: database)
        self.bookkeeping = .init(database: database, timeouts: timeouts)
        self.timeouts = timeouts
        self.now = now
    }

    public func execute(_ command: V2RoomMaintenanceCommand,
                        token: V2RoomActivationToken) async throws -> V2RoomMaintenanceResult {
        guard command.roomID == token.roomID else { throw V2RoomActivationLeaseError.activationChanged }
        switch command {
        case .trimLog(let request):
            let mode: V2RoomLogRetentionMode = request.mode == .window ? .window : .permanent
            let report = try await retention.trimRoomLog(token: token, mode: mode,
                window: request.windowSeconds, now: now(), timeouts: timeouts)
            return .logTrimmed(.init(advancedFloor: report.trimmedRooms == 1,
                deletedEvents: report.deletedEvents))
        case .purgeBookkeeping(let request):
            let report = try await bookkeeping.purge(token: token, now: now(),
                retention: request.retentionSeconds,
                idempotencyRetention: request.idempotencyRetentionSeconds,
                rowLimit: request.rowLimit)
            return .bookkeepingPurged(report)
        }
    }
}

/// 扫描器只提供提示。调用适配器会通过仅供服务使用的房间能力，
/// 对所选房间分别执行准入。
public protocol V2RoomMaintenanceScanning: Sendable {
    func retentionCandidates(limit: Int) async throws -> [RoomID]
    func bookkeepingCandidates(limit: Int) async throws -> [RoomID]
}

public protocol V2RoomMaintenanceInvoking: Sendable {
    func invoke(_ command: V2RoomMaintenanceCommand,
                deadline: ContinuousClock.Instant) async throws -> V2RoomMaintenanceResult
}

/// 每个物理所有者数据库对应一个实例。簿记扫描按有界键顺序访问
/// 所有本地房间，无须新增资格索引或 schema；
/// 逐房间命令会在围栏下检查终态条件。
public actor PostgresV2RoomMaintenanceScanner: V2RoomMaintenanceScanning {
    private let database: any Database
    private let retention: PostgresV2RoomLogRetentionStore
    private var lastBookkeepingRoomID: UUID?

    public init(database: any Database) {
        self.database = database
        self.retention = .init(database: database)
    }

    public func retentionCandidates(limit: Int) async throws -> [RoomID] {
        try await retention.scanCandidateRoomIDs(limit: limit)
    }

    public func bookkeepingCandidates(limit: Int) async throws -> [RoomID] {
        guard (1...1_000).contains(limit) else { throw V2ControlPlaneHousekeepingError.invalidLimit }
        guard let sql = database as? any SQLDatabase else {
            throw V2ControlPlaneHousekeepingError.corruptPersistenceState
        }
        let after = lastBookkeepingRoomID
        let predicate: SQLQueryString = if let after { "room_id > \(bind: after)" } else { "TRUE" }
        var rows = try await sql.raw("""
            SELECT room_id FROM im_v2.rooms WHERE \(predicate)
            ORDER BY room_id LIMIT \(bind: limit)
            """).all(decoding: V2RoomMaintenanceScanRow.self)
        if rows.isEmpty, after != nil {
            rows = try await sql.raw("""
                SELECT room_id FROM im_v2.rooms ORDER BY room_id LIMIT \(bind: limit)
                """).all(decoding: V2RoomMaintenanceScanRow.self)
        }
        lastBookkeepingRoomID = rows.last?.roomID
        return rows.map { RoomID(uuid: $0.roomID) }
    }
}

private struct V2RoomMaintenanceScanRow: Decodable {
    let roomID: UUID
    enum CodingKeys: String, CodingKey { case roomID = "room_id" }
}

public struct V2RoomActorMaintenanceReport: Equatable, Sendable {
    public let scannedRooms: Int
    public let advancedFloors: Int
    public let deletedEvents: Int
    public let deletedReviewJobs: Int
    public let deletedOperationRows: Int

    public init(scannedRooms: Int, advancedFloors: Int = 0, deletedEvents: Int = 0,
                deletedReviewJobs: Int = 0, deletedOperationRows: Int = 0) {
        self.scannedRooms = scannedRooms
        self.advancedFloors = advancedFloors
        self.deletedEvents = deletedEvents
        self.deletedReviewJobs = deletedReviewJobs
        self.deletedOperationRows = deletedOperationRows
    }
}

/// 每个候选房间分发一条命令。失败房间由后续扫描重试；
/// 同一轮有界处理中的健康房间仍能推进。
public struct V2RoomActorMaintenanceWorker: Sendable {
    private let scanner: any V2RoomMaintenanceScanning
    private let invoker: any V2RoomMaintenanceInvoking
    private let callTimeout: Duration

    public init(scanner: any V2RoomMaintenanceScanning,
                invoker: any V2RoomMaintenanceInvoking,
                callTimeout: Duration = .seconds(10)) {
        precondition(callTimeout > .zero)
        self.scanner = scanner
        self.invoker = invoker
        self.callTimeout = callTimeout
    }

    public func runRetention(limit: Int, mode: V2RoomLogRetentionMode,
                             window: TimeInterval) async throws -> V2RoomActorMaintenanceReport {
        let rooms = try await scanner.retentionCandidates(limit: limit)
        var floors = 0, events = 0
        var failure: (any Error)?
        for room in rooms {
            do {
                let request = V2ActorRoomLogTrimWire(roomID: room,
                    mode: mode == .window ? .window : .permanent, windowSeconds: window)
                guard case .logTrimmed(let result) = try await invoker.invoke(.trimLog(request),
                    deadline: ContinuousClock.now.advanced(by: callTimeout)) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                if result.advancedFloor { floors += 1 }
                events += result.deletedEvents
            } catch is CancellationError { throw CancellationError() }
            catch { failure = failure ?? error }
        }
        if let failure { throw failure }
        return .init(scannedRooms: rooms.count, advancedFloors: floors, deletedEvents: events)
    }

    public func runBookkeeping(limit: Int, retention: TimeInterval,
                               idempotencyRetention: TimeInterval,
                               rowLimitPerRoom: Int) async throws -> V2RoomActorMaintenanceReport {
        let rooms = try await scanner.bookkeepingCandidates(limit: limit)
        var jobs = 0, operations = 0
        var failure: (any Error)?
        for room in rooms {
            do {
                let request = V2ActorRoomBookkeepingPurgeWire(roomID: room,
                    retentionSeconds: retention,
                    idempotencyRetentionSeconds: idempotencyRetention,
                    rowLimit: rowLimitPerRoom)
                guard case .bookkeepingPurged(let result) = try await invoker.invoke(
                    .purgeBookkeeping(request),
                    deadline: ContinuousClock.now.advanced(by: callTimeout)) else {
                    throw V2ControlPlaneHousekeepingError.corruptPersistenceState
                }
                jobs += result.deletedReviewJobs
                operations += result.deletedOperationRows
            } catch is CancellationError { throw CancellationError() }
            catch { failure = failure ?? error }
        }
        if let failure { throw failure }
        return .init(scannedRooms: rooms.count, deletedReviewJobs: jobs,
            deletedOperationRows: operations)
    }
}
