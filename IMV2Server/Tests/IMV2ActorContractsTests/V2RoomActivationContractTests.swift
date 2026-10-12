import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing

@Suite("Room activation identity and wire boundary")
struct V2RoomActivationContractTests {
    @Test("untrusted decoding cannot bypass epoch and duration constraints")
    func rejectsInvalidWireValues() throws {
        for value in ["0", "-1", "9223372036854775808"] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(V2ActorEpoch.self, from: Data(value.utf8))
            }
        }
        for value in ["0", "-1", "3600001"] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(V2ActorMilliseconds.self, from: Data(value.utf8))
            }
        }
        #expect(try JSONDecoder().decode(
            V2ActorEpoch.self, from: Data("9223372036854775807".utf8)
        ).rawValue == Int64.max)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                V2RoomDataOwner.self, from: Data(#"{"shardID":"  ","epoch":1}"#.utf8)
            )
        }
    }

    @Test("owner routes preserve main's zero epoch and shard normalization")
    func legacyOwnerIdentity() throws {
        let owner = try V2RoomDataOwner(shardID: " zone/a ", epoch: 0)
        #expect(owner.shardID == "zone/a")
        #expect(try JSONDecoder().decode(
            V2RoomDataOwner.self, from: JSONEncoder().encode(owner)
        ) == owner)
        #expect(throws: V2ActorContractError.invalidEpoch) {
            try JSONDecoder().decode(
                V2RoomDataOwner.self, from: Data(#"{"shardID":"primary","epoch":-1}"#.utf8)
            )
        }
    }

    @Test("token round trip preserves all four independent identity boundaries")
    func tokenRoundTripAndGenerationOrdering() throws {
        let token = try makeToken()
        let decoded = try JSONDecoder().decode(
            V2RoomActivationToken.self, from: JSONEncoder().encode(token)
        )
        #expect(decoded == token)
        #expect(try makeToken(activationEpoch: 2).isNewer(than: token))
        #expect(try makeToken(ownerEpoch: 2).isNewer(than: token))
        #expect(!(try makeToken(room: "other").isNewer(than: token)))
        #expect(!(try makeToken(shard: "other").isNewer(than: token)))
        let restarted = try makeToken(incarnation: UUID())
        #expect(restarted != token)
        #expect(!restarted.isNewer(than: token))
    }

    @Test("placement epochs fence process counters and exact incarnations")
    func placementIdentityBounds() throws {
        let host = try makeToken().host
        for epoch: UInt64 in [0, V2RoomActorPlacementGrant.maximumEpoch + 1] {
            #expect(throws: V2ActorContractError.invalidEpoch) {
                try V2RoomActorPlacementGrant(host: host, epoch: epoch)
            }
        }
        let grant = try V2RoomActorPlacementGrant(host: host, epoch: 1)
        #expect(throws: V2ActorContractError.invalidEpoch) { try grant.activationEpoch(counter: 0) }
        let first = try makeToken(activationEpoch: grant.activationEpoch(counter: 1).rawValue)
        let reopened = try makeToken(activationEpoch: grant.activationEpoch(counter: 2).rawValue)
        #expect(grant.matches(first))
        #expect(grant.matches(reopened))
        #expect(reopened.isNewer(than: first))
        #expect(!grant.matches(try makeToken(activationEpoch: Int64(1) << 32)))
        #expect(!grant.matches(try makeToken(activationEpoch: first.activationEpoch.rawValue, incarnation: UUID())))
        let successor = try V2RoomActorPlacementGrant(host: host, epoch: 2)
        #expect(!successor.matches(first))
        let successorEpoch = try successor.activationEpoch(counter: 1)
        let previousMaximum = try grant.activationEpoch(counter: .max)
        #expect(successorEpoch.rawValue > previousMaximum.rawValue)
        let maximum = try V2RoomActorPlacementGrant(host: host, epoch: V2RoomActorPlacementGrant.maximumEpoch)
        #expect(try maximum.activationEpoch(counter: .max).rawValue == Int64.max)
    }

    @Test("unknown completion retries only capabilities with durable identity")
    func unknownCompletionClassification() {
        let unknown = V2RoomCallFailure.outcomeUnknown
        #expect(unknown.retryAction(policy: .durableIdempotent, hasStableOperationID: true)
            == .retrySameOperation)
        #expect(unknown.retryAction(policy: .durableIdempotent, hasStableOperationID: false)
            == .reconcile)
        #expect(unknown.retryAction(policy: .noAutomaticRetry, hasStableOperationID: true)
            == .reconcile)
        #expect(unknown.retryAction(policy: .readOnly, hasStableOperationID: false) == .retryRead)
    }

    @Test("routing rejections differ from authorization, cancellation, and overload")
    func rejectionClassificationAndCoding() throws {
        for failure in [
            V2RoomCallFailure.notAccepted(.forbidden),
            .notAccepted(.cancelled), .notAccepted(.overloaded),
            .rolledBack(.idempotencyConflict),
        ] {
            #expect(failure.retryAction(policy: .durableIdempotent, hasStableOperationID: true)
                == .returnFailure)
        }
        let stale = V2RoomCallFailure.notAccepted(.staleActivation)
        #expect(stale.retryAction(policy: .noAutomaticRetry, hasStableOperationID: false)
            == .refreshLocation)
        for failure in [stale, .outcomeUnknown, .rolledBack(.unavailable)] {
            #expect(try JSONDecoder().decode(
                V2RoomCallFailure.self, from: JSONEncoder().encode(failure)
            ) == failure)
        }
    }

    @Test("configuration rejects unbounded admission and impossible deadline relationships")
    func configurationBounds() throws {
        let configuration = try V2RoomRuntimeConfiguration()
        #expect(configuration.maximumConcurrentRestores <= configuration.maximumActiveRooms)
        #expect(throws: (any Error).self) {
            try V2RoomRuntimeConfiguration(maximumQueuedCommandsPerRoom: 0)
        }
        #expect(throws: (any Error).self) {
            try V2RoomRuntimeConfiguration(maximumQueuedBytesPerHost: 1_024)
        }
        #expect(throws: (any Error).self) {
            try V2RoomRuntimeConfiguration(maximumRequestBytes: 8 * 1_024 * 1_024)
        }
        #expect(throws: (any Error).self) {
            try V2RoomRuntimeConfiguration(transactionTimeoutMilliseconds: 29_000)
        }
        #expect(throws: (any Error).self) {
            try V2RoomRuntimeConfiguration(callTimeoutMilliseconds: 0)
        }
        #expect(throws: (any Error).self) {
            try V2RoomRuntimeConfiguration(maximumPendingActivations: 0)
        }
        #expect(throws: (any Error).self) {
            try V2RoomRuntimeConfiguration(maximumActivationWaitersPerHost: 128)
        }
        #expect(throws: (any Error).self) {
            try V2RoomRuntimeConfiguration(maximumConcurrentResolutions: 0)
        }
        #expect(throws: (any Error).self) {
            try V2RoomRuntimeConfiguration(maximumCachedLocations: 0)
        }
    }

    private func makeToken(
        room: String = "room", shard: String = "primary", ownerEpoch: Int64 = 1,
        activationEpoch: Int64 = 1,
        incarnation: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    ) throws -> V2RoomActivationToken {
        try V2RoomActivationToken(
            roomID: RoomID(room),
            owner: V2RoomDataOwner(shardID: shard, epoch: ownerEpoch),
            activationEpoch: V2ActorEpoch(activationEpoch),
            host: V2ActorHostIdentity(hostID: V2ActorHostID("host-a"), incarnationID: incarnation)
        )
    }
}
