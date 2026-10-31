import Foundation
import IMV2Core
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts

// Adapt existing per-recipient test probes to the batch port. Production has
// only the batch initializer and calls the multi-recipient service directly.
typealias AuthorPresentationFixtureRead = @Sendable (V2ProfilePresentationBatchRequest, V2AuthenticatedConnection) async throws -> V2ProfilePresentationBatchResponse

private struct AuthorFixtureResult: Sendable {
    let index: Int
    let result: Result<V2ProfilePresentationBatchResponse, any Error>
}

func authorPresentationFixtureBatch(_ read: @escaping AuthorPresentationFixtureRead) -> V2AuthorPresentationDispatcher.BatchRead {
    { requests in
        // Preserve the index and enum payload in a concrete value across the
        // async boundary; this also keeps optimized test probes deterministic.
        await withTaskGroup(of: AuthorFixtureResult.self) { group in
            for (index, input) in requests.enumerated() {
                group.addTask {
                    do { return .init(index: index, result: .success(try await read(input.request, .init(userID: input.actorUserID, deviceID: input.deviceID, capabilityProfile: "standard")))) }
                    catch { return .init(index: index, result: .failure(error)) }
                }
            }
            var values: [Int: Result<V2ProfilePresentationBatchResponse, any Error>] = [:]
            for await item in group { values[item.index] = item.result }
            return requests.indices.map { values[$0]! }
        }
    }
}

extension V2AuthorPresentationDispatcher {
    init(configuration: Configuration, read: @escaping AuthorPresentationFixtureRead,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.init(configuration: configuration, readBatch: authorPresentationFixtureBatch(read), now: now)
    }
}

extension V2AuthorPresentationRuntime {
    init(configuration: V2AuthorPresentationDispatcher.Configuration,
         ingressConfiguration: V2AuthorPresentationIngress.Configuration,
         read: @escaping AuthorPresentationFixtureRead, closeReader: @escaping @Sendable () async -> Void) {
        self.init(configuration: configuration, ingressConfiguration: ingressConfiguration,
                  readBatch: authorPresentationFixtureBatch(read), closeReader: closeReader)
    }
}
