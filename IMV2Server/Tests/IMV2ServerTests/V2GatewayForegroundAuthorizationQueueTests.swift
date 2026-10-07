@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import IMV2ActorContracts
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import NIOCore
import NIOEmbedded
import Synchronization
import Testing
@testable import IMV2ServerGateway

@Suite("V2 gateway foreground authorization at write time")
struct V2GatewayForegroundAuthorizationQueueTests {
    @Test("each extracted NIO frame checks its captured projection at actual channel enqueue")
    func projectionRevokedBetweenFrames() throws {
        let channel = EmbeddedChannel()
        _ = try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
        channel.isWritable = false
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init())
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let source = V2RealtimeJournalSource(sourceID: "fixture", incarnationID: UUID(), partitionID: 1)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: Date().addingTimeInterval(30), routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: UUID())
        #expect(receiver.install(source: source, serviceID: "fixture", fence: fence,
            deadline: .now + .seconds(30), rooms: [room], viewers: [user]))
        let snapshot = V2RealtimeJournalProjectionBatch(source: source, fence: fence,
            payload: .snapshot(cut: 1, rooms: [.init(roomID: room, ownerEpoch: 1,
                permissionVersion: 1, controlVersion: 1, viewerMembershipRevisions: [user: 1], highWatermark: 1)]))
        #expect(receiver.authorizeSnapshot(snapshot))
        guard case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: "fixture") else {
            Issue.record("snapshot not installed"); return
        }
        let writer = V2NIOGatewayForegroundWriter(channel: channel, scheduler: .init())
        writer.submit(ByteBuffer(bytes: [1]), isAuthorizedToWrite: { true }, enqueueIfCurrent: { enqueue in
            let accepted = receiver.enqueueAuthorized(roomID: room, userID: user, memberRevision: 1,
                expectedSource: source, expectedFence: fence, enqueue: enqueue)
            // The first frame has actually entered the channel. Retire before
            // the next frame from this same extracted FIFO batch can enqueue.
            receiver.retire(source: source)
            return accepted
        })
        writer.submit(ByteBuffer(bytes: [2]), isAuthorizedToWrite: { true }, enqueueIfCurrent: { enqueue in
            receiver.enqueueAuthorized(roomID: room, userID: user, memberRevision: 1,
                expectedSource: source, expectedFence: fence, enqueue: enqueue)
        })
        channel.embeddedEventLoop.run()
        channel.isWritable = true
        writer.resumeAfterWritabilityChange()
        channel.embeddedEventLoop.run()
        #expect(try channel.readOutbound(as: ByteBuffer.self) == ByteBuffer(bytes: [1]))
        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)
        #expect(!writer.hasPendingFrames)
        #expect(try channel.finish().isClean)
        receiver.shutdown()
    }

    @Test("an expired or revoked queued frame is omitted when writability returns", arguments: [false, true])
    func queuedFrameRevokedBeforeDrain(expires: Bool) throws {
        let channel = EmbeddedChannel()
        _ = try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
        channel.isWritable = false
        let clock = Mutex(10)
        let authorization = V2GatewayForegroundAuthorization(sessionIsLive: { clock.withLock { $0 < 11 } })
        let writer = V2NIOGatewayForegroundWriter(channel: channel, scheduler: .init())
        writer.submit(ByteBuffer(bytes: [1]), isAuthorizedToWrite: { authorization.isAuthorizedToWrite() })
        channel.embeddedEventLoop.run()
        if expires { clock.withLock { $0 = 11 } }
        else { authorization.invalidate() }
        channel.isWritable = true
        writer.resumeAfterWritabilityChange()
        channel.embeddedEventLoop.run()

        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)
        #expect(!writer.hasPendingFrames)
        #expect(try channel.finish().isClean)
    }
}
