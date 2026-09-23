import Foundation
import IMV2ActorContracts
import IMV2Core

/// A permit remains charged while queued, executing, or awaiting reconciliation.
/// Only the budget that issued it can return its capacity.
public struct V2RoomCommandPermit: Equatable, Sendable {
    public let roomID: RoomID
    /// Dispatch uses these exact immutable bytes, not a separately supplied
    /// payload with a caller-reported size. Data copies share immutable storage.
    public let encodedRequest: Data
    public var byteCount: Int { encodedRequest.count }
    fileprivate let budgetID: UUID
    fileprivate let permitID: UUID
}

public struct V2RoomCommandBudgetSnapshot: Equatable, Sendable {
    public let commandCount: Int
    public let byteCount: Int
    public let roomCount: Int
}

/// Non-waiting room and host admission prevents overload from creating another
/// unbounded queue. The activation owns each permit through durable completion.
public actor V2RoomCommandBudget {
    private let identity = UUID()
    private let configuration: V2RoomRuntimeConfiguration
    private var permits: [UUID: V2RoomCommandPermit] = [:]
    private var rooms: [RoomID: RoomUsage] = [:]
    private var totalBytes = 0

    public init(configuration: V2RoomRuntimeConfiguration) {
        self.configuration = configuration
    }

    public func acquire(roomID: RoomID, encodedRequest: Data) throws -> V2RoomCommandPermit {
        let byteCount = encodedRequest.count
        guard byteCount > 0, byteCount <= configuration.maximumRequestBytes else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        let usage = rooms[roomID] ?? RoomUsage()
        guard permits.count < configuration.maximumQueuedCommandsPerHost,
              usage.commandCount < configuration.maximumQueuedCommandsPerRoom,
              byteCount <= configuration.maximumQueuedBytesPerHost - totalBytes,
              byteCount <= configuration.maximumQueuedBytesPerRoom - usage.byteCount
        else { throw V2RoomCallFailure.notAccepted(.overloaded) }

        let permit = V2RoomCommandPermit(
            roomID: roomID, encodedRequest: encodedRequest, budgetID: identity, permitID: UUID()
        )
        permits[permit.permitID] = permit
        rooms[roomID] = RoomUsage(
            commandCount: usage.commandCount + 1, byteCount: usage.byteCount + byteCount
        )
        totalBytes += byteCount
        return permit
    }

    /// Safe for cancellation and completion to race. A late duplicate or a
    /// permit from another host budget cannot decrement capacity again.
    @discardableResult
    public func release(_ permit: V2RoomCommandPermit) -> Bool {
        guard permit.budgetID == identity,
              permits[permit.permitID] == permit,
              let usage = rooms[permit.roomID] else { return false }
        permits.removeValue(forKey: permit.permitID)
        totalBytes -= permit.byteCount
        if usage.commandCount == 1 {
            rooms.removeValue(forKey: permit.roomID)
        } else {
            rooms[permit.roomID] = RoomUsage(
                commandCount: usage.commandCount - 1,
                byteCount: usage.byteCount - permit.byteCount
            )
        }
        return true
    }

    public func snapshot() -> V2RoomCommandBudgetSnapshot {
        V2RoomCommandBudgetSnapshot(
            commandCount: permits.count, byteCount: totalBytes, roomCount: rooms.count
        )
    }

    private struct RoomUsage: Sendable {
        var commandCount = 0
        var byteCount = 0
    }
}
