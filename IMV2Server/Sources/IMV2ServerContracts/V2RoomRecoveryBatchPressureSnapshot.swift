import Foundation

/// Server-only labels; never supplied by a client or derived from a room ID.
public enum V2RoomRecoveryBatchPurpose: String, CaseIterable, Hashable, Sendable {
    case statesCohort = "states_cohort"
    case scalar
    case purePull = "pure_pull"
}

public struct V2RoomRecoveryBatchPurposeSnapshot: Sendable, Equatable {
    public var inFlight: Int
    public var items: Int
    public var oldestMilliseconds: Double
    public var started: UInt64
    public var completed: UInt64
    public var busyBeforeAcquire: UInt64
    public var durationMillisecondsSum: Double
    public var durationMillisecondsMax: Double

    public init(inFlight: Int = 0, items: Int = 0, oldestMilliseconds: Double = 0,
                started: UInt64 = 0, completed: UInt64 = 0, busyBeforeAcquire: UInt64 = 0,
                durationMillisecondsSum: Double = 0, durationMillisecondsMax: Double = 0) {
        self.inFlight = inFlight; self.items = items; self.oldestMilliseconds = oldestMilliseconds
        self.started = started; self.completed = completed; self.busyBeforeAcquire = busyBeforeAcquire
        self.durationMillisecondsSum = durationMillisecondsSum; self.durationMillisecondsMax = durationMillisecondsMax
    }
}

/// Actual batch lifetime includes work admission, database callbacks and reply
/// validation. Caller cancellation does not settle a submitted batch.
public struct V2RoomRecoveryBatchPressureSnapshot: Sendable, Equatable {
    public var purposes: [V2RoomRecoveryBatchPurpose: V2RoomRecoveryBatchPurposeSnapshot]
    public var pendingItems: Int = 0
    public var retainedItems: Int = 0
    public var retainedBytes: Int = 0
    public var ordinaryRetainedItems: Int = 0
    public var actualBatches: Int = 0
    public var oldestQueuedMilliseconds: Double = 0
    public var oldestActualMilliseconds: Double = 0
    public var batchesStarted: UInt64 = 0
    public var itemsSelected: UInt64 = 0
    public var itemsSettled: UInt64 = 0
    public init(purposes: [V2RoomRecoveryBatchPurpose: V2RoomRecoveryBatchPurposeSnapshot] = [:]) {
        self.purposes = Dictionary(uniqueKeysWithValues: V2RoomRecoveryBatchPurpose.allCases.map {
            ($0, purposes[$0, default: .init()])
        })
    }
}
