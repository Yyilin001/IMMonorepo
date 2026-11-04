import Foundation
import GRDB

/// 同步查询和写入执行器在批次边界检查关闭状态，不依赖另一个 actor 获得执行机会。
final class V2SearchLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    func check() throws {
        if lock.withLock({ closed }) { throw V2MessageSearchError.closed }
        try Task.checkCancellation()
    }
    func close() { lock.withLock { closed = true } }
}

/// 与具体账号数据库实例同生共死。此 actor 只管理任务，读写分别在各自的执行器上进行。
public actor V2MessageSearchService {
    private let databasePool: DatabasePool
    private let available: Bool
    private let reader: V2MessageSearchReader
    private let writer: V2MessageSearchWriter?
    private let lifetime = V2SearchLifetime()
    private var worker: (id: UUID, task: Task<Void, Never>)?
    private struct Operation {
        let cancel: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }
    private var operations: [UUID: Operation] = [:]

    init(primary: DatabasePool, search: DatabasePool?, writable: Bool, scope: V2AccountStorageScope?) throws {
        databasePool = primary
        available = search != nil
        reader = V2MessageSearchReader(primary: primary, search: search, lifetime: lifetime, storageIncarnation: scope?.incarnation)
        if let search, writable { writer = try V2MessageSearchWriter(primary: primary, search: search, lifetime: lifetime) }
        else { writer = nil }
    }

    deinit {
        lifetime.close()
        worker?.task.cancel()
        for operation in operations.values { operation.cancel() }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try lifetime.check()
        let id = UUID()
        let task = Task { try await body() }
        operations[id] = Operation(cancel: { task.cancel() }, join: { _ = await task.result })
        defer { operations[id] = nil }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try lifetime.check()
        return result
    }

    public func searchMessages(_ request: V2MessageSearchRequest) async throws -> V2MessageSearchPage {
        try await perform { [reader, writer] in
            do { return try await reader.searchMessages(request) }
            catch let damage as V2DamagedSearchIndex {
                guard let writer else { throw V2MessageSearchError.indexUnavailable(.failed) }
                try await writer.invalidate(generation: damage.generation)
                throw V2MessageSearchError.indexUnavailable(.building)
            }
        }
    }

    public func startIndexing() {
        guard let writer, (try? lifetime.check()) != nil else { return }
        if let worker, !worker.task.isCancelled { return }
        let previous = worker?.task
        let id = UUID()
        let task = Task(priority: .utility) { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                try await writer.runMessageSearchIndexer()
            } catch {
                if !Task.isCancelled, error as? V2MessageSearchError != .closed { await writer.markFailed() }
            }
            await self?.finished(id)
        }
        worker = (id, task)
    }

    private func finished(_ id: UUID) {
        if worker?.id == id { worker = nil }
    }

    public func stopIndexing() async {
        guard let current = worker else { return }
        current.task.cancel()
        await current.task.value
        finished(current.id)
    }

    public func close() async {
        lifetime.close()
        let active = Array(operations.values)
        for operation in active { operation.cancel() }
        await stopIndexing()
        for operation in active { await operation.join() }
    }

    private func writableIndex() throws -> V2MessageSearchWriter {
        try lifetime.check()
        guard let writer else { throw V2MessageSearchError.readOnly }
        return writer
    }

    func rebuildMessageSearchIndex() async throws {
        let writer = try writableIndex()
        try await perform { try await writer.rebuildMessageSearchIndex() }
    }

    func prepareMessageSearchIndex() async throws {
        let writer = try writableIndex()
        try await perform { try await writer.prepareMessageSearchIndex() }
    }

    @discardableResult
    func processPendingMessageSearchIndexJobs(limit: Int = 64) async throws -> Int {
        let writer = try writableIndex()
        return try await perform { try await writer.processPendingMessageSearchIndexJobs(limit: limit) }
    }

    public func messageSearchIndexState() throws -> V2MessageSearchIndexState {
        try lifetime.check()
        guard available else { return .building }
        return try databasePool.read { try GRDBV2LocalSyncStore.readMessageSearchIndexState(db: $0) }
    }

    public func messageSearchIndexProgress() throws -> V2MessageSearchIndexProgress {
        try lifetime.check()
        return try databasePool.read { db in
            let state = try available ? GRDBV2LocalSyncStore.readMessageSearchIndexState(db: db) : .building
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_message_search_jobs") ?? 0
            return .init(state: state, pendingJobCount: count)
        }
    }

    public func messageSearchIndexUpdates() -> AsyncThrowingStream<V2MessageSearchIndexSnapshot, any Error> {
        let (stream, output) = AsyncThrowingStream<V2MessageSearchIndexSnapshot, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        do { try lifetime.check() } catch { output.finish(throwing: error); return stream }
        let id = UUID(), pool = databasePool, available = available
        let task = Task { [weak self] in
            do {
                let observation = ValueObservation.tracking { db in
                    guard let row = try Row.fetchOne(db, sql: "SELECT state,generation,index_version FROM v2_message_search_state WHERE singleton=1"),
                          let state = V2MessageSearchIndexState(storageValue: row["state"]) else {
                        throw V2ClientProjectionError.invalidMessagePayload
                    }
                    let version = Int(try GRDBV2LocalSyncStore.searchInteger(row, "index_version"))
                    return V2MessageSearchIndexSnapshot(state: available && version == GRDBV2LocalSyncStore.messageSearchIndexVersion ? state : .building,
                        generation: UInt64(try GRDBV2LocalSyncStore.searchInteger(row, "generation")), indexVersion: version)
                }.removeDuplicates()
                for try await snapshot in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) { output.yield(snapshot) }
                output.finish()
            } catch { output.finish(throwing: error) }
            await self?.removeObservation(id)
        }
        operations[id] = Operation(cancel: { task.cancel() }, join: { await task.value })
        output.onTermination = { _ in task.cancel() }
        return stream
    }

    private func removeObservation(_ id: UUID) { operations[id] = nil }
}
