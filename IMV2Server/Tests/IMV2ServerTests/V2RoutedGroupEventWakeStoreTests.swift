@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Routed group-event wake store")
struct V2RoutedGroupEventWakeStoreTests {
    @Test("invalid clocks preserve lease ownership and owner rotation")
    func clockBoundsPreserveOwners() async throws {
        let firstLease = try makeLease(roomSuffix: 601, tokenSuffix: 7)
        let secondLease = try makeLease(roomSuffix: 602, tokenSuffix: 8)
        let first = RoutedWakeOwnerStoreFake(leases: [firstLease])
        let second = RoutedWakeOwnerStoreFake(leases: [secondLease])
        let store = try V2RoutedGroupEventWakeStore(ownerStores: ["a": first, "b": second])
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(try await store.claimPending(now: now, leaseDuration: 15, limit: 1) == [firstLease])
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
            let invalid = Date(timeIntervalSince1970: seconds)
            await #expect(throws: V2GroupEventWakeStoreError.corruptPersistenceState) { try await store.claimPending(now: invalid, leaseDuration: 15, limit: 1) }
            await #expect(throws: V2GroupEventWakeStoreError.corruptPersistenceState) { try await store.scheduleRetry(firstLease, nextAttemptAt: invalid) }
        }
        for duration in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude, 0.0000001, 0, -1] {
            await #expect(throws: V2GroupEventWakeStoreError.corruptPersistenceState) { try await store.claimPending(now: now, leaseDuration: duration, limit: 1) }
        }
        let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
        await #expect(throws: V2GroupEventWakeStoreError.corruptPersistenceState) { try await store.claimPending(now: upper, leaseDuration: 15, limit: 1) }
        #expect(await first.claimLimits() == [1])
        #expect(await second.claimLimits().isEmpty)
        #expect(await first.retriedRooms().isEmpty)
        try await store.scheduleRetry(firstLease, nextAttemptAt: now.addingTimeInterval(-1))
        #expect(await first.retriedRooms() == [firstLease.wake.roomID])
        #expect(try await store.claimPending(now: now, leaseDuration: 15, limit: 1) == [secondLease])
        try await store.markPublished(secondLease)
        #expect(await second.publishedRooms() == [secondLease.wake.roomID])
    }

    @Test("an empty claim allocates for returned work instead of the requested maximum")
    func maximumLimitWithEmptyOwners() async throws {
        let first = RoutedWakeOwnerStoreFake(leases: [])
        let second = RoutedWakeOwnerStoreFake(leases: [])
        let store = try V2RoutedGroupEventWakeStore(ownerStores: ["a": first, "b": second])
        #expect(try await store.claimPending(now: .init(timeIntervalSince1970: 0), leaseDuration: 15, limit: Int.max).isEmpty)
        #expect(await first.claimLimits() == [Int.max / 2 + 1])
        #expect(await second.claimLimits() == [Int.max / 2])
    }

    @Test("claims owners concurrently and completes every lease on its issuing store")
    func routesLeaseCompletionToIssuingOwner() async throws {
        let first = RoutedWakeOwnerStoreFake(leases: try [
            makeLease(roomSuffix: 101, tokenSuffix: 1),
            makeLease(roomSuffix: 102, tokenSuffix: 2),
        ])
        let second = RoutedWakeOwnerStoreFake(leases: try [
            makeLease(roomSuffix: 201, tokenSuffix: 3),
        ])
        let store = try V2RoutedGroupEventWakeStore(ownerStores: [
            "postgres-a": first,
            "postgres-b": second,
        ])

        let leases = try await store.claimPending(
            now: .init(timeIntervalSince1970: 100),
            leaseDuration: 15,
            limit: 3
        )
        #expect(leases.count == 3)
        #expect(await first.claimLimits() == [2])
        #expect(await second.claimLimits() == [1])

        for lease in leases where lease.wake.roomID.rawValue.hasSuffix("000000000201") {
            try await store.scheduleRetry(
                lease,
                nextAttemptAt: .init(timeIntervalSince1970: 120)
            )
        }
        for lease in leases where !lease.wake.roomID.rawValue.hasSuffix("000000000201") {
            try await store.markPublished(lease)
        }

        #expect(await first.publishedRooms().count == 2)
        #expect(await first.retriedRooms().isEmpty)
        #expect(await second.publishedRooms().isEmpty)
        #expect(await second.retriedRooms().count == 1)
    }

    @Test("a limit smaller than the owner count rotates fairly between passes")
    func rotatesSmallClaimLimit() async throws {
        let first = RoutedWakeOwnerStoreFake(leases: try [
            makeLease(roomSuffix: 301, tokenSuffix: 4),
        ])
        let second = RoutedWakeOwnerStoreFake(leases: try [
            makeLease(roomSuffix: 401, tokenSuffix: 5),
        ])
        let store = try V2RoutedGroupEventWakeStore(ownerStores: [
            "postgres-a": first,
            "postgres-b": second,
        ])
        let now = Date(timeIntervalSince1970: 200)

        let firstPass = try await store.claimPending(
            now: now,
            leaseDuration: 15,
            limit: 1
        )
        let secondPass = try await store.claimPending(
            now: now,
            leaseDuration: 15,
            limit: 1
        )

        #expect(firstPass.map(\.wake.roomID.rawValue) != secondPass.map(\.wake.roomID.rawValue))
        #expect(await first.claimLimits() == [1])
        #expect(await second.claimLimits() == [1])
    }

    @Test("a failed owner does not strand leases already claimed from a healthy owner")
    func partialOwnerFailureReturnsHealthyLeases() async throws {
        let failed = RoutedWakeOwnerStoreFake(leases: [], failsClaims: true)
        let healthyLease = try makeLease(roomSuffix: 501, tokenSuffix: 6)
        let healthy = RoutedWakeOwnerStoreFake(leases: [healthyLease])
        let store = try V2RoutedGroupEventWakeStore(ownerStores: [
            "postgres-a": failed,
            "postgres-b": healthy,
        ])

        let leases = try await store.claimPending(
            now: .init(timeIntervalSince1970: 300),
            leaseDuration: 15,
            limit: 2
        )

        #expect(leases == [healthyLease])
        try await store.markPublished(healthyLease)
        #expect(await healthy.publishedRooms() == [healthyLease.wake.roomID])
    }
}

private enum RoutedWakeOwnerStoreFakeError: Error {
    case unavailable
}

private actor RoutedWakeOwnerStoreFake: V2GroupEventWakeStore {
    private var pending: [V2GroupEventWakeLease]
    private let failsClaims: Bool
    private var limits: [Int] = []
    private var published: [RoomID] = []
    private var retried: [RoomID] = []

    init(leases: [V2GroupEventWakeLease], failsClaims: Bool = false) {
        pending = leases
        self.failsClaims = failsClaims
    }

    func claimPending(
        now _: Date,
        leaseDuration _: TimeInterval,
        limit: Int
    ) throws -> [V2GroupEventWakeLease] {
        limits.append(limit)
        if failsClaims { throw RoutedWakeOwnerStoreFakeError.unavailable }
        let count = min(limit, pending.count)
        let claimed = Array(pending.prefix(count))
        pending.removeFirst(count)
        return claimed
    }

    func markPublished(_ lease: V2GroupEventWakeLease) {
        published.append(lease.wake.roomID)
    }

    func scheduleRetry(
        _ lease: V2GroupEventWakeLease,
        nextAttemptAt _: Date
    ) {
        retried.append(lease.wake.roomID)
    }

    func claimLimits() -> [Int] { limits }
    func publishedRooms() -> [RoomID] { published }
    func retriedRooms() -> [RoomID] { retried }
}

private func makeLease(
    roomSuffix: Int,
    tokenSuffix: Int
) throws -> V2GroupEventWakeLease {
    let roomID = try RoomID(String(
        format: "00000000-0000-0000-0000-%012d",
        roomSuffix
    ))
    let token = UUID(uuidString: String(
        format: "10000000-0000-0000-0000-%012d",
        tokenSuffix
    ))!
    return .init(
        wake: .init(roomID: roomID, highWatermark: UInt64(roomSuffix)),
        revision: UInt64(roomSuffix),
        claimToken: token,
        attempt: 1
    )
}
