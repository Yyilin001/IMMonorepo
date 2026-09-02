@testable import IMV2Server
import Testing

@Suite("V2 routed content review worker")
struct V2RoutedContentReviewWorkerTests {
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
