import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 shard admission lease control plane")
struct V2ShardAdmissionLeaseServiceTests {
    @Test("issue and fenced renewal preserve the identity and counters")
    func issueAndRenew() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let profile = try profile()
        let key = try V2ShardAdmissionPoolKey(roomShardID: "room-shard-a", capacityProfileID: "standard")
        let store = InMemoryV2ShardAdmissionLeaseStore()
        let service = V2ShardAdmissionLeaseService(
            store: store,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000101")! },
            now: { now }
        )

        let issued = try await service.issue(key: key, capacityProfile: profile, lifetime: 30)
        let renewed = try await service.renew(key: key, expectedFence: issued.v2Fence, lifetime: 60)

        #expect(issued.id == renewed.id)
        #expect(issued.generation == renewed.generation)
        #expect(renewed.validUntil == now.addingTimeInterval(60))
        let state = try #require(await store.state(for: key))
        #expect(state.outstandingFanoutUnits == 0)
        #expect(state.lease == renewed)
    }

    @Test("expired replacement advances the fence, resets only windows and retains outstanding work")
    func expiredReplacementRetainsOutstandingWork() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_100)
        let profile = try profile()
        let key = try V2ShardAdmissionPoolKey(roomShardID: "room-shard-a", capacityProfileID: "standard")
        let oldLease = try ShardAdmissionLease(
            id: try .init("00000000-0000-0000-0000-000000000102"),
            generation: 7,
            validUntil: now.addingTimeInterval(-1),
            commandWindow: .init(limit: 10, used: 8),
            fanoutWindow: .init(limit: 100, used: 80),
            maxOutstandingFanoutUnits: 100,
            maxOutstandingPlans: 10
        )
        let store = InMemoryV2ShardAdmissionLeaseStore(seed: [
            (key, try .init(lease: oldLease, outstandingFanoutUnits: 45, outstandingPlans: 3)),
        ])
        let service = V2ShardAdmissionLeaseService(
            store: store,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000103")! },
            now: { now }
        )

        let replacement = try await service.replaceExpired(key: key, capacityProfile: profile, lifetime: 30)

        #expect(replacement.id != oldLease.id)
        #expect(replacement.generation == 8)
        #expect(replacement.commandWindow.used == 0)
        #expect(replacement.fanoutWindow.used == 0)
        let state = try #require(await store.state(for: key))
        #expect(state.outstandingFanoutUnits == 45)
        #expect(state.outstandingPlans == 3)
    }

    @Test("stale renewals and early replacements are rejected")
    func rejectsStaleOrEarlyControlOperations() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_200)
        let profile = try profile()
        let key = try V2ShardAdmissionPoolKey(roomShardID: "room-shard-a", capacityProfileID: "standard")
        let store = InMemoryV2ShardAdmissionLeaseStore()
        let service = V2ShardAdmissionLeaseService(store: store, now: { now })
        let issued = try await service.issue(key: key, capacityProfile: profile, lifetime: 30)
        let stale = V2ShardAdmissionLeaseFence(id: try .init("00000000-0000-0000-0000-000000000104"), generation: 1)

        await #expect(throws: V2ShardAdmissionLeaseControlError.fenceMismatch) {
            try await service.renew(key: key, expectedFence: stale, lifetime: 60)
        }
        await #expect(throws: V2ShardAdmissionLeaseControlError.replacementRequiresExpiredLease) {
            try await service.replaceExpired(key: key, capacityProfile: profile, lifetime: 60)
        }
        #expect(issued.v2Fence != stale)
    }

    private func profile() throws -> V2CapacityProfile {
        try .init(
            id: "standard",
            limits: .init(
                maxEligibleMembers: 100,
                maxCommandsPerWindow: 10,
                maxFanoutUnitsPerWindow: 100,
                maxOutstandingFanoutUnits: 100,
                maxOutstandingPlans: 10,
                maxEnumerationPageSize: 10,
                maxPlannerConcurrency: 1,
                maxDeliveryConcurrency: 1,
                retryAfterSeconds: 3
            )
        )
    }
}
