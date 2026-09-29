import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

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
                    throw V2RoomMaintenanceError.unexpectedResult
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
                    throw V2RoomMaintenanceError.unexpectedResult
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
