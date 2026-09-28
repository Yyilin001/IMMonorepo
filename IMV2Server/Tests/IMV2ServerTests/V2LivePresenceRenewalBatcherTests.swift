import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 live presence renewal batching")
struct V2LivePresenceRenewalBatcherTests {
    @Test("invalid clocks cannot enter or poison a coalesced heartbeat")
    func invalidClockDoesNotEnterBatch() async throws {
        let leases = RecordingRenewalLeases()
        let batcher = V2LivePresenceRenewalBatcher(leases: leases,
            configuration: .init(maximumBatchSize: 1, maximumDelay: .zero))
        let identity = V2AuthenticatedConnection(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), capabilityProfile: "base")
        let connectionID = UUID()
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
            await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) {
                try await batcher.renew(identity: identity, connectionID: connectionID, now: Date(timeIntervalSince1970: seconds))
            }
        }
        #expect(await leases.batchSizes().isEmpty)
        let before = await batcher.snapshot()
        #expect(before.submittedRequests == 0 && before.pendingConnections == 0)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let result = try await batcher.renew(identity: identity, connectionID: connectionID, now: now)
        #expect(result.outcome == .accepted(expiresAt: now.addingTimeInterval(90)))
        #expect(await leases.batchSizes() == [1])
    }

    @Test("concurrent heartbeats share bounded renewal calls")
    func coalescesConcurrentHeartbeats() async throws {
        let leases = RecordingRenewalLeases()
        let batcher = V2LivePresenceRenewalBatcher(
            leases: leases,
            configuration: .init(maximumBatchSize: 16, maximumDelay: .milliseconds(20))
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let accepted = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 1...64 {
                group.addTask {
                    let identity = try V2AuthenticatedConnection(
                        userID: .init(String(format: "00000000-0000-0000-0001-%012d", index)),
                        deviceID: .init(String(format: "00000000-0000-0000-0002-%012d", index)),
                        capabilityProfile: "base"
                    )
                    let refresh = try await batcher.renew(
                        identity: identity,
                        connectionID: UUID(
                            uuidString: String(format: "00000000-0000-0000-0003-%012d", index)
                        )!,
                        now: now
                    )
                    guard case .accepted = refresh.outcome else { return false }
                    return refresh.allowsOnlinePresence
                }
            }
            var results: [Bool] = []
            for try await result in group { results.append(result) }
            return results
        }

        #expect(accepted.count == 64)
        #expect(accepted.allSatisfy { $0 })
        let calls = await leases.batchSizes()
        #expect(calls.reduce(0, +) == 64)
        #expect(calls.count < 64)
        #expect(calls.max() ?? 0 > 1)
        #expect(calls.allSatisfy { $0 <= 16 })
        #expect(await leases.singletonRenewalCalls() == 0)
        let snapshot = await batcher.snapshot()
        #expect(snapshot.submittedRequests == 64)
        #expect(snapshot.executedBatches == UInt64(calls.count))
        #expect(snapshot.failedBatches == 0)
        #expect(snapshot.pendingConnections == 0)
    }

    @Test("a store that omits a renewal fails that connection closed")
    func missingRenewalFailsClosed() async throws {
        let leases = RecordingRenewalLeases(omitResults: true)
        let batcher = V2LivePresenceRenewalBatcher(
            leases: leases,
            configuration: .init(maximumBatchSize: 1, maximumDelay: .zero)
        )
        let identity = try V2AuthenticatedConnection(
            userID: .init("00000000-0000-0000-0000-000000000001"),
            deviceID: .init("00000000-0000-0000-0000-000000000002"),
            capabilityProfile: "base"
        )
        let refresh = try await batcher.renew(
            identity: identity,
            connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            now: Date()
        )

        #expect(refresh.outcome == .rejected)
        #expect(!refresh.allowsOnlinePresence)
    }
}

private actor RecordingRenewalLeases: V2LivePresenceLeaseManaging {
    private let omitResults: Bool
    private var batches: [Int] = []
    private var singletonCalls = 0

    init(omitResults: Bool = false) {
        self.omitResults = omitResults
    }

    func setPresencePublication(identity: V2AuthenticatedConnection, connectionID: UUID,
        suppressed: Bool, now: Date) throws -> V2PresencePublicationLeaseObservation {
        Issue.record("Renewing a lease must not change publication policy")
        throw CancellationError()
    }

    func admitConnection(
        identity _: V2AuthenticatedConnection,
        connectionID _: UUID,
        publicationSuppressed _: Bool,
        policy _: V2AuthenticatedConnectionAdmissionPolicy,
        now: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome {
        .accepted(expiresAt: now.addingTimeInterval(90))
    }

    func renewConnection(
        identity _: V2AuthenticatedConnection,
        connectionID _: UUID,
        now: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome {
        singletonCalls += 1
        return .accepted(expiresAt: now.addingTimeInterval(90))
    }

    func renewConnections(
        _ requests: [V2LivePresenceLeaseRenewalRequest]
    ) -> [UUID: V2LivePresenceLeaseRefresh] {
        batches.append(requests.count)
        guard !omitResults else { return [:] }
        return Dictionary(uniqueKeysWithValues: requests.map { request in
            (
                request.connectionID,
                .init(
                    outcome: .accepted(expiresAt: request.now.addingTimeInterval(90)),
                    allowsOnlinePresence: true
                )
            )
        })
    }

    func removePresence(
        identity _: V2AuthenticatedConnection,
        connectionID _: UUID,
        now _: Date
    ) -> Bool { false }

    func allowsOnlinePresence(userID _: UserID) -> Bool { true }
    func batchSizes() -> [Int] { batches }
    func singletonRenewalCalls() -> Int { singletonCalls }
}
