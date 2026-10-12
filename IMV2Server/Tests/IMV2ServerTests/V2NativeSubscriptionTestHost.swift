import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2ServerApplication
import Testing
@testable import IMV2ActorCluster
@testable import IMV2Server

/// Subscription tests obtain capabilities from a real Host restoration. No
/// serialized token or test constructor can manufacture an activation lifetime.
final class V2NativeSubscriptionLifetimes: Sendable {
    let values = Mutex<[RoomID: V2RoomActivationLifetime]>([:])
}

final class V2NativeSubscriptionTestHost: Sendable {
    private let host: V2RoomActivationHost<Int, Int>
    private let placement: V2RoomActorPlacementRuntime
    private let shardID: String
    private let lifetimes: V2NativeSubscriptionLifetimes
    private let subscriptions = Mutex<[V2RoomSubscriptionHost]>([])

    init(host: V2RoomActivationHost<Int, Int>, placement: V2RoomActorPlacementRuntime,
         lifetimes: V2NativeSubscriptionLifetimes, shardID: String) {
        self.host = host; self.placement = placement; self.lifetimes = lifetimes; self.shardID = shardID
    }

    func activate(_ room: RoomID) async throws -> (token: V2RoomActivationToken, lifetime: V2RoomActivationLifetime) {
        guard case .ready(let token) = try await host.activate(roomID: room,
            owner: .init(shardID: shardID, epoch: 0), deadline: .now + .seconds(30)) else {
            throw V2RoomCallFailure.notAccepted(.notReady)
        }
        let lifetime = try #require(lifetimes.values.withLock { $0[room] })
        return (token, lifetime)
    }

    func own(_ subscription: V2RoomSubscriptionHost) { subscriptions.withLock { $0.append(subscription) } }

    func drain(deadline: ContinuousClock.Instant) async -> V2RoomActivationDrainResult {
        await host.drain(deadline: deadline)
    }

    func stop() async throws {
        for subscription in subscriptions.withLock({ $0 }) { await subscription.close() }
        let proof = try #require(await host.stop(deadline: .now + .seconds(30)).proof)
        try await placement.retireAfterDrain(proof, shards: [shardID])
    }
}

func withNativeSubscriptionTestHost<Value: Sendable>(
    shardID: String = "subscription-test",
    _ body: @escaping @Sendable (V2NativeSubscriptionTestHost) async throws -> Value
) async throws -> Value {
    let identity = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
    return try await withNativePlacementTestControl(host: identity, shardID: shardID) { control in
        let placement = try await control.register(identity, shard: shardID)
        let lifetimes = V2NativeSubscriptionLifetimes()
        let configuration = try V2RoomRuntimeConfiguration()
        let host = V2RoomActivationHost<Int, Int>(identity: identity, placement: placement,
            configuration: configuration, budget: .init(configuration: configuration), classify: { _ in .barrier },
            factory: .init { token in
                .init(restore: { context in
                    try await context.validate()
                    lifetimes.values.withLock { $0[token.roomID] = context.lifetime }
                }, execute: { .committed($0.items.map { $0.request }) },
                invalidateReservation: { _ in }, close: {})
            })
        let fixture = V2NativeSubscriptionTestHost(host: host, placement: placement, lifetimes: lifetimes, shardID: shardID)
        await host.start()
        do {
            let value = try await body(fixture)
            try await fixture.stop()
            return value
        } catch {
            try await fixture.stop()
            throw error
        }
    }
}
