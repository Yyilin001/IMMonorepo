import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

struct PostgresV2RoomMaintenanceAdapter: V2RoomMaintenancePersisting {
    private let retention: PostgresV2RoomLogRetentionStore
    private let bookkeeping: PostgresV2RoomBookkeepingStore
    private let timeouts: V2RoomActivationSQLTimeouts

    init(database: any Database, timeouts: V2RoomActivationSQLTimeouts) {
        self.retention = .init(database: database)
        self.bookkeeping = .init(database: database, timeouts: timeouts)
        self.timeouts = timeouts
    }

    func execute(_ command: V2RoomMaintenanceCommand, token: V2RoomActivationToken,
                 now: Date) async throws -> V2RoomMaintenanceResult {
        switch command {
        case .trimLog(let request):
            let mode: V2RoomLogRetentionMode = request.mode == .window ? .window : .permanent
            let report = try await retention.trimRoomLog(token: token, mode: mode,
                window: request.windowSeconds, now: now, timeouts: timeouts)
            return .logTrimmed(.init(advancedFloor: report.trimmedRooms == 1,
                deletedEvents: report.deletedEvents))
        case .purgeBookkeeping(let request):
            let report = try await bookkeeping.purge(token: token, now: now,
                retention: request.retentionSeconds,
                idempotencyRetention: request.idempotencyRetentionSeconds,
                rowLimit: request.rowLimit)
            return .bookkeepingPurged(report)
        }
    }
}

public extension V2ActorRoomMaintenanceExecutor {
    init(database: any Database, timeouts: V2RoomActivationSQLTimeouts = .default,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.init(persistence: PostgresV2RoomMaintenanceAdapter(database: database,
            timeouts: timeouts), now: now)
    }
}
