import Foundation
import Testing
@testable import IMV2Core

struct CommandAdmissionTests {
    @Test
    func roomLogReservesOnlyRoomAndShardCommandCapacity() throws {
        let profile = try profile()
        let room = try roomState(eligibleMembers: 3)
        let shard = try shardState(validUntil: .distantFuture)

        let result = try V2CommandAdmissionEvaluator.reserve(
            profile: profile,
            roomState: room,
            shardState: shard,
            now: Date()
        )

        guard case let .accepted(reservation, reservedRoom, reservedShard) = result else {
            Issue.record("Expected a successful admission")
            return
        }
        #expect(reservation.shardLeaseID == shard.lease?.id)
        #expect(reservation.shardLeaseGeneration == shard.lease?.generation)
        #expect(reservedRoom.commandWindow.used == 1)
        #expect(reservedShard.lease?.commandWindow.used == 1)
    }

    @Test
    func shardLeaseFailureDoesNotProduceAReservation() throws {
        let result = try V2CommandAdmissionEvaluator.reserve(
            profile: try profile(),
            roomState: try roomState(eligibleMembers: 1),
            shardState: try ShardAdmissionState(lease: nil),
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
            commandWindow: try CapacityWindow(limit: 10, used: 10))
        let shard = try ShardAdmissionState(lease: exhaustedLease)

        let result = try V2CommandAdmissionEvaluator.reserve(
            profile: profile,
            roomState: room,
            shardState: shard,
            now: Date()
        )

        #expect(result == .rateLimited(retryAfterSeconds: profile.retryAfterSeconds))
        #expect(room.commandWindow.used == 0)
    }

    @Test
    func admissionRejectsAStateThatDoesNotMatchItsDeclaredProfile() throws {
        let profile = try profile()
        let room = try RoomAdmissionState(
            eligibleMemberCount: 1,
            commandWindow: try CapacityWindow(limit: profile.maxCommandsPerWindow - 1))

        let result = try V2CommandAdmissionEvaluator.reserve(
            profile: profile,
            roomState: room,
            shardState: try shardState(validUntil: .distantFuture),
            now: Date()
        )

        #expect(result == .rateLimited(retryAfterSeconds: profile.retryAfterSeconds))
    }

    @Test(arguments: [1, 100])
    func memberCountDoesNotChangeCommandCost(members: Int) throws {
        let room = try RoomAdmissionState(
            eligibleMemberCount: members,
            commandWindow: CapacityWindow(limit: 10))
        let result = try V2CommandAdmissionEvaluator.reserve(
            profile: profile(), roomState: room,
            shardState: shardState(validUntil: .distantFuture), now: Date()
        )
        guard case let .accepted(_, nextRoom, nextShard) = result else {
            Issue.record("Room-log admission must reserve one command")
            return
        }
        #expect(nextRoom.commandWindow.used == 1)
        #expect(nextShard.lease?.commandWindow.used == 1)
    }

    @Test
    func leaseExpiresAtItsExactDeadline() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let result = try V2CommandAdmissionEvaluator.reserve(
            profile: profile(), roomState: roomState(eligibleMembers: 1),
            shardState: shardState(validUntil: now), now: now
        )
        #expect(result == .unavailable(.expiredShardLease))
    }

    @Test
    func memberCapacityStillRejectsAnOversizedRoom() throws {
        let result = try V2CommandAdmissionEvaluator.reserve(
            profile: profile(), roomState: roomState(eligibleMembers: 101),
            shardState: shardState(validUntil: .distantFuture), now: Date()
        )
        #expect(result == .rateLimited(retryAfterSeconds: 3))
    }

    @Test
    func fullCommandWindowRejectsWithoutOverflow() throws {
        let window = try CapacityWindow(limit: Int.max, used: Int.max)
        #expect(!window.canReserve(1))
        #expect(throws: V2CommandAdmissionMutationError.capacityExceeded) {
            try window.reserving(1)
        }
    }

    private func profile() throws -> RoomCapacityProfile {
        try RoomCapacityProfile(
            maxEligibleMembers: 100,
            maxCommandsPerWindow: 10,

            retryAfterSeconds: 3
        )
    }

    private func roomState(eligibleMembers: Int) throws -> RoomAdmissionState {
        try RoomAdmissionState(
            eligibleMemberCount: eligibleMembers,
            commandWindow: try CapacityWindow(limit: 10))
    }

    private func shardState(validUntil: Date) throws -> ShardAdmissionState {
        let lease = try ShardAdmissionLease(
            id: try ShardAdmissionLeaseID("lease-a"),
            generation: 1,
            validUntil: validUntil,
            commandWindow: try CapacityWindow(limit: 10))
        return try ShardAdmissionState(lease: lease)
    }
}
