import Foundation
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import Testing

@Suite("Room dispatch pipeline bounds")
struct V2RoomDispatchBatchBoundsTests {
    @Test("maximum audience pages stay bounded and all durable targets precede source acknowledgement")
    func maximumAudiencePages() async throws {
        let fixture = try DispatchPipelineFixture()
        let worker = V2RoomDispatchWorker(outbox: fixture, projector: fixture, pageSize: 256)
        let report = try await worker.runOnce(limit: 64)
        #expect(report.claimedPages == 64 && report.acknowledgedPages == 64 && report.failedPages == 0)
        #expect(await fixture.acceptedFacts == 64 * 256)
        #expect(await fixture.acknowledged.count == 64)
        #expect(await fixture.largestBatch <= 1024)
    }
}

private actor DispatchPipelineFixture: V2RoomDispatchOutbox, V2RoomDispatchProjecting {
    let leases: [V2RoomDispatchLease]
    let users = (0..<256).map { _ in UserID(uuid: UUID()) }
    var next = 0
    var accepted: [UUID: Set<UserID>] = [:]
    var acknowledged = Set<UUID>()
    var largestBatch = 0
    var acceptedFacts: Int { accepted.values.reduce(0) { $0 + $1.count } }
    init() throws {
        let now = Date()
        leases = try (0..<64).map { _ in
            .init(eventID: UUID(), messageID: nil, roomID: .init(uuid: UUID()), roomSequence: 1,
                  membershipRevision: 0, senderID: nil, mentionedUserIDs: [], mentionsEveryone: false,
                  createdAtTimestamp: try .init(date: now), recipientCursor: nil, token: UUID(), attempt: 1,
                  expiresAt: now.addingTimeInterval(60))
        }
    }
    func claim(now: Date, limit: Int, leaseDuration: TimeInterval) -> [V2RoomDispatchLease] {
        let end = min(leases.count, next + limit)
        defer { next = end }
        return Array(leases[next..<end])
    }
    func recipients(_ lease: V2RoomDispatchLease, limit: Int, now: Date) -> [UserID] { Array(users.prefix(limit)) }
    func project(_ lease: V2RoomDispatchLease, to userID: UserID) { accepted[lease.eventID, default: []].insert(userID) }
    func projectTargets(_ targets: [V2RoomDispatchTarget]) -> Set<UserID> {
        let facts = targets.reduce(0) { $0 + $1.leases.count }
        #expect(facts <= 1024 && targets.count <= 1024)
        largestBatch = max(largestBatch, facts)
        for target in targets { for lease in target.leases { project(lease, to: target.userID) } }
        return Set(targets.map(\.userID))
    }
    func acknowledgePage(_ lease: V2RoomDispatchLease, through cursor: UUID?, now: Date) -> Bool {
        #expect(accepted[lease.eventID] == Set(users))
        acknowledged.insert(lease.eventID)
        return true
    }
    func retry(_ lease: V2RoomDispatchLease, now: Date, after delay: TimeInterval) { Issue.record("unexpected retry") }
}
