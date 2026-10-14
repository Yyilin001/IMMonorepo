import Foundation
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerGateway
@testable import IMV2ServerApp

@Suite("Trusted Journal control catch-up")
struct GatewayJournalControlCatchUpTests {
    @Test("a late rejected recovery cannot retire a successor binding")
    func conditionalRetirement() throws {
        let f = try fixture(), old = f.fence
        let next = V2RealtimeJournalProjectionFence(publisherIncarnationID: old.publisherIncarnationID,
            sourceLeaseEpoch: old.sourceLeaseEpoch + 1, sourceLeaseToken: UUID(), sourceLeaseExpiresAt: .distantFuture,
            routingPartitionEpoch: old.routingPartitionEpoch, routingLeaseToken: old.routingLeaseToken,
            sessionID: old.sessionID, interestGeneration: old.interestGeneration, gatewayIncarnationID: old.gatewayIncarnationID)
        try #require(f.receiver.install(source: f.source, serviceID: "host", fence: next,
            deadline: .now + .seconds(60), rooms: [], viewers: []))
        f.receiver.retire(source: f.source, fence: old)
        #expect(f.receiver.recoveryBindingSnapshot(source: f.source)?.fence == next)
        #expect(f.receiver.recoveryCheckpoint(source: f.source, fence: next, minimumCut: 0) == nil)
        f.receiver.retire(source: f.source, fence: next)
        #expect(f.receiver.recoveryBindingSnapshot(source: f.source) == nil)
    }
    @Test("blocked projection retains only previously installed same-generation floors")
    func retainedFloors() throws {
        let f = try fixture()
        let projected = V2RealtimeJournalProjectionBatch(source: f.source, fence: f.fence,
            payload: .changes(fromExclusive: 0, throughInclusive: 1, entries: [
                .init(sequence: 1, change: .userControlInvalidation(userID: f.user, controlVersion: 4, deviceID: nil, membershipRoomID: nil))]))
        #expect(f.receiver.applyJournalProjection(projected, authenticatedServiceID: "host") == .snapshotRequired)
        #expect(f.receiver.recoveryCheckpoint(source: f.source, fence: f.fence, minimumCut: 0) == nil)
        #expect(f.receiver.retainsRecoveryFloors(source: f.source, fence: f.fence, versions: [f.user: 3]))
        #expect(!f.receiver.retainsRecoveryFloors(source: f.source, fence: f.fence, versions: [f.user: 4]))
        #expect(!f.receiver.retainsRecoveryFloors(source: f.source, fence: f.fence, versions: [UserID(uuid: UUID()): 0]))
        f.receiver.retire(source: f.source)
        #expect(!f.receiver.retainsRecoveryFloors(source: f.source, fence: f.fence, versions: [f.user: 3]))
    }
    private struct Fixture {
        let user: UserID
        let source: V2RealtimeJournalSource
        let fence: V2RealtimeJournalProjectionFence
        let receiver: V2GatewayJournalProjectionReceiver
    }
    private func fixture() throws -> Fixture {
        let user = UserID(uuid: UUID()), source = V2RealtimeJournalSource(sourceID: "source", incarnationID: UUID(), partitionID: 1)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: .distantFuture, routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: UUID())
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init())
        try #require(receiver.install(source: source, serviceID: "host", fence: fence,
            deadline: .now + .seconds(60), rooms: [], viewers: []))
        try #require(receiver.installUserControlFloors(source: source, fence: fence, versions: [user: 3]))
        let snapshot = V2RealtimeJournalProjectionBatch(source: source, fence: fence, payload: .snapshot(cut: 0, rooms: []))
        try #require(receiver.authorizeSnapshot(snapshot))
        guard case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: "host") else { throw CatchUpError.initialSnapshot }
        return .init(user: user, source: source, fence: fence, receiver: receiver)
    }

}
private enum CatchUpError: Error { case initialSnapshot }
