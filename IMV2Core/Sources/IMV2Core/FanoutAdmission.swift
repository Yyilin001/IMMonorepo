import Foundation

public enum FanoutTargetRule: Equatable, Sendable {
    /// The ordinary room-message rule: exactly one user projection per eligible member.
    case eligibleMemberCount
    /// A command whose immutable audience is already known at acceptance time.
    case exactTargetCount(Int)
}

public struct FanoutCost: Equatable, Sendable {
    public let targetCount: Int

    public init(targetCount: Int) throws {
        guard targetCount >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.targetCount = targetCount
    }
}

public enum FanoutCostCalculator {
    public static func cost(
        for targetRule: FanoutTargetRule,
        eligibleMemberCount: Int
    ) throws -> FanoutCost {
        guard eligibleMemberCount >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }

        switch targetRule {
        case .eligibleMemberCount:
            return try FanoutCost(targetCount: eligibleMemberCount)
        case .exactTargetCount(let targetCount):
            return try FanoutCost(targetCount: targetCount)
        }
    }
}

public struct CapacityWindow: Equatable, Sendable {
    public let limit: Int
    public let used: Int

    public init(limit: Int, used: Int = 0) throws {
        guard limit >= 0, used >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.limit = limit
        self.used = used
    }

    public func canReserve(_ amount: Int) -> Bool {
        amount >= 0 && used <= limit && amount <= limit - used
    }

    public func reserving(_ amount: Int) throws -> CapacityWindow {
        guard canReserve(amount) else {
            throw FanoutAdmissionMutationError.capacityExceeded
        }
        return try CapacityWindow(limit: limit, used: used + amount)
    }
}

public struct RoomCapacityProfile: Equatable, Sendable {
    public let maxEligibleMembers: Int
    public let maxCommandsPerWindow: Int
    public let maxFanoutUnitsPerWindow: Int
    public let maxOutstandingFanoutUnits: Int
    public let maxOutstandingPlans: Int
    public let maxEnumerationPageSize: Int
    public let maxPlannerConcurrency: Int
    public let maxDeliveryConcurrency: Int
    public let retryAfterSeconds: Int

    public init(
        maxEligibleMembers: Int,
        maxCommandsPerWindow: Int,
        maxFanoutUnitsPerWindow: Int,
        maxOutstandingFanoutUnits: Int,
        maxOutstandingPlans: Int,
        maxEnumerationPageSize: Int,
        maxPlannerConcurrency: Int,
        maxDeliveryConcurrency: Int,
        retryAfterSeconds: Int
    ) throws {
        let values = [
            maxEligibleMembers,
            maxCommandsPerWindow,
            maxFanoutUnitsPerWindow,
            maxOutstandingFanoutUnits,
            maxOutstandingPlans,
            maxEnumerationPageSize,
            maxPlannerConcurrency,
            maxDeliveryConcurrency,
            retryAfterSeconds,
        ]
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.maxEligibleMembers = maxEligibleMembers
        self.maxCommandsPerWindow = maxCommandsPerWindow
        self.maxFanoutUnitsPerWindow = maxFanoutUnitsPerWindow
        self.maxOutstandingFanoutUnits = maxOutstandingFanoutUnits
        self.maxOutstandingPlans = maxOutstandingPlans
        self.maxEnumerationPageSize = maxEnumerationPageSize
        self.maxPlannerConcurrency = maxPlannerConcurrency
        self.maxDeliveryConcurrency = maxDeliveryConcurrency
        self.retryAfterSeconds = retryAfterSeconds
    }
}

public struct RoomAdmissionState: Equatable, Sendable {
    public let eligibleMemberCount: Int
    public let commandWindow: CapacityWindow
    public let fanoutWindow: CapacityWindow
    public let outstandingFanoutUnits: Int
    public let outstandingPlans: Int

    public init(
        eligibleMemberCount: Int,
        commandWindow: CapacityWindow,
        fanoutWindow: CapacityWindow,
        outstandingFanoutUnits: Int,
        outstandingPlans: Int
    ) throws {
        guard eligibleMemberCount >= 0,
              outstandingFanoutUnits >= 0,
              outstandingPlans >= 0
        else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.eligibleMemberCount = eligibleMemberCount
        self.commandWindow = commandWindow
        self.fanoutWindow = fanoutWindow
        self.outstandingFanoutUnits = outstandingFanoutUnits
        self.outstandingPlans = outstandingPlans
    }

    func reserving(cost: FanoutCost) throws -> RoomAdmissionState {
        try RoomAdmissionState(
            eligibleMemberCount: eligibleMemberCount,
            commandWindow: commandWindow.reserving(1),
            fanoutWindow: fanoutWindow.reserving(cost.targetCount),
            outstandingFanoutUnits: outstandingFanoutUnits + cost.targetCount,
            outstandingPlans: outstandingPlans + 1
        )
    }

    public func releasing(completedUnitCost: FanoutCost) throws -> RoomAdmissionState {
        guard completedUnitCost.targetCount <= outstandingFanoutUnits else {
            throw FanoutAdmissionMutationError.releaseExceedsReservation
        }
        return try RoomAdmissionState(
            eligibleMemberCount: eligibleMemberCount,
            commandWindow: commandWindow,
            fanoutWindow: fanoutWindow,
            outstandingFanoutUnits: outstandingFanoutUnits - completedUnitCost.targetCount,
            outstandingPlans: outstandingPlans
        )
    }
}

public struct ShardAdmissionLease: Equatable, Sendable {
    public let id: ShardAdmissionLeaseID
    public let generation: UInt64
    public let validUntil: Date
    public let commandWindow: CapacityWindow
    public let fanoutWindow: CapacityWindow
    public let maxOutstandingFanoutUnits: Int
    public let maxOutstandingPlans: Int

    public init(
        id: ShardAdmissionLeaseID,
        generation: UInt64,
        validUntil: Date,
        commandWindow: CapacityWindow,
        fanoutWindow: CapacityWindow,
        maxOutstandingFanoutUnits: Int,
        maxOutstandingPlans: Int
    ) throws {
        guard generation > 0 else {
            throw V2CoreError.invalidGeneration
        }
        guard maxOutstandingFanoutUnits >= 0, maxOutstandingPlans >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.id = id
        self.generation = generation
        self.validUntil = validUntil
        self.commandWindow = commandWindow
        self.fanoutWindow = fanoutWindow
        self.maxOutstandingFanoutUnits = maxOutstandingFanoutUnits
        self.maxOutstandingPlans = maxOutstandingPlans
    }

    public func isValid(at instant: Date) -> Bool {
        validUntil > instant
    }
}

public struct ShardAdmissionState: Equatable, Sendable {
    public let lease: ShardAdmissionLease?
    public let outstandingFanoutUnits: Int
    public let outstandingPlans: Int

    public init(
        lease: ShardAdmissionLease?,
        outstandingFanoutUnits: Int,
        outstandingPlans: Int
    ) throws {
        guard outstandingFanoutUnits >= 0, outstandingPlans >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.lease = lease
        self.outstandingFanoutUnits = outstandingFanoutUnits
        self.outstandingPlans = outstandingPlans
    }

    func reserving(cost: FanoutCost) throws -> ShardAdmissionState {
        guard let lease else {
            throw FanoutAdmissionMutationError.missingLease
        }
        return try ShardAdmissionState(
            lease: try ShardAdmissionLease(
                id: lease.id,
                generation: lease.generation,
                validUntil: lease.validUntil,
                commandWindow: lease.commandWindow.reserving(1),
                fanoutWindow: lease.fanoutWindow.reserving(cost.targetCount),
                maxOutstandingFanoutUnits: lease.maxOutstandingFanoutUnits,
                maxOutstandingPlans: lease.maxOutstandingPlans
            ),
            outstandingFanoutUnits: outstandingFanoutUnits + cost.targetCount,
            outstandingPlans: outstandingPlans + 1
        )
    }

    public func releasing(completedUnitCost: FanoutCost) throws -> ShardAdmissionState {
        guard completedUnitCost.targetCount <= outstandingFanoutUnits else {
            throw FanoutAdmissionMutationError.releaseExceedsReservation
        }
        return try ShardAdmissionState(
            lease: lease,
            outstandingFanoutUnits: outstandingFanoutUnits - completedUnitCost.targetCount,
            outstandingPlans: outstandingPlans
        )
    }
}

public struct FanoutAdmissionRequest: Equatable, Sendable {
    public let targetRule: FanoutTargetRule

    public init(targetRule: FanoutTargetRule) {
        self.targetRule = targetRule
    }
}

public struct FanoutAdmissionReservation: Equatable, Sendable {
    public let cost: FanoutCost
    public let shardLeaseID: ShardAdmissionLeaseID
    public let shardLeaseGeneration: UInt64

    public init(cost: FanoutCost, shardLeaseID: ShardAdmissionLeaseID, shardLeaseGeneration: UInt64) {
        self.cost = cost
        self.shardLeaseID = shardLeaseID
        self.shardLeaseGeneration = shardLeaseGeneration
    }
}

public enum FanoutAdmissionUnavailableReason: Equatable, Sendable {
    case missingShardLease
    case expiredShardLease
}

public enum FanoutAdmissionResult: Equatable, Sendable {
    /// Persist `roomState` and `shardState` together with the source event/outbox/plan.
    case accepted(
        reservation: FanoutAdmissionReservation,
        roomState: RoomAdmissionState,
        shardState: ShardAdmissionState
    )
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
}

public enum FanoutAdmissionMutationError: Error, Equatable, Sendable {
    case capacityExceeded
    case missingLease
    case releaseExceedsReservation
}

public enum FanoutAdmissionEvaluator {
    public static func reserve(
        request: FanoutAdmissionRequest,
        profile: RoomCapacityProfile,
        roomState: RoomAdmissionState,
        shardState: ShardAdmissionState,
        now: Date
    ) throws -> FanoutAdmissionResult {
        guard let lease = shardState.lease else {
            return .unavailable(.missingShardLease)
        }
        guard lease.isValid(at: now) else {
            return .unavailable(.expiredShardLease)
        }

        let cost = try FanoutCostCalculator.cost(
            for: request.targetRule,
            eligibleMemberCount: roomState.eligibleMemberCount
        )
        guard roomState.eligibleMemberCount <= profile.maxEligibleMembers,
              roomState.commandWindow.limit == profile.maxCommandsPerWindow,
              roomState.fanoutWindow.limit == profile.maxFanoutUnitsPerWindow,
              roomState.commandWindow.canReserve(1),
              roomState.fanoutWindow.canReserve(cost.targetCount),
              roomState.outstandingFanoutUnits + cost.targetCount <= profile.maxOutstandingFanoutUnits,
              roomState.outstandingPlans + 1 <= profile.maxOutstandingPlans,
              lease.commandWindow.canReserve(1),
              lease.fanoutWindow.canReserve(cost.targetCount),
              shardState.outstandingFanoutUnits + cost.targetCount <= lease.maxOutstandingFanoutUnits,
              shardState.outstandingPlans + 1 <= lease.maxOutstandingPlans
        else {
            return .rateLimited(retryAfterSeconds: profile.retryAfterSeconds)
        }

        let reservedRoomState = try roomState.reserving(cost: cost)
        let reservedShardState = try shardState.reserving(cost: cost)
        return .accepted(
            reservation: FanoutAdmissionReservation(
                cost: cost,
                shardLeaseID: lease.id,
                shardLeaseGeneration: lease.generation
            ),
            roomState: reservedRoomState,
            shardState: reservedShardState
        )
    }

    /// Releases one immutable completion unit. `closesPlan` must be true only
    /// for the final released unit of a source plan; this prevents a large
    /// group from leaking its single outstanding-plan reservation forever.
    public static func release(
        completedUnit: FanoutCost,
        roomState: RoomAdmissionState,
        shardState: ShardAdmissionState,
        closesPlan: Bool
    ) throws -> (roomState: RoomAdmissionState, shardState: ShardAdmissionState) {
        let releasedRoom = try roomState.releasing(completedUnitCost: completedUnit)
        let releasedShard = try shardState.releasing(completedUnitCost: completedUnit)
        guard closesPlan else { return (releasedRoom, releasedShard) }
        guard releasedRoom.outstandingPlans > 0, releasedShard.outstandingPlans > 0 else {
            throw FanoutAdmissionMutationError.releaseExceedsReservation
        }
        return (
            try RoomAdmissionState(
                eligibleMemberCount: releasedRoom.eligibleMemberCount,
                commandWindow: releasedRoom.commandWindow,
                fanoutWindow: releasedRoom.fanoutWindow,
                outstandingFanoutUnits: releasedRoom.outstandingFanoutUnits,
                outstandingPlans: releasedRoom.outstandingPlans - 1
            ),
            try ShardAdmissionState(
                lease: releasedShard.lease,
                outstandingFanoutUnits: releasedShard.outstandingFanoutUnits,
                outstandingPlans: releasedShard.outstandingPlans - 1
            )
        )
    }
}

public enum CompletionUnitState: Equatable, Sendable {
    case pending
    case terminal
    case released
}

/// A bounded, immutable target range. Persistence records the range itself;
/// this value type enforces the progress and one-time-release state machine.
public struct FanoutCompletionUnit: Equatable, Sendable {
    public let id: CompletionUnitID
    public let targetCount: Int
    public private(set) var committedTargetCount: Int
    public private(set) var policySkippedTargetCount: Int
    public private(set) var state: CompletionUnitState

    public init(id: CompletionUnitID, targetCount: Int) throws {
        guard targetCount >= 0 else {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.id = id
        self.targetCount = targetCount
        self.committedTargetCount = 0
        self.policySkippedTargetCount = 0
        self.state = .pending
    }

    public var terminalTargetCount: Int {
        committedTargetCount + policySkippedTargetCount
    }

    public mutating func recordCommittedTargets(_ count: Int) throws {
        try recordTerminalTargets(count, asPolicySkipped: false)
    }

    public mutating func recordPolicySkippedTargets(_ count: Int) throws {
        try recordTerminalTargets(count, asPolicySkipped: true)
    }

    public mutating func markTerminal() throws {
        guard state == .pending, terminalTargetCount == targetCount else {
            throw CompletionUnitMutationError.cannotBecomeTerminal
        }
        state = .terminal
    }

    /// Returns the unit cost exactly once. Callers persist the corresponding
    /// room and shard release in the same source-room transaction.
    public mutating func releaseReservation() throws -> FanoutCost {
        guard state == .terminal else {
            throw CompletionUnitMutationError.cannotRelease
        }
        state = .released
        return try FanoutCost(targetCount: targetCount)
    }

    private mutating func recordTerminalTargets(_ count: Int, asPolicySkipped: Bool) throws {
        guard state == .pending, count >= 0, terminalTargetCount + count <= targetCount else {
            throw CompletionUnitMutationError.invalidProgress
        }
        if asPolicySkipped {
            policySkippedTargetCount += count
        } else {
            committedTargetCount += count
        }
    }
}

public enum CompletionUnitMutationError: Error, Equatable, Sendable {
    case invalidProgress
    case cannotBecomeTerminal
    case cannotRelease
}
