/// Fixed Directory observations; caller waits do not imply physical RPC/SQL ownership.
/// Cold caller wait and shared actual resolution overlap and must not be added.
public enum V2RoomDirectoryRecoveryStage: String, CaseIterable, Sendable {
    case coldCallerWait = "cold_caller_wait"
    /// Shared actual resolver job, also used by ordinary send/read callers.
    case actualResolution = "actual_resolution"
    case hostCallerWait = "host_caller_wait"
    case settledCallback = "settled_callback"
}

public struct V2RoomDirectoryRecoveryStageSnapshot: Equatable, Sendable {
    public var active: Int
    public var oldestMilliseconds: Double
    public var started: UInt64
    public var completed: UInt64
    public var itemsStarted: UInt64
    public var totalMilliseconds: Double
    public var maxMilliseconds: Double

    public init(active: Int = 0, oldestMilliseconds: Double = 0, started: UInt64 = 0, completed: UInt64 = 0,
                itemsStarted: UInt64 = 0, totalMilliseconds: Double = 0, maxMilliseconds: Double = 0) {
        self.active = active; self.oldestMilliseconds = oldestMilliseconds
        self.started = started; self.completed = completed
        self.itemsStarted = itemsStarted; self.totalMilliseconds = totalMilliseconds
        self.maxMilliseconds = maxMilliseconds
    }
}

/// Closed, process-local counters; no room, actor or operation identifiers.
public struct V2RoomDirectoryCallMetricsSnapshot: Equatable, Sendable {
    public let cachedCalls: UInt64
    public let cachedResponses: UInt64
    public let cacheMisses: UInt64
    public let locationInvalidations: UInt64
    public let recoveryAttempts: UInt64
    public let recoveryWaits: UInt64
    public let recoveringRooms: Int
    public let waitingForLeaseRooms: Int
    public let recoveryWarmItems: UInt64
    public let recoveryColdItems: UInt64
    /// Calls actually entering the transport batch API, including predispatch rejection.
    /// Physical invocations and their settlement are measured by the transport separately.
    public let recoveryHostCohorts: UInt64
    public let recoveryHostItems: UInt64
    public let recoveryStages: [V2RoomDirectoryRecoveryStage: V2RoomDirectoryRecoveryStageSnapshot]

    public init(cachedCalls: UInt64 = 0,
                cachedResponses: UInt64 = 0,
                cacheMisses: UInt64 = 0,
                locationInvalidations: UInt64 = 0,
                recoveryAttempts: UInt64 = 0,
                recoveryWaits: UInt64 = 0,
                recoveringRooms: Int = 0,
                waitingForLeaseRooms: Int = 0,
                recoveryWarmItems: UInt64 = 0, recoveryColdItems: UInt64 = 0,
                recoveryHostCohorts: UInt64 = 0, recoveryHostItems: UInt64 = 0,
                recoveryStages: [V2RoomDirectoryRecoveryStage: V2RoomDirectoryRecoveryStageSnapshot] = [:]) {
        self.cachedCalls = cachedCalls
        self.cachedResponses = cachedResponses
        self.cacheMisses = cacheMisses
        self.locationInvalidations = locationInvalidations
        self.recoveryAttempts = recoveryAttempts
        self.recoveryWaits = recoveryWaits
        self.recoveringRooms = recoveringRooms
        self.waitingForLeaseRooms = waitingForLeaseRooms
        self.recoveryWarmItems = recoveryWarmItems; self.recoveryColdItems = recoveryColdItems
        self.recoveryHostCohorts = recoveryHostCohorts; self.recoveryHostItems = recoveryHostItems
        self.recoveryStages = Dictionary(uniqueKeysWithValues: V2RoomDirectoryRecoveryStage.allCases.map {
            ($0, recoveryStages[$0] ?? .init())
        })
    }
}

/// Closed, process-local counters; no room, actor or operation identifiers.
public enum V2RoomRenewalFailureStage: String, CaseIterable, Sendable {
    case callerTimeout, callerCancelled, transportError, replyVerification, invalidBatchReply, remoteOutcomeUnknown
}

public struct V2RoomTransportCallMetricsSnapshot: Equatable, Sendable {
    public let cachedLocalCalls: UInt64
    public let cachedRemoteCalls: UInt64
    public let roomLookups: UInt64
    public let roomInvocations: UInt64
    public let referenceMisses: UInt64
    public let hostRecoveryProbes: UInt64
    public let hostRecoveryWaits: UInt64
    public let activeHostRecoveries: Int
    public let recoveryStages: [V2RoomTransportRecoveryStage: V2RoomTransportRecoveryStageSnapshot]
    public let batchCallerTimeouts: UInt64
    public let batchCallerCancellations: UInt64
    public let batchRejectedGlobal: UInt64
    public let batchRejectedPeer: UInt64
    public let renewalActualCalls: Int
    public let renewalFailures: [V2RoomRenewalFailureStage: UInt64]

    public init(cachedLocalCalls: UInt64 = 0,
                cachedRemoteCalls: UInt64 = 0,
                roomLookups: UInt64 = 0,
                roomInvocations: UInt64 = 0,
                referenceMisses: UInt64 = 0,
                hostRecoveryProbes: UInt64 = 0,
                hostRecoveryWaits: UInt64 = 0,
                activeHostRecoveries: Int = 0,
                recoveryStages: [V2RoomTransportRecoveryStage: V2RoomTransportRecoveryStageSnapshot] = [:],
                batchCallerTimeouts: UInt64 = 0, batchCallerCancellations: UInt64 = 0,
                batchRejectedGlobal: UInt64 = 0, batchRejectedPeer: UInt64 = 0,
                renewalActualCalls: Int = 0, renewalFailures: [V2RoomRenewalFailureStage: UInt64] = [:]) {
        self.cachedLocalCalls = cachedLocalCalls
        self.cachedRemoteCalls = cachedRemoteCalls
        self.roomLookups = roomLookups
        self.roomInvocations = roomInvocations
        self.referenceMisses = referenceMisses
        self.hostRecoveryProbes = hostRecoveryProbes
        self.hostRecoveryWaits = hostRecoveryWaits
        self.activeHostRecoveries = activeHostRecoveries
        self.recoveryStages = Dictionary(uniqueKeysWithValues: V2RoomTransportRecoveryStage.allCases.map {
            ($0, recoveryStages[$0] ?? .init())
        })
        self.batchCallerTimeouts = batchCallerTimeouts
        self.batchCallerCancellations = batchCallerCancellations
        self.batchRejectedGlobal = batchRejectedGlobal
        self.batchRejectedPeer = batchRejectedPeer
        self.renewalActualCalls = renewalActualCalls
        self.renewalFailures = renewalFailures
    }
}

public struct V2RoomActivationHostSnapshot: Equatable, Sendable {
    public let accepting: Bool
    public let activeRooms: Int
    public let pendingRooms: Int
    public let activationWaiters: Int
    public let restoringRooms: Int
    public let retiringRooms: Int

    package init(accepting: Bool, activeRooms: Int, pendingRooms: Int, activationWaiters: Int, restoringRooms: Int, retiringRooms: Int) {
        self.accepting = accepting
        self.activeRooms = activeRooms
        self.pendingRooms = pendingRooms
        self.activationWaiters = activationWaiters
        self.restoringRooms = restoringRooms
        self.retiringRooms = retiringRooms
    }
}

public struct V2RoomCommandBudgetSnapshot: Equatable, Sendable {
    public let commandCount: Int
    public let byteCount: Int
    public let roomCount: Int
    public let reservationCount: Int
    public let peakCommandCount: Int
    public let peakByteCount: Int

    package init(commandCount: Int, byteCount: Int, roomCount: Int, reservationCount: Int, peakCommandCount: Int, peakByteCount: Int) {
        self.commandCount = commandCount
        self.byteCount = byteCount
        self.roomCount = roomCount
        self.reservationCount = reservationCount
        self.peakCommandCount = peakCommandCount
        self.peakByteCount = peakByteCount
    }
}

/// 有界的进程内观测数据。不导出房间、宿主或操作标识；
/// 各组件样本也不构成事务一致的快照。
public struct V2RoomRuntimeMetricsSnapshot: Equatable, Sendable {
    public let host: V2RoomActivationHostSnapshot?
    public let commands: V2RoomCommandBudgetSnapshot?
    public let cachedLocations: Int
    public let pendingResolutions: Int
    public let activeResolutions: Int
    public let resolutionWaiters: Int
    public let directoryCalls: V2RoomDirectoryCallMetricsSnapshot
    public let transportCalls: V2RoomTransportCallMetricsSnapshot

    public init(host: V2RoomActivationHostSnapshot?, commands: V2RoomCommandBudgetSnapshot?,
                cachedLocations: Int, pendingResolutions: Int,
                activeResolutions: Int, resolutionWaiters: Int,
                directoryCalls: V2RoomDirectoryCallMetricsSnapshot = .init(),
                transportCalls: V2RoomTransportCallMetricsSnapshot = .init()) {
        self.host = host
        self.commands = commands
        self.cachedLocations = cachedLocations
        self.pendingResolutions = pendingResolutions
        self.activeResolutions = activeResolutions
        self.resolutionWaiters = resolutionWaiters
        self.directoryCalls = directoryCalls
        self.transportCalls = transportCalls
    }
}

public protocol V2RoomRuntimeMetricsReading: Sendable {
    func roomRuntimeMetricsSnapshot() async -> V2RoomRuntimeMetricsSnapshot
}
