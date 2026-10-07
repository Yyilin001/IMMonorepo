import Foundation
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
@testable import IMV2ServerApp

struct GatewayJournalRuntimeTests {
    @Test func productionJournalRetainsOnlyUserControlsAndOrderedCut() {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: .distantFuture, routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: UUID())
        let source = V2RealtimeJournalSource(sourceID: "source", incarnationID: UUID(), partitionID: 1)
        let userControl = V2RealtimeJournalProjectionEntry(sequence: 12,
            change: .userControlInvalidation(userID: user, controlVersion: 7, deviceID: nil, membershipRoomID: room))
        let input = V2RealtimeJournalProjectionBatch(source: source, fence: fence,
            payload: .changes(fromExclusive: 10, throughInclusive: 14, entries: [
                .init(sequence: 11, change: .head(roomID: room, highWatermark: 99, ownerEpoch: 0, permissionVersion: 1)),
                userControl,
                .init(sequence: 13, change: .controlInvalidation(roomID: room, ownerEpoch: 0, controlVersion: 2)),
                .init(sequence: 14, change: .invalidate(roomID: room))]))
        let filtered = GatewayJournalRuntime.userControlProjection(input)
        #expect(filtered.source == source && filtered.fence == fence)
        #expect(filtered.payload == .changes(fromExclusive: 10, throughInclusive: 14, entries: [userControl]))
        let grant = V2RealtimeJournalRoomAuthorization(roomID: room, ownerEpoch: 0, permissionVersion: 1,
            controlVersion: 2, viewerMembershipRevisions: [user: 0], highWatermark: 99)
        #expect(GatewayJournalRuntime.userControlProjection(.init(source: source, fence: fence,
            payload: .snapshot(cut: 14, rooms: [grant]))).payload == .snapshot(cut: 14, rooms: []))
        #expect(GatewayJournalRuntime.userControlProjection(.init(source: source, fence: fence,
            payload: .heads([.init(roomID: room, highWatermark: 99, ownerEpoch: 0, controlVersion: 2)]))).payload == .heads([]))
    }

    @Test func routingLeaseCannotRenewSourceBinding() {
        let host = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "gateway-service", incarnationID: UUID())
        let sourceToken = UUID(), routingToken = UUID()
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: host.incarnationID,
            sourceLeaseEpoch: 9, sourceLeaseToken: sourceToken, sourceLeaseExpiresAt: .distantFuture,
            routingPartitionEpoch: 4, routingLeaseToken: routingToken, sessionID: UUID(),
            interestGeneration: 2, gatewayIncarnationID: UUID())
        let routing = V2RealtimePartitionLease(partitionID: 3, identity: host, epoch: 4,
            token: routingToken, remainingLeaseSeconds: 30)
        #expect(!GatewayJournalRuntime.matchesSourceLease(routing, fence: fence, host: host))
        let source = V2RealtimePartitionLease(partitionID: 3, identity: host, epoch: 9,
            token: sourceToken, remainingLeaseSeconds: 30)
        #expect(GatewayJournalRuntime.matchesSourceLease(source, fence: fence, host: host))
        let replacement = V2RealtimePartitionLease(partitionID: 3, identity: host, epoch: 10,
            token: UUID(), remainingLeaseSeconds: 30)
        #expect(!GatewayJournalRuntime.matchesSourceLease(replacement, fence: fence, host: host))
    }
    @Test func wireWallClockCannotEstablishSourceAuthority() {
        let host = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "gateway-service", incarnationID: UUID())
        let token = UUID()
        let lease = V2RealtimePartitionLease(partitionID: 2, identity: host, epoch: 1,
            token: token, remainingLeaseSeconds: 3)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: host.incarnationID,
            sourceLeaseEpoch: 1, sourceLeaseToken: token, sourceLeaseExpiresAt: .distantPast,
            routingPartitionEpoch: 99, routingLeaseToken: UUID(), sessionID: UUID(),
            interestGeneration: 2, gatewayIncarnationID: UUID())
        #expect(GatewayJournalRuntime.matchesSourceLease(lease, fence: fence, host: host))
        let other = V2GatewayRealtimeIdentity(nodeID: host.nodeID, serviceID: host.serviceID, incarnationID: UUID())
        #expect(!GatewayJournalRuntime.matchesSourceLease(lease, fence: fence, host: other))
    }
}
