import Foundation

private final class ActiveQuery: @unchecked Sendable {
    private let lock = NSLock()
    private var control: OperationControl?
    func replace(with next: OperationControl?) {
        let old = lock.withLock { let old = control; control = next; return old }
        old?.cancel()
    }
}

/// 独立账号搜索库。实例拥有读写执行器；所有持久化仅发生在指定文件中。
public final class SearchIndex: Sendable {
    public let capabilities: SQLiteCapabilities
    public let configuration: SearchConfiguration
    private let writer: IndexWriter
    private let reader: IndexReader
    private let admission: AdmissionGate
    private let queryAdmission = AdmissionGate(maximum: 16)
    private let activeQuery = ActiveQuery()

    private init(configuration: SearchConfiguration, capabilities: SQLiteCapabilities, writer: IndexWriter, reader: IndexReader) {
        self.configuration = configuration; self.capabilities = capabilities; self.writer = writer; self.reader = reader
        admission = AdmissionGate(maximum: configuration.maximumQueuedBytes)
    }
    public static func open(_ configuration: SearchConfiguration) async throws -> SearchIndex {
        try configuration.validate()
        try Task.checkCancellation()
        let writer = IndexWriter(configuration), reader = IndexReader(configuration)
        do {
            let capabilities = try await writer.initialize()
            try await reader.initialize()
            try Task.checkCancellation()
            let index = SearchIndex(configuration: configuration, capabilities: capabilities, writer: writer, reader: reader)
            if configuration.automaticallyProcess { await writer.startProcessing() }
            return index
        } catch {
            try? await reader.close(); try? await writer.close(); throw error
        }
    }

    /// 回执表示持久接收，是否已可搜索由 waitUntilIndexed/status 明确表达。
    public func enqueue(_ changes: [IndexChange], checkpoint: SourceCheckpoint? = nil) async throws -> IndexReceipt {
        try Task.checkCancellation()
        let bytes = try validate(changes)
        try admission.acquire(bytes); defer { admission.release(bytes) }
        let control = OperationControl()
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        return try await withTaskCancellationHandler {
            try await writer.enqueue(changes, checkpoint: checkpoint, requestedAt: requestedAt, control: control)
        } onCancel: { control.cancel() }
    }

    /// 手动消费适合离线导入与基准；自动模式也可调用，所有批次仍由同一写者串行处理。
    public func processPending(maximumBatches: Int = .max) async throws -> Int {
        guard maximumBatches > 0 else { throw SearchIndexError.invalidArgument("invalid batch count") }
        let control = OperationControl()
        return try await withTaskCancellationHandler {
            var processed = 0
            for _ in 0..<maximumBatches {
                let count = try await writer.processBatch(control: control)
                processed += count
                if count == 0 { break }
                try Task.checkCancellation()
            }
            return processed
        } onCancel: { control.cancel() }
    }
    public func waitUntilIndexed(_ receipt: IndexReceipt, timeoutSeconds: Double = 30) async throws {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { throw SearchIndexError.invalidArgument("invalid timeout") }
        let control = OperationControl(timeout: timeoutSeconds)
        while true {
            try Task.checkCancellation(); try control.check()
            if try await writer.checkReceipt(receipt) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    public func search(_ request: SearchRequest, after cursor: SearchCursor? = nil) async throws -> SearchPage {
        try Task.checkCancellation()
        try queryAdmission.acquire(1); defer { queryAdmission.release(1) }
        let control = OperationControl(timeout: configuration.queryTimeoutSeconds)
        activeQuery.replace(with: control)
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        return try await withTaskCancellationHandler {
            try await reader.search(request, after: cursor, requestedAt: requestedAt, control: control)
        } onCancel: { control.cancel() }
    }
    public func status() async throws -> IndexStatus { try await writer.status() }
    public func setSourceCoverage(_ coverage: SourceCoverage) async throws { try await writer.setCoverage(coverage) }
    public func diagnostics(reset: Bool = false) async -> SearchDiagnostics {
        await SearchDiagnostics(index: writer.diagnostics(reset: reset), query: reader.diagnostics(reset: reset),
                                admission: admission.snapshot(reset: reset), queryAdmission: queryAdmission.snapshot(reset: reset))
    }
    public func retryFailed() async throws { try await writer.retryFailed() }
    public func integrityCheck() async throws { try await writer.integrityCheck() }
    public func maintain() async throws { try await writer.maintain() }

    /// 从已保存原文重建影子索引，可切换大小写规则；再次打开时配置应使用切换后的模式。
    /// 来源尚未投递的数据仍由适配层补齐。
    public func rebuild(mode: SearchTextMode? = nil, batchSize: Int = 100) async throws {
        guard (1...1000).contains(batchSize) else { throw SearchIndexError.invalidArgument("invalid rebuild batch size") }
        let control = OperationControl()
        try await withTaskCancellationHandler {
            try await writer.beginRebuild(mode: mode)
            while try await !writer.rebuildStep(count: batchSize, control: control) { try Task.checkCancellation() }
        } onCancel: { control.cancel() }
    }

    public func close() async throws {
        writer.stop.cancel()
        admission.close(); queryAdmission.close(); activeQuery.replace(with: nil)
        try await reader.close(); try await writer.close()
    }
    public func purge() async throws {
        writer.stop.cancel()
        admission.close(); queryAdmission.close(); activeQuery.replace(with: nil)
        try await reader.close(); try await writer.purge()
    }

    // 仅供同包测试注入事务边界失败，不影响生产配置或记录消息内容。
    package func setFault(_ fault: (@Sendable (FaultPoint) throws -> Void)?) async { await writer.setFault(fault) }
    func beginRebuildForTesting() async throws { try await writer.beginRebuild() }
    func rebuildStepForTesting(count: Int) async throws -> Bool { try await writer.rebuildStep(count: count, control: OperationControl()) }
    func limitDatabaseGrowthForTesting() async throws { try await writer.limitDatabaseGrowthForTesting() }

    private func validate(_ changes: [IndexChange]) throws -> Int {
        guard changes.count <= configuration.maximumBatchCount else { throw SearchIndexError.invalidArgument("batch count exceeded") }
        func key(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 512 }
        var bytes = 0
        for change in changes {
            guard key(change.eventID) else { throw SearchIndexError.invalidArgument("invalid event ID") }
            bytes += change.eventID.utf8.count + 256
            switch change.operation {
            case .upsert(let document):
                guard key(document.id), key(document.groupID), key(document.kind), document.version >= 0,
                      document.fields.count <= 64, Set(document.fields.map(\.id)).count == document.fields.count,
                      document.fields.allSatisfy({ key($0.id) }) else { throw SearchIndexError.invalidArgument("invalid document") }
                let textBytes = document.fields.reduce(0) { $0 + $1.text.utf8.count }
                guard textBytes <= configuration.maximumDocumentBytes else { throw SearchIndexError.invalidArgument("document byte limit exceeded") }
                bytes += textBytes + document.fields.reduce(0) { $0 + $1.id.utf8.count } + document.id.utf8.count + document.groupID.utf8.count
            case .delete(let id, let version), .clearGroup(let id, let version):
                guard key(id), version >= 0 else { throw SearchIndexError.invalidArgument("invalid deletion") }
                bytes += id.utf8.count
            }
            guard bytes <= configuration.maximumQueuedBytes else { throw SearchIndexError.backpressure }
        }
        return max(1, bytes)
    }
}
