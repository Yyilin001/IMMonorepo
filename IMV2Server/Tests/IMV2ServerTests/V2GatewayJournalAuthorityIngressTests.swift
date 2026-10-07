import Foundation
import Testing
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerGateway

@Suite("Owned authoritative journal recovery", .timeLimit(.minutes(1)))
struct V2GatewayJournalAuthorityIngressTests {
    @Test("membership targets and member versions survive mixed control recovery admission")
    func mixedMemberAndSessionControls() async throws {
        let user = UserID(uuid: UUID()), a = RoomID(uuid: UUID()), b = RoomID(uuid: UUID()), device = UUID()
        let source = V2RealtimeJournalSource(sourceID: "mixed", incarnationID: UUID(), partitionID: 1)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: .distantFuture, routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: UUID())
        let ready = JournalColdReady()
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init())
        let ingress = V2GatewayJournalAuthorityIngress(receiver: receiver,
            recoverControls: { _, service, cut, controls in
                #expect(service == "trusted" && cut == 3)
                #expect(controls.versions[user] == 3)
                #expect(controls.membershipVersions[user] == 2)
                #expect(controls.membershipRooms[user] == [a, b])
                #expect(controls.devices == [.init(userID: user.uuidValue!, deviceID: device)])
                await ready.finished()
            }, recover: { _, _, _ in Issue.record("lost structured controls") }, notify: { _ in })
        ingress.start()
        let batch = V2RealtimeJournalProjectionBatch(source: source, fence: fence,
            payload: .changes(fromExclusive: 0, throughInclusive: 3, entries: [
                .init(sequence: 1, change: .userControlInvalidation(userID: user, controlVersion: 1,
                    deviceID: nil, membershipRoomID: a)),
                .init(sequence: 2, change: .userControlInvalidation(userID: user, controlVersion: 2,
                    deviceID: nil, membershipRoomID: b)),
                .init(sequence: 3, change: .userControlInvalidation(userID: user, controlVersion: 3, deviceID: device))]))
        #expect(ingress.applyJournalProjection(batch, authenticatedServiceID: "trusted") == .snapshotRequired)
        await ready.wait()
        await ingress.shutdown()
    }

    @Test("baseline requests cannot install remote grants and return only an actual cold commit")
    func trustedColdCommit() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let source = V2RealtimeJournalSource(sourceID: "test-source", incarnationID: UUID(), partitionID: 1)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: .distantFuture, routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: UUID())
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init())
        let ready = JournalColdReady()
        let ingress = V2GatewayJournalAuthorityIngress(receiver: receiver, recover: { batch, service, minimum in
            guard service == "trusted", minimum == 5 else { throw JournalColdError.invalid }
            guard receiver.install(source: source, serviceID: service, fence: fence, deadline: .now + .seconds(10),
                rooms: [room], viewers: [user]) else { throw JournalColdError.invalid }
            let snapshot = V2RealtimeJournalProjectionBatch(source: source, fence: fence,
                payload: .snapshot(cut: 5, rooms: [.init(roomID: room, ownerEpoch: 1,
                    permissionVersion: 1, controlVersion: 1, viewerMembershipRevisions: [user: 1], highWatermark: 3)]))
            guard receiver.authorizeSnapshot(snapshot),
                  case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: service) else {
                throw JournalColdError.invalid
            }
            await ready.finished()
        }, notify: { _ in })
        let request = V2RealtimeJournalProjectionBatch(source: source, fence: fence, payload: .baseline(minimumCut: 5))
        #expect(ingress.applyJournalProjection(request, authenticatedServiceID: "trusted") == .stale)
        ingress.start()
        #expect(ingress.applyJournalProjection(request, authenticatedServiceID: "trusted") == .snapshotRequired)
        await ready.wait()
        guard case .applied(let receipt) = ingress.applyJournalProjection(request, authenticatedServiceID: "trusted") else {
            Issue.record("cold baseline was not committed"); await ingress.shutdown(); return
        }
        #expect(receipt.batchID == request.batchID && receipt.appliedThrough == 5 && receipt.snapshotInstalled)
        await ingress.shutdown()
        #expect(receiver.currentRoom(room) == nil)
        #expect(ingress.applyJournalProjection(request, authenticatedServiceID: "trusted") == .stale)
    }
}
private enum JournalColdError: Error { case invalid }
private actor JournalColdReady {
    var done = false
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !done { await withCheckedContinuation { waiter = $0 } } }
    func finished() { done = true; waiter?.resume(); waiter = nil }
}
