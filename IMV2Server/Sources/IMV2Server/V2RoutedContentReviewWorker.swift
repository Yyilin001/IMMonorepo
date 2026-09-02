/// Drains review jobs from every physical room owner. A failed owner cannot
/// stop healthy owners from resolving or redacting their own messages; all
/// owners failing is surfaced so the runtime retains its normal retry cadence.
public struct V2RoutedContentReviewWorker: Sendable {
    private let workers: [any V2ContentReviewProgressing]

    public init(workers: [V2ContentReviewWorker]) throws {
        try self.init(progressors: workers)
    }

    public init(progressors: [any V2ContentReviewProgressing]) throws {
        guard !progressors.isEmpty else {
            throw V2RoutedContentReviewWorkerError.noOwners
        }
        workers = progressors
    }

    public func runOnce(limitPerOwner: Int) async throws
        -> V2ContentReviewReport {
        precondition(limitPerOwner > 0)
        let result = await withTaskGroup(
            of: Result<V2ContentReviewReport, any Error>.self,
            returning: Result<
                V2ContentReviewReport,
                V2RoutedContentReviewWorkerError
            >.self
        ) { group in
            for worker in workers {
                group.addTask {
                    do {
                        return .success(
                            try await worker.runOnce(limit: limitPerOwner)
                        )
                    } catch { return .failure(error) }
                }
            }
            var successfulOwners = 0
            var failedOwners = 0
            var claimed = 0
            var resolved = 0
            var redacted = 0
            var released = 0
            for await ownerResult in group {
                switch ownerResult {
                case .success(let report):
                    successfulOwners += 1
                    claimed += report.claimedCount
                    resolved += report.resolvedCount
                    redacted += report.redactedCount
                    released += report.releasedCount
                case .failure:
                    failedOwners += 1
                }
            }
            guard successfulOwners > 0 else {
                return .failure(.allOwnersFailed(failedOwners))
            }
            return .success(.init(
                claimedCount: claimed,
                resolvedCount: resolved,
                redactedCount: redacted,
                releasedCount: released
            ))
        }
        return try result.get()
    }
}

public protocol V2ContentReviewProgressing: Sendable {
    func runOnce(limit: Int) async throws -> V2ContentReviewReport
}

extension V2ContentReviewWorker: V2ContentReviewProgressing {}

public enum V2RoutedContentReviewWorkerError:
    Error,
    Equatable,
    Sendable {
    case noOwners
    case allOwnersFailed(Int)
}
