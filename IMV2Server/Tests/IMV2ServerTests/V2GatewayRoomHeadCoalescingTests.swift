import Foundation
import Testing
import Synchronization
import NIOCore
import NIOEmbedded
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerGateway

@Suite("Room head and body socket admission")
struct V2GatewayRoomHeadCoalescingTests {
    @Test func writtenBodyCoversHeadButRejectedBodyDoesNot() throws {
        let f = try Fixture()
        defer { f.writer.finish(); _ = try? f.channel.finish() }
        f.body(11)
        #expect(f.writer.submitRoomHead(f.permit, highWatermark: 11))
        f.loop.run()
        #expect(try f.read() == [11])
        #expect(f.observation.encodes.withLock { $0 } == 0)
        f.body(12, accepted: false)
        #expect(f.writer.submitRoomHead(f.permit, highWatermark: 12))
        f.loop.run()
        #expect(try f.read() == [112])
        #expect(f.observation.encodes.withLock { $0 } == 1)
    }

    @Test func pendingHeadsCoalesceAndResumeOnWritabilityWithoutBody() throws {
        let f = try Fixture()
        defer { f.writer.finish(); _ = try? f.channel.finish() }
        f.channel.isWritable = false
        for h in 11...20 { #expect(f.writer.submitRoomHead(f.permit, highWatermark: UInt64(h))) }
        f.loop.run()
        #expect(try f.read().isEmpty)
        #expect(f.observation.encodes.withLock { $0 } == 0)
        f.channel.isWritable = true
        f.writer.resumeAfterWritabilityChange()
        f.loop.run()
        #expect(try f.read() == [120])
        #expect(f.observation.encodes.withLock { $0 } == 1)
        #expect(f.writer.submitRoomHead(f.permit, highWatermark: 19))
        f.loop.run()
        #expect(try f.read().isEmpty)
        #expect(f.observation.encodes.withLock { $0 } == 1)
    }

    @Test func freshScopeDoesNotInheritSentWatermarkAndRevocationRejectsQueuedWork() throws {
        let f = try Fixture()
        defer { f.writer.finish(); _ = try? f.channel.finish() }
        f.body(20); f.loop.run(); #expect(try f.read() == [20])
        var fresh = f.permit
        fresh = .init(fence: fresh.fence, userID: fresh.userID, memberRevision: fresh.memberRevision,
            connectionID: fresh.connectionID, lifecycle: fresh.lifecycle, scopeGeneration: 2,
            baselineSequence: 10, roomInterestID: UUID(), authorizationID: fresh.authorizationID, socketGate: f.gate)
        _ = f.gate.interest(lifecycle: fresh.lifecycle, roomID: fresh.fence.roomID, generation: 2)
        f.loop.run()
        f.activate(fresh)
        #expect(!f.writer.submitRoomHead(f.permit, highWatermark: 21))
        #expect(f.writer.submitRoomHead(fresh, highWatermark: 10))
        f.loop.run(); #expect(try f.read() == [110])
        _ = f.gate.install(roomID: fresh.fence.roomID, permission: .denied)
        f.loop.run()
        f.body(22)
        #expect(f.writer.submitRoomHead(fresh, highWatermark: 22))
        f.loop.run(); #expect(try f.read().isEmpty)
    }

    @Test func zeroHeadAndConnectionFenceArePreserved() throws {
        let f = try Fixture()
        defer { f.writer.finish(); _ = try? f.channel.finish() }
        #expect(f.writer.submitRoomHead(f.permit, highWatermark: 0))
        f.loop.run(); #expect(try f.read() == [100])
        f.observation.active.withLock { $0 = false }
        #expect(f.writer.submitRoomHead(f.permit, highWatermark: 11))
        f.loop.run(); #expect(try f.read().isEmpty)
        f.writer.finish()
        #expect(!f.writer.submitRoomHead(f.permit, highWatermark: 12))
    }

    @Test func queuedBodiesDrainBeforeAnUncoveredHead() throws {
        let f = try Fixture(maximumDrainFrames: 1)
        defer { f.writer.finish(); _ = try? f.channel.finish() }
        f.body(11); f.body(12); f.body(13)
        #expect(f.writer.submitRoomHead(f.permit, highWatermark: 14))
        f.loop.run()
        #expect(try f.read() == [11, 12, 13, 114])
    }
}

private final class Fixture {
    let channel: EmbeddedChannel
    var loop: EmbeddedEventLoop { channel.embeddedEventLoop }
    let writer: V2NIOGatewayForegroundWriter
    let gate: V2RoomSubscriptionSocketGate
    let permit: V2GatewayRoomSubscriptionAuthority.Permit
    let observation = Observation()
    init(maximumDrainFrames: Int = 32) throws {
        channel = EmbeddedChannel()
        _ = try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
        gate = .init(eventLoop: channel.eventLoop)
        let room = RoomID(uuid: UUID()), lifecycle = UUID()
        let fence = V2RoomSubscriptionFence(activation: .init(roomID: room,
            owner: try .init(shardID: "rooms", epoch: 1), activationEpoch: try .init(1),
            host: .init(hostID: try .init("head-owner"), incarnationID: UUID())),
            subscriptionID: UUID(), generation: 1, baselineSequence: 10)
        permit = .init(fence: fence, userID: UserID(uuid: UUID()), memberRevision: 1,
            connectionID: UUID(), lifecycle: lifecycle, scopeGeneration: 1, baselineSequence: 10,
            roomInterestID: UUID(), authorizationID: UUID(), socketGate: gate)
        let session = V2RoomDeliverySessionGate(session: .init(host: fence.activation.host,
            gateway: .init(nodeID: "head-gateway", serviceID: "head-gateway", incarnationID: UUID()), generation: 1), serviceID: "owner")
        _ = gate.register(lifecycle: lifecycle)
        _ = gate.interest(lifecycle: lifecycle, roomID: room, generation: 1)
        _ = gate.install(roomID: room, permission: .init(fence: fence, session: session,
            authorizationID: permit.authorizationID, memberRevision: 1))
        writer = .init(channel: channel, scheduler: .init(), maximumDrainFrames: maximumDrainFrames)
        loop.run()
        activate(permit)
    }
    func activate(_ permit: V2GatewayRoomSubscriptionAuthority.Permit) {
        let gate = gate, observation = observation
        writer.activateRoomHead(permit, enqueueIfCurrent: { body in
            guard observation.active.withLock({ $0 }) else { return false }
            return gate.enqueue(permit, now: .now, body: body)
        }, encode: { h in observation.encodes.withLock { $0 += 1 }; return ByteBuffer(bytes: [UInt8(h + 100)]) })
    }
    func body(_ h: UInt64, accepted: Bool = true) {
        let gate = gate, permit = permit
        writer.submit(ByteBuffer(bytes: [UInt8(h)]), isAuthorizedToWrite: { accepted }, enqueueIfCurrent: { write in
            gate.enqueue(permit, now: .now) { write(); gate.recordSubmittedHead(permit, highWatermark: h) }
        })
    }
    func read() throws -> [UInt8] {
        var bytes: [UInt8] = []
        while let b = try channel.readOutbound(as: ByteBuffer.self) { bytes.append(contentsOf: b.readableBytesView) }
        return bytes
    }
}

private final class Observation: Sendable {
    let encodes = Mutex(0)
    let active = Mutex(true)
}
