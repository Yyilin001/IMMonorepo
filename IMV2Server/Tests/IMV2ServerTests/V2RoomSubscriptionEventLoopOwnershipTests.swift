import Foundation
import Synchronization
import Testing
import NIOCore
import NIOPosix
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerGateway

@Suite("Room actor and connection EventLoop ownership", .serialized, .timeLimit(.minutes(1)))
struct V2RoomSubscriptionEventLoopOwnershipTests {
    @Test("revocation acknowledgement fences delayed socket writes and resubscribe cannot revive old permits")
    func revocationBarrier() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let loop = group.next(), f = Fixture()
            let authority = V2GatewayRoomSubscriptionAuthority()
            let gate = try await loop.submit { V2RoomSubscriptionSocketGate(eventLoop: loop) }.get()
            #expect(authority.registerConnection(f.connection, userID: f.user, lifecycle: f.lifecycle))
            await authority.bindSocket(f.connection, lifecycle: f.lifecycle, gate: gate)
            #expect(await authority.registerRoomInterest(connectionID: f.connection, lifecycle: f.lifecycle,
                roomID: f.room, scopeGeneration: 1))
            try await f.baseline(authority)
            let permit = try #require(await authority.capturePermits(roomID: f.room).first)
            let writes = Mutex(0)
            #expect(try await loop.submit { authority.enqueueIfCurrent(permit) { writes.withLock { $0 += 1 } } }.get())
            #expect(await authority.apply(f.delivery(2, .revoke(userID: f.user, memberRevision: 1)),
                authenticatedServiceID: "owner") == .applied(permits: []))
            #expect(try await loop.submit { authority.enqueueIfCurrent(permit) { writes.withLock { $0 += 1 } } }.get() == false)
            #expect(await authority.apply(f.delivery(3, .grant(member: f.member, baselineSequence: 10)),
                authenticatedServiceID: "owner") == .applied(permits: []))
            #expect(try await loop.submit { authority.enqueueIfCurrent(permit) { writes.withLock { $0 += 1 } } }.get() == false)
            let fresh = try #require(await authority.capturePermits(roomID: f.room).first)
            #expect(try await loop.submit { authority.enqueueIfCurrent(fresh) { writes.withLock { $0 += 1 } } }.get())
            #expect(writes.withLock { $0 } == 2)
            await authority.shutdown()
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }

    @Test("a retiring room waits for its connection projection while other room actors continue")
    func independentRooms() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let unblock = DispatchSemaphore(value: 0)
        do {
            let loop = group.next(), f = Fixture(), other = Fixture()
            let authority = V2GatewayRoomSubscriptionAuthority(maximumRooms: 2)
            let gate = try await loop.submit { V2RoomSubscriptionSocketGate(eventLoop: loop) }.get()
            #expect(authority.registerConnection(f.connection, userID: f.user, lifecycle: f.lifecycle))
            await authority.bindSocket(f.connection, lifecycle: f.lifecycle, gate: gate)
            try await f.baseline(authority)
            let oldPermit = try #require(await authority.captureOnlinePermits(roomID: f.room).first)
            try await other.baseline(authority)
            let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            loop.execute { started.continuation.yield(()); unblock.wait() }
            var starts = started.stream.makeAsyncIterator()
            _ = await starts.next()
            let completed = Mutex(false)
            let retiring = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let revoked = Task {
                retiring.continuation.yield(())
                let accepted = await authority.retire(fence: f.fence)
                completed.withLock { $0 = true }
                return accepted
            }
            var retireStarts = retiring.stream.makeAsyncIterator()
            _ = await retireStarts.next()
            #expect(authority.enqueueIfCurrent(oldPermit, enqueue: {}) == false)
            #expect(completed.withLock { $0 } == false)
            // The first room is waiting for its projection acknowledgement.
            // This second room must finish without releasing that EventLoop.
            #expect(await authority.pause(fence: other.fence))
            #expect(completed.withLock { $0 } == false)
            let next = Fixture()
            #expect(await authority.installTestSession(fence: next.fence, serviceID: "owner") == false)
            unblock.signal()
            #expect(await revoked.value)
            try await next.baseline(authority)
            await authority.shutdown()
            try await group.shutdownGracefully()
        } catch { unblock.signal(); try? await group.shutdownGracefully(); throw error }
    }

    @Test("interest replacement and connection close reject already captured permits on the EventLoop")
    func lifecycleAndInterest() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let loop = group.next(), f = Fixture()
            let authority = V2GatewayRoomSubscriptionAuthority()
            let gate = try await loop.submit { V2RoomSubscriptionSocketGate(eventLoop: loop) }.get()
            #expect(authority.registerConnection(f.connection, userID: f.user, lifecycle: f.lifecycle))
            await authority.bindSocket(f.connection, lifecycle: f.lifecycle, gate: gate)
            #expect(await authority.registerRoomInterest(connectionID: f.connection, lifecycle: f.lifecycle,
                roomID: f.room, scopeGeneration: 1))
            try await f.baseline(authority)
            let old = try #require(await authority.capturePermits(roomID: f.room).first)
            let account = try #require(await authority.captureOnlinePermits(roomID: f.room).first)
            await authority.removeRoomInterest(connectionID: f.connection, lifecycle: f.lifecycle, roomID: f.room, scopeGeneration: 1)
            #expect(try await loop.submit { authority.enqueueIfCurrent(old, enqueue: {}) }.get() == false)
            #expect(try await loop.submit { authority.enqueueIfCurrent(account, enqueue: {}) }.get())
            #expect(await authority.registerRoomInterest(connectionID: f.connection, lifecycle: f.lifecycle,
                roomID: f.room, scopeGeneration: 2))
            #expect(try await loop.submit { authority.enqueueIfCurrent(old, enqueue: {}) }.get() == false)
            authority.removeConnection(f.connection, lifecycle: f.lifecycle)
            #expect(try await loop.submit { authority.enqueueIfCurrent(account, enqueue: {}) }.get() == false)
            await authority.shutdown()
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}

private struct Fixture: Sendable {
    let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
    let connection = UUID(), lifecycle = UUID(), subscription = UUID()
    var member: V2RoomSubscriptionMember { .init(userID: user, memberRevision: 1) }
    var fence: V2RoomSubscriptionFence {
        .init(activation: .init(roomID: room, owner: try! .init(shardID: "rooms", epoch: 1),
            activationEpoch: try! .init(1), host: .init(hostID: try! .init("event-loop-owner"), incarnationID: lifecycle)),
            subscriptionID: subscription, generation: 1, baselineSequence: 10)
    }
    func delivery(_ sequence: UInt64, _ payload: V2RoomSubscriptionPayload) -> V2RoomSubscriptionDelivery {
        .init(fence: fence, deliverySequence: sequence, authorizationSequence: sequence, payload: payload)
    }
    func baseline(_ authority: V2GatewayRoomSubscriptionAuthority) async throws {
        try #require(await authority.installTestSession(fence: fence, serviceID: "owner"))
        try #require(await authority.apply(delivery(1, .baseline(members: [member])), authenticatedServiceID: "owner") == .applied(permits: []))
    }
}
