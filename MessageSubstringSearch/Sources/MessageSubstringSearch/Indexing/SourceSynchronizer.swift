import Foundation

public struct SourceChangeBatch: Sendable {
    public let epoch: String
    public let changes: [IndexChange]
    public let nextCursor: String
    public let reachedHead: Bool
    public init(epoch: String, changes: [IndexChange], nextCursor: String, reachedHead: Bool) {
        self.epoch = epoch; self.changes = changes; self.nextCursor = nextCursor; self.reachedHead = reachedHead
    }
}

/// 适配器实现这个边界；必须保证游标稳定、变更可重放、包含删除和清空。
/// SDK 若只能回调，应直接 enqueue 并保持 coverage unknown，不能伪造此保证。
public protocol SearchChangeSource: Sendable {
    func readChanges(after cursor: String, limit: Int) async throws -> SourceChangeBatch
}

public struct SourceSynchronizer: Sendable {
    private let index: SearchIndex
    private let source: any SearchChangeSource
    public init(index: SearchIndex, source: any SearchChangeSource) { self.index = index; self.source = source }

    /// 每页确认持久化并完成索引后再读取下一页，天然限制补建内存；中断后从持久游标继续。
    public func synchronize(pageSize: Int = 100, receiptTimeoutSeconds: Double = 30) async throws {
        guard (1...index.configuration.maximumBatchCount).contains(pageSize) else { throw SearchIndexError.invalidArgument("invalid source page size") }
        try await index.setSourceCoverage(.catchingUp)
        while true {
            try Task.checkCancellation()
            let cursor = try await index.status().acceptedSourceCheckpoint
            let batch = try await source.readChanges(after: cursor, limit: pageSize)
            guard batch.epoch == index.configuration.sourceEpoch else { throw SearchIndexError.incompatibleIndex }
            guard batch.changes.count <= pageSize,
                  (batch.reachedHead && batch.changes.isEmpty) || batch.nextCursor != cursor else {
                throw SearchIndexError.invalidArgument("source did not advance its cursor")
            }
            let receipt = try await index.enqueue(batch.changes, checkpoint: SourceCheckpoint(expected: cursor, next: batch.nextCursor))
            if !index.configuration.automaticallyProcess { _ = try await index.processPending() }
            try await index.waitUntilIndexed(receipt, timeoutSeconds: receiptTimeoutSeconds)
            if batch.reachedHead { try await index.setSourceCoverage(.caughtUp(through: batch.nextCursor)); return }
        }
    }
}
