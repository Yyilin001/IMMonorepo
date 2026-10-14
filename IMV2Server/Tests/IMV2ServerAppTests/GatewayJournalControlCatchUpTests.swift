import Foundation
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerGateway
@testable import IMV2ServerApp

@Suite("Trusted Journal control catch-up")
struct GatewayJournalControlCatchUpTests {
    @Test("unrelated and already-installed controls advance without a user snapshot")
    func unchangedControls() throws {
        let f = try fixture()
        let other = UserID(uuid: UUID())
        let entries = [
            entry(sequence: 1, user: other, version: 50),
            entry(sequence: 2, user: f.user, version: 3)]
        let batch = V2RealtimeJournalBatch(partitionID: 1, publishedThrough: 2, trimmedThrough: 0, requiresSnapshot: false, entries: entries)
        let cut = GatewayJournalControlCatchUp.apply(batch, after: 0, source: f.source,
            fence: f.fence, service: "host", localUsers: [f.user], receiver: f.receiver)
        #expect(cut == 2)
        #expect(f.receiver.recoveryCheckpoint(source: f.source, fence: f.fence, minimumCut: 2) == 2)
    }
    @Test("newer local policy blocks the projection instead of granting from a replay")
    func newerControl() throws {
        let f = try fixture()
        let batch = V2RealtimeJournalBatch(partitionID: 1, publishedThrough: 1, trimmedThrough: 0, requiresSnapshot: false,
            entries: [entry(sequence: 1, user: f.user, version: 4)])
        #expect(GatewayJournalControlCatchUp.apply(batch, after: 0, source: f.source, fence: f.fence,
            service: "host", localUsers: [f.user], receiver: f.receiver) == nil)
        #expect(f.receiver.recoveryCheckpoint(source: f.source, fence: f.fence, minimumCut: 0) == nil)
    }
    @Test("trimmed, missing, opaque and expired evidence require a baseline", arguments: [0,1,2,3])
    func missingEvidence(kind: Int) throws {
        let f = try fixture()
        var row = entry(sequence: kind == 1 ? 2 : 1, user: f.user, version: 3)
        if kind == 2 { row = .init(partitionID: 1, sequence: 1, sourceEventID: UUID(), topicKind: "userSync", topicID: f.user.rawValue, changeKind: "legacy") }
        if kind == 3 { f.receiver.retire(source: f.source) }
        let batch = V2RealtimeJournalBatch(partitionID: 1, publishedThrough: 2, trimmedThrough: kind == 0 ? 1 : 0,
            requiresSnapshot: kind == 0, entries: [row])
        #expect(GatewayJournalControlCatchUp.apply(batch, after: 0, source: f.source, fence: f.fence,
            service: "host", localUsers: [f.user], receiver: f.receiver) == nil)
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
    private func entry(sequence: Int64, user: UserID, version: Int64) -> V2RealtimeJournalEntry {
        .init(partitionID: 1, sequence: sequence, sourceEventID: UUID(), topicKind: "userSync",
            topicID: user.rawValue, changeKind: "userControl", userControlVersion: version)
    }
}
private enum CatchUpError: Error { case initialSnapshot }
