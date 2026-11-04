import Foundation

private struct Candidate {
    let id: String
    let version: Int64
    let timestamp: Int64
}

/// 一次查询的有序候选来自同一 WAL 读快照。只把翻页实际需要的前缀存入内存，
/// 已读取的游标可以重试。正文与版本始终从 IndexReader 的当前读事务核验。
private final class QuerySnapshot {
    let id = UUID()
    let request: SearchRequest
    let generation: Int64
    let mode: SearchTextMode
    let pattern: TokenPattern
    let created = DispatchTime.now().uptimeNanoseconds
    let count: Int
    let truncated: Bool
    private(set) var candidates: [Candidate] = []
    private(set) var source: SQLiteConnection?
    private let selection: String
    private let arguments: [SQLValue]
    private let groupBy: String

    init(request: SearchRequest, configuration: SearchConfiguration, db: SQLiteConnection, control: OperationControl) throws {
        try control.check()
        self.request = request
        try db.execute("BEGIN")
        guard let mode = SearchTextMode(rawValue: try db.meta("mode")) else { throw SearchIndexError.incompatibleIndex }
        self.mode = mode
        let query = try CharacterTokenizer.tokenize(request.text, mode: mode,
            byteLimit: configuration.maximumQueryCharacters * 256, check: control.check)
        guard !query.tokens.isEmpty else { throw SearchIndexError.emptyQuery }
        guard query.tokens.count <= configuration.maximumQueryCharacters, (1...200).contains(request.pageSize) else {
            throw SearchIndexError.invalidArgument("query or page size exceeds limit")
        }
        if let from = request.fromTimestamp, let through = request.throughTimestamp, from > through {
            throw SearchIndexError.invalidArgument("invalid time range")
        }
        pattern = TokenPattern(query.tokens)
        generation = try Int64(db.meta("generation")) ?? 1
        let chunks = """
            SELECT f.document FROM chunk_fts
            JOIN chunks c ON c.pk=chunk_fts.rowid JOIN fields f ON f.pk=c.field
            WHERE chunk_fts MATCH ? AND c.generation=?
            """
        var filters = "NOT EXISTS(SELECT 1 FROM group_epochs g WHERE g.id=d.group_id AND g.version>=d.version)"
        var values: [SQLValue] = [.text("\"" + query.encoded(query.tokens.indices) + "\""), .integer(generation)]
        if let group = request.groupID { filters += " AND d.group_id=?"; values.append(.text(group)) }
        if let kind = request.kind { filters += " AND d.kind=?"; values.append(.text(kind)) }
        if let from = request.fromTimestamp { filters += " AND d.timestamp>=?"; values.append(.integer(from)) }
        if let through = request.throughTimestamp { filters += " AND d.timestamp<=?"; values.append(.integer(through)) }

        // 只探测上限 + 1 个不同文档，不为截断标记排序或复制所有消息 ID。
        let limit = configuration.maximumResults
        let joined = """
            FROM chunk_fts JOIN chunks c ON c.pk=chunk_fts.rowid JOIN fields f ON f.pk=c.field
            JOIN documents d ON d.pk=f.document
            WHERE chunk_fts MATCH ? AND c.generation=? AND \(filters)
            """
        // 少量命中可在一次 FTS 扫描内完成；只有样本溢出时才探测完整的分页上限。
        let peek = min(request.pageSize, limit) + 1
        let sampleSQL = """
            SELECT id,version,timestamp FROM (
                SELECT DISTINCT d.id,d.version,d.timestamp \(joined) LIMIT ?
            ) ORDER BY timestamp DESC,id COLLATE BINARY DESC
            """
        let sample = try db.controlled(control) {
            try Self.readCandidates(db, sql: sampleSQL, values: values + [.integer(Int64(peek))], control: control)
        }
        let total: Int64
        if sample.count < peek {
            candidates = sample
            total = Int64(sample.count)
        } else if sample.count > limit {
            total = Int64(limit + 1)
        } else {
            let probe = "SELECT COUNT(*) FROM (SELECT DISTINCT d.pk \(joined) LIMIT ?)"
            total = try db.controlled(control) { try db.integer(probe, values + [.integer(Int64(limit + 1))]) }
        }
        count = min(Int(total), limit)
        truncated = total > limit
        // 高频词按时间索引取一页即可停止。稀有词从 FTS 命中集排序，避免倒扫历史。
        let visible = try Int64(db.meta("visibleDocuments")) ?? 0
        let columns = "SELECT d.id,d.version,d.timestamp"
        if total > Int64(request.pageSize) && total >= visible / 8 {
            groupBy = ""
            selection = "\(columns) FROM documents d INDEXED BY document_order WHERE d.pk IN (\(chunks)) AND \(filters)"
        } else {
            groupBy = " GROUP BY d.pk"
            selection = "\(columns) \(joined)"
        }
        arguments = values
        source = db
    }

    func endRead() -> SQLiteConnection? {
        guard let db = source else { return nil }
        source = nil
        // 结束读事务后才复用句柄。无法结束的连接随局部引用释放。
        do { try db.execute("ROLLBACK"); return db } catch { return nil }
    }

    func fetchMore(control: OperationControl) throws {
        let offset = candidates.count
        guard let source else { throw SearchIndexError.incompatibleIndex }
        var sql = selection, values = arguments
        if let last = candidates.last {
            sql += " AND (d.timestamp,d.id) < (?,?)"
            values += [.integer(last.timestamp), .text(last.id)]
        }
        let limit = min(count - offset, max(request.pageSize, candidates.count))
        sql += groupBy + " ORDER BY d.timestamp DESC,d.id COLLATE BINARY DESC LIMIT ?"
        values.append(.integer(Int64(limit)))
        // 先完成批次再追加，取消/超时后的同一游标仍可重试。
        let batch = try source.controlled(control) {
            try Self.readCandidates(source, sql: sql, values: values, control: control)
        }
        guard batch.count == limit else { throw SearchIndexError.incompatibleIndex }
        candidates += batch
    }

    private static func readCandidates(_ db: SQLiteConnection, sql: String, values: [SQLValue],
                                       control: OperationControl) throws -> [Candidate] {
        try db.statement(sql, values: values) { statement in
            var rows: [Candidate] = []
            while try db.step(statement) {
                try control.check()
                rows.append(.init(id: db.text(statement, 0), version: db.int(statement, 1),
                                  timestamp: db.int(statement, 2)))
            }
            return rows
        }
    }

}

actor IndexReader {
    nonisolated let executor = DatabaseExecutor("MessageSubstringSearch.reader")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let configuration: SearchConfiguration
    private var database: SQLiteConnection?
    private var snapshot: QuerySnapshot?
    private var idleReader: SQLiteConnection?
    private var expiry: Task<Void, Never>?
    private var metrics = QueryMetrics()
    init(_ configuration: SearchConfiguration) { self.configuration = configuration }
    func initialize() throws {
        database = try SQLiteConnection(path: configuration.path, readOnly: true, cacheCapacity: configuration.statementCacheCapacity)
    }
    func close() throws {
        expiry?.cancel()
        snapshot = nil
        idleReader = nil
        try database?.close()
        database = nil
    }
    func diagnostics(reset: Bool) -> QueryMetrics { let result = metrics; if reset { metrics = QueryMetrics() }; return result }

    func search(_ request: SearchRequest, after cursor: SearchCursor?, requestedAt: UInt64, control: OperationControl) throws -> SearchPage {
        guard let db = database else { throw SearchIndexError.closed }
        let start = DispatchTime.now().uptimeNanoseconds
        if configuration.metricsEnabled { metrics.queueWait.record(elapsedMilliseconds(since: requestedAt)) }
        do {
            try control.check()
            var ftsMilliseconds = 0.0
            let current: QuerySnapshot
            if let cursor {
                guard let saved = snapshot, cursor.snapshotID == saved.id, saved.request == request,
                      cursor.offset >= 0, cursor.offset < saved.count,
                      elapsedMilliseconds(since: saved.created) < configuration.snapshotLifetimeSeconds * 1000 else {
                    throw SearchIndexError.staleCursor
                }
                current = saved
            } else {
                let ftsStart = DispatchTime.now().uptimeNanoseconds
                let source = try idleReader ?? SQLiteConnection(path: configuration.path, readOnly: true,
                                                                cacheCapacity: configuration.statementCacheCapacity)
                idleReader = nil
                current = try QuerySnapshot(request: request, configuration: configuration, db: source, control: control)
                if configuration.metricsEnabled { ftsMilliseconds = elapsedMilliseconds(since: ftsStart) }
            }
            func materialize(_ db: SQLiteConnection) throws -> SearchPage {
                let preparationMilliseconds = ftsMilliseconds
                let materializeStart = DispatchTime.now().uptimeNanoseconds
                var offset = cursor?.offset ?? 0, hits: [SearchHit] = [], returnedBytes = 0
                while offset < current.count && hits.count < request.pageSize {
                    try control.check()
                    if offset == current.candidates.count {
                        let fetchStart = DispatchTime.now().uptimeNanoseconds
                        try current.fetchMore(control: control)
                        if configuration.metricsEnabled { ftsMilliseconds += elapsedMilliseconds(since: fetchStart) }
                    }
                    let candidate = current.candidates[offset]
                    guard let document = try loadDocument(db, id: candidate.id), document.version == candidate.version else {
                        offset += 1; continue // 快照后删除/修改的记录不冒用旧排序与高亮。
                    }
                    let barrier = try db.integer("SELECT coalesce(max(version),-1) FROM group_epochs WHERE id=?", [.text(document.groupID)])
                    if document.version <= barrier { offset += 1; continue }
                    let bytes = document.fields.reduce(0) { $0 + $1.text.utf8.count }
                    if !hits.isEmpty && returnedBytes + bytes > 2 * 1_048_576 { break }
                    offset += 1
                    for field in document.fields {
                        let text = try CharacterTokenizer.tokenize(field.text, mode: current.mode,
                            byteLimit: configuration.maximumDocumentBytes, check: control.check)
                        let ranges = try current.pattern.ranges(in: text, check: control.check)
                        if !ranges.isEmpty {
                            let hash = try db.string("SELECT lower(hex(hash)) FROM documents WHERE id=?", [.text(document.id)])
                            hits.append(SearchHit(document: document, fieldID: field.id, contentHash: hash, ranges: ranges))
                            returnedBytes += bytes; break
                        }
                    }
                }
                try control.check()
                let status = try readStatus(db, path: configuration.path)
                if configuration.metricsEnabled {
                    if ftsMilliseconds > 0 { metrics.fts.record(ftsMilliseconds) }
                    let fetched = ftsMilliseconds - preparationMilliseconds
                    metrics.materialization.record(max(0, elapsedMilliseconds(since: materializeStart) - fetched))
                    metrics.execution.record(elapsedMilliseconds(since: start))
                }
                return SearchPage(hits: hits, nextCursor: offset < current.count ? SearchCursor(snapshotID: current.id, offset: offset) : nil,
                                  resultsTruncated: current.truncated, status: status)
            }
            let page: SearchPage
            if cursor == nil, let frozen = current.source {
                // 首屏的命中、模式和状态取自同一读事务，包括并发切换代次的情况。
                page = try frozen.controlled(control) { try materialize(frozen) }
            } else {
                page = try db.controlled(control) {
                    try db.transaction(readOnly: true) {
                        guard try Int64(db.meta("generation")) == current.generation else { throw SearchIndexError.staleCursor }
                        return try materialize(db)
                    }
                }
            }
            if current.candidates.count == current.count { recycle(current) }
            if cursor == nil {
                if let snapshot { recycle(snapshot) }
                expiry?.cancel()
                snapshot = page.nextCursor != nil ? current : nil
                if snapshot != nil {
                    let id = current.id
                    let lifetime = configuration.snapshotLifetimeSeconds
                    expiry = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(min(lifetime, 9e9))) } catch { return }
                        await self?.expire(id)
                    }
                }
            }
            return page
        } catch {
            if configuration.metricsEnabled {
                if error is CancellationError { metrics.cancelled += 1 }
                if error as? SearchIndexError == .timeout { metrics.timedOut += 1 }
            }
            throw error
        }
    }

    private func recycle(_ current: QuerySnapshot) {
        if let released = current.endRead() { idleReader = released }
    }

    private func expire(_ id: UUID) {
        guard let current = snapshot, current.id == id else { return }
        recycle(current)
        snapshot = nil
    }
}
