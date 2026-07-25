import Foundation
import Testing
@testable import IMV2Core

struct FanoutAdmissionTests {
    @Test
    func groupMessageReservesRoomAndShardCapacityAtomically() throws {
        let profile = try profile()
        let room = try roomState(eligibleMembers: 3)
        let shard = try shardState(validUntil: .distantFuture)

        let result = try FanoutAdmissionEvaluator.reserve(
            request: FanoutAdmissionRequest(targetRule: .eligibleMemberCount),
            profile: profile,
            roomState: room,
            shardState: shard,
            now: Date()
        )

        guard case let .accepted(reservation, reservedRoom, reservedShard) = result else {
            Issue.record("Expected a successful admission")
            return
        }
        #expect(reservation.cost.targetCount == 3)
        #expect(reservedRoom.commandWindow.used == 1)
        #expect(reservedRoom.fanoutWindow.used == 3)
        #expect(reservedRoom.outstandingFanoutUnits == 3)
        #expect(reservedShard.lease?.commandWindow.used == 1)
        #expect(reservedShard.lease?.fanoutWindow.used == 3)
        #expect(reservedShard.outstandingFanoutUnits == 3)
    }

    @Test
    func shardLeaseFailureDoesNotProduceAReservation() throws {
        let result = try FanoutAdmissionEvaluator.reserve(
            request: FanoutAdmissionRequest(targetRule: .exactTargetCount(1)),
            profile: try profile(),
            roomState: try roomState(eligibleMembers: 1),
            shardState: try ShardAdmissionState(lease: nil, outstandingFanoutUnits: 0, outstandingPlans: 0),
            now: Date()
        )

        #expect(result == .unavailable(.missingShardLease))
    }

    @Test
    func exhaustedShardPoolRejectsBeforeAnyStateCanBeCommitted() throws {
        let profile = try profile()
        let room = try roomState(eligibleMembers: 3)
        let exhaustedLease = try ShardAdmissionLease(
            id: try ShardAdmissionLeaseID("lease-a"),
            generation: 1,
            validUntil: .distantFuture,
            commandWindow: try CapacityWindow(limit: 10),
            fanoutWindow: try CapacityWindow(limit: 2),
            maxOutstandingFanoutUnits: 10,
            maxOutstandingPlans: 10
        )
        let shard = try ShardAdmissionState(lease: exhaustedLease, outstandingFanoutUnits: 0, outstandingPlans: 0)

        let result = try FanoutAdmissionEvaluator.reserve(
            request: FanoutAdmissionRequest(targetRule: .eligibleMemberCount),
            profile: profile,
            roomState: room,
            shardState: shard,
            now: Date()
        )

        #expect(result == .rateLimited(retryAfterSeconds: profile.retryAfterSeconds))
        #expect(room.commandWindow.used == 0)
        #expect(shard.lease?.fanoutWindow.used == 0)
    }

    @Test
    func admissionRejectsAStateThatDoesNotMatchItsDeclaredProfile() throws {
        let profile = try profile()
        let room = try RoomAdmissionState(
            eligibleMemberCount: 1,
            commandWindow: try CapacityWindow(limit: profile.maxCommandsPerWindow - 1),
            fanoutWindow: try CapacityWindow(limit: profile.maxFanoutUnitsPerWindow),
            outstandingFanoutUnits: 0,
            outstandingPlans: 0
        )

        let result = try FanoutAdmissionEvaluator.reserve(
            request: FanoutAdmissionRequest(targetRule: .eligibleMemberCount),
            profile: profile,
            roomState: room,
            shardState: try shardState(validUntil: .distantFuture),
            now: Date()
        )

        #expect(result == .rateLimited(retryAfterSeconds: profile.retryAfterSeconds))
    }

    @Test
    func completionUnitReleasesItsRepresentedCostExactlyOnce() throws {
        var unit = try FanoutCompletionUnit(id: try CompletionUnitID("plan-1.page-1"), targetCount: 3)
        try unit.recordCommittedTargets(2)
        try unit.recordPolicySkippedTargets(1)
        try unit.markTerminal()

        let cost = try unit.releaseReservation()
        #expect(cost.targetCount == 3)
        #expect(unit.state == .released)
        #expect(throws: CompletionUnitMutationError.cannotRelease) {
            _ = try unit.releaseReservation()
        }
    }

    @Test("final completion unit releases both unit capacity and plan capacity")
    func finalCompletionUnitClosesOutstandingPlan() throws {
        let initialShard = try shardState(validUntil: .distantFuture)
        let result = try FanoutAdmissionEvaluator.release(
            completedUnit: try FanoutCost(targetCount: 3),
            roomState: try RoomAdmissionState(
                eligibleMemberCount: 3,
                commandWindow: try CapacityWindow(limit: 10, used: 1),
                fanoutWindow: try CapacityWindow(limit: 10, used: 3),
                outstandingFanoutUnits: 3,
                outstandingPlans: 1
            ),
            shardState: try ShardAdmissionState(
                lease: initialShard.lease,
                outstandingFanoutUnits: 3,
                outstandingPlans: 1
            ),
            closesPlan: true
        )
        #expect(result.roomState.outstandingFanoutUnits == 0)
        #expect(result.roomState.outstandingPlans == 0)
        #expect(result.shardState.outstandingFanoutUnits == 0)
        #expect(result.shardState.outstandingPlans == 0)
    }

    private func profile() throws -> RoomCapacityProfile {
        try RoomCapacityProfile(
            maxEligibleMembers: 100,
            maxCommandsPerWindow: 10,
            maxFanoutUnitsPerWindow: 100,
            maxOutstandingFanoutUnits: 100,
            maxOutstandingPlans: 10,
            maxEnumerationPageSize: 10,
            maxPlannerConcurrency: 2,
            maxDeliveryConcurrency: 4,
            retryAfterSeconds: 3
        )
    }

    private func roomState(eligibleMembers: Int) throws -> RoomAdmissionState {
        try RoomAdmissionState(
            eligibleMemberCount: eligibleMembers,
            commandWindow: try CapacityWindow(limit: 10),
            fanoutWindow: try CapacityWindow(limit: 100),
            outstandingFanoutUnits: 0,
            outstandingPlans: 0
        )
    }

    private func shardState(validUntil: Date) throws -> ShardAdmissionState {
        let lease = try ShardAdmissionLease(
            id: try ShardAdmissionLeaseID("lease-a"),
            generation: 1,
            validUntil: validUntil,
            commandWindow: try CapacityWindow(limit: 10),
            fanoutWindow: try CapacityWindow(limit: 100),
            maxOutstandingFanoutUnits: 100,
            maxOutstandingPlans: 10
        )
        return try ShardAdmissionState(lease: lease, outstandingFanoutUnits: 0, outstandingPlans: 0)
    }
}
