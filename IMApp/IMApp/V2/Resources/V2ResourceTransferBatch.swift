import Foundation
import IMV2ClientKit

nonisolated enum V2ResourceTransferBatchAction: Equatable, Sendable {
    case retry, confirmCancellation
    var capability: V2ManagedResourceTransferAction {
        switch self { case .retry: .retry; case .confirmCancellation: .retryCancellation }
    }
}

nonisolated struct V2ResourceTransferBatchResult: Sendable {
    enum Outcome: Sendable { case requested, skipped, failed(String) }
    let items: [(id: V2ManagedResourceTransferID, outcome: Outcome)]
    var requestedCount: Int { items.filter { if case .requested = $0.outcome { true } else { false } }.count }
    var failedIDs: [V2ManagedResourceTransferID] { items.compactMap { if case .failed = $0.outcome { $0.id } else { nil } } }
    var skippedCount: Int { items.count - requestedCount - failedIDs.count }
    var failures: [String] { Array(Set(items.compactMap { if case .failed(let text) = $0.outcome { text } else { nil } })).sorted() }
}

extension V2ResourceManagementService {
    func retryTransfers(_ ids: [V2ManagedResourceTransferID], action: V2ResourceTransferBatchAction) async throws -> V2ResourceTransferBatchResult {
        guard !ids.isEmpty, ids.count <= 100 else { throw V2ResourceStorageError.invalidRecord }
        var seen = Set<V2ManagedResourceTransferID>()
        var items: [(V2ManagedResourceTransferID, V2ResourceTransferBatchResult.Outcome)] = []
        for id in ids where seen.insert(id).inserted {
            try Task.checkCancellation()
            do {
                // These commands revalidate capabilities in their existing
                // journal transaction and retain the original operation IDs.
                switch action {
                case .retry: try await center.retryTransfer(id)
                case .confirmCancellation: try await center.retryCancellation(id)
                }
                items.append((id, .requested))
            } catch is CancellationError { throw CancellationError() }
            catch V2ResourceStorageError.closed { throw V2ResourceStorageError.closed }
            catch V2ResourceTransferManagementError.actionUnavailable { items.append((id, .skipped)) }
            catch { items.append((id, .failed(V2ResourceFailure.message(error)))) }
        }
        return .init(items: items)
    }
}
