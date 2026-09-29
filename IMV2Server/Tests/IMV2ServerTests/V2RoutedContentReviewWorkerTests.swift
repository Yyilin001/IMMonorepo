@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 routed content review worker")
struct V2RoutedContentReviewWorkerTests {
    @Test("invalid batch limits fail before calling any room owner")
    func rejectsInvalidLimits() async throws {
        let owner = RoutedReviewProgressor(result: .success(.init(claimedCount: 0, resolvedCount: 0, redactedCount: 0, releasedCount: 0)))
        let worker = try V2RoutedContentReviewWorker(progressors: [owner])
        for limit in [Int.min, -1, 0] {
            await #expect(throws: V2ContentReviewWorkerError.invalidLimit) { try await worker.runOnce(limitPerOwner: limit) }
        }
        #expect(await owner.limits().isEmpty)
    }

    @Test("aggregate budget rejects overflow before starting owners", arguments: [2, 3])
    func aggregateBudgetBounds(ownerCount: Int) async throws {
        let owner = RoutedReviewProgressor(result: .success(.init(
            claimedCount: 0, resolvedCount: 0, redactedCount: 0, releasedCount: 0
        )))
        let worker = try V2RoutedContentReviewWorker(
            progressors: Array(repeating: owner, count: ownerCount)
        )
        for limit in [Int.max / ownerCount + 1, Int.max] {
            await #expect(throws: V2ContentReviewWorkerError.invalidLimit) {
                try await worker.runOnce(limitPerOwner: limit)
            }
        }
        #expect(await owner.limits().isEmpty)
    }

    @Test("largest representable aggregate budget remains usable", arguments: [1, 2, 3])
    func maximumAggregateBudget(ownerCount: Int) async throws {
        let limit = Int.max / ownerCount
        let owner = RoutedReviewProgressor(result: .success(.init(
            claimedCount: limit, resolvedCount: limit, redactedCount: limit, releasedCount: 0
        )))
        let worker = try V2RoutedContentReviewWorker(
            progressors: Array(repeating: owner, count: ownerCount)
        )
        #expect(try await worker.runOnce(limitPerOwner: limit) == .init(
            claimedCount: limit * ownerCount, resolvedCount: limit * ownerCount,
            redactedCount: limit * ownerCount, releasedCount: 0
        ))
        #expect(await owner.limits() == Array(repeating: limit, count: ownerCount))
    }

    @Test("healthy room owners continue while one review store is unavailable")
    func isolatesOwnerFailureAndAggregatesReports() async throws {
        let first = RoutedReviewProgressor(result: .success(.init(
            claimedCount: 3,
            resolvedCount: 2,
            redactedCount: 1,
            releasedCount: 1
        )))
        let unavailable = RoutedReviewProgressor(
            result: .failure(RoutedReviewTestError.unavailable)
        )
        let second = RoutedReviewProgressor(result: .success(.init(
            claimedCount: 4,
            resolvedCount: 4,
            redactedCount: 2,
            releasedCount: 0
        )))
        let worker = try V2RoutedContentReviewWorker(progressors: [
            first,
            unavailable,
            second,
        ])

        #expect(try await worker.runOnce(limitPerOwner: 17) == .init(
            claimedCount: 7,
            resolvedCount: 6,
            redactedCount: 3,
            releasedCount: 1
        ))
        #expect(await first.limits() == [17])
        #expect(await unavailable.limits() == [17])
        #expect(await second.limits() == [17])
    }

    @Test("all owner failures are visible to runtime retry")
    func failsWhenEveryOwnerIsUnavailable() async throws {
        let worker = try V2RoutedContentReviewWorker(progressors: [
            RoutedReviewProgressor(
                result: .failure(RoutedReviewTestError.unavailable)
            ),
            RoutedReviewProgressor(
                result: .failure(RoutedReviewTestError.unavailable)
            ),
        ])

        await #expect(
            throws: V2RoutedContentReviewWorkerError.allOwnersFailed(2)
        ) {
            try await worker.runOnce(limitPerOwner: 8)
        }
    }
}

private actor RoutedReviewProgressor: V2ContentReviewProgressing {
    private let result: Result<V2ContentReviewReport, RoutedReviewTestError>
    private var observedLimits: [Int] = []

    init(result: Result<V2ContentReviewReport, RoutedReviewTestError>) {
        self.result = result
    }

    func runOnce(limit: Int) throws -> V2ContentReviewReport {
        observedLimits.append(limit)
        return try result.get()
    }

    func limits() -> [Int] { observedLimits }
}

private enum RoutedReviewTestError: Error, Sendable {
    case unavailable
}
