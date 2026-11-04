import Foundation

private struct Candidate { let id: String; let version: Int64 }
private struct QuerySnapshot {
    let id: UUID
    let request: SearchRequest
    let generation: Int64
    let created: UInt64
    let candidates: [Candidate]
    let truncated: Bool
}

actor IndexReader {
    nonisolated let executor = DatabaseExecutor("MessageSubstringSearch.reader")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let configuration: SearchConfiguration
    private var database: SQLiteConnection?
    private var snapshot: QuerySnapshot?
    private var metrics = QueryMetrics()
    init(_ configuration: SearchConfiguration) { self.configuration = configuration }
    func initialize() throws {
        database = try SQLiteConnection(path: configuration.path, readOnly: true, cacheCapacity: configuration.statementCacheCapacity)
    }
    func close() throws { try database?.close(); database = nil; snapshot = nil }
    func diagnostics(reset: Bool) -> QueryMetrics { let result = metrics; if reset { metrics = QueryMetrics() }; return result }

    func search(_ request: SearchRequest, after cursor: SearchCursor?, requestedAt: UInt64, control: OperationControl) throws -> SearchPage {
        guard let db = database else { throw SearchIndexError.closed }
        let start = DispatchTime.now().uptimeNanoseconds
        if configuration.metricsEnabled { metrics.queueWait.record(elapsedMilliseconds(since: requestedAt)) }
        do {
            return try db.controlled(control) {
                try db.transaction(readOnly: true) {
                    guard let mode = SearchTextMode(rawValue: try db.meta("mode")) else { throw SearchIndexError.incompatibleIndex }
                    let query = try CharacterTokenizer.tokenize(request.text, mode: mode,
                        byteLimit: configuration.maximumQueryCharacters * 256, check: control.check)
                    guard !query.tokens.isEmpty else { throw SearchIndexError.emptyQuery }
                    guard query.tokens.count <= configuration.maximumQueryCharacters, (1...200).contains(request.pageSize) else {
                        throw SearchIndexError.invalidArgument("query or page size exceeds limit")
                    }
                    if let from = request.fromTimestamp, let through = request.throughTimestamp, from > through {
                        throw SearchIndexError.invalidArgument("invalid time range")
                    }
                    let generation = Int64(try db.meta("generation")) ?? 1
                    let current: QuerySnapshot
                    if let cursor {
                        guard let saved = snapshot, cursor.snapshotID == saved.id, saved.request == request,
                              saved.generation == generation, cursor.offset >= 0, cursor.offset <= saved.candidates.count,
                              elapsedMilliseconds(since: saved.created) < configuration.snapshotLifetimeSeconds * 1000 else {
                            throw SearchIndexError.staleCursor
                        }
                        current = saved
                    } else {
                        let ftsStart = DispatchTime.now().uptimeNanoseconds
                        var values: [SQLValue] = [.text("\"" + query.tokens.joined(separator: " ") + "\""), .integer(generation)]
                        var sql = """
                            SELECT d.id,d.version FROM chunk_fts
                            JOIN chunks c ON c.pk=chunk_fts.rowid JOIN fields f ON f.pk=c.field
                            JOIN documents d ON d.pk=f.document WHERE chunk_fts MATCH ? AND c.generation=?
                              AND NOT EXISTS(SELECT 1 FROM group_epochs g WHERE g.id=d.group_id AND g.version>=d.version)
                            """
                        if let group = request.groupID { sql += " AND d.group_id=?"; values.append(.text(group)) }
                        if let kind = request.kind { sql += " AND d.kind=?"; values.append(.text(kind)) }
                        if let from = request.fromTimestamp { sql += " AND d.timestamp>=?"; values.append(.integer(from)) }
                        if let through = request.throughTimestamp { sql += " AND d.timestamp<=?"; values.append(.integer(through)) }
                        sql += " GROUP BY d.pk ORDER BY d.timestamp DESC,d.id COLLATE BINARY DESC LIMIT ?"
                        values.append(.integer(Int64(configuration.maximumResults + 1)))
                        var candidates: [Candidate] = []
                        try db.statement(sql, values: values) {
                            while try db.step($0) { try control.check(); candidates.append(Candidate(id: db.text($0, 0), version: db.int($0, 1))) }
                        }
                        let truncated = candidates.count > configuration.maximumResults
                        if truncated { candidates.removeLast() }
                        if configuration.metricsEnabled { metrics.fts.record(elapsedMilliseconds(since: ftsStart)) }
                        current = QuerySnapshot(id: UUID(), request: request, generation: generation,
                            created: DispatchTime.now().uptimeNanoseconds, candidates: candidates, truncated: truncated)
                    }
                    let materializeStart = DispatchTime.now().uptimeNanoseconds
                    var offset = cursor?.offset ?? 0, hits: [SearchHit] = [], returnedBytes = 0
                    while offset < current.candidates.count && hits.count < request.pageSize {
                        try control.check()
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
                            let text = try CharacterTokenizer.tokenize(field.text, mode: mode,
                                byteLimit: configuration.maximumDocumentBytes, check: control.check)
                            let ranges = try CharacterTokenizer.matchingRanges(in: text, query: query.tokens, check: control.check)
                            if !ranges.isEmpty {
                                let hash = try db.string("SELECT lower(hex(hash)) FROM documents WHERE id=?", [.text(document.id)])
                                hits.append(SearchHit(document: document, fieldID: field.id, contentHash: hash, ranges: ranges))
                                returnedBytes += bytes; break
                            }
                        }
                    }
                    try control.check()
                    let status = try readStatus(db, path: configuration.path)
                    snapshot = current
                    if configuration.metricsEnabled {
                        metrics.materialization.record(elapsedMilliseconds(since: materializeStart))
                        metrics.execution.record(elapsedMilliseconds(since: start))
                    }
                    return SearchPage(hits: hits, nextCursor: offset < current.candidates.count ? SearchCursor(snapshotID: current.id, offset: offset) : nil,
                                      resultsTruncated: current.truncated, status: status)
                }
            }
        } catch {
            if configuration.metricsEnabled {
                if error is CancellationError { metrics.cancelled += 1 }
                if error as? SearchIndexError == .timeout { metrics.timedOut += 1 }
            }
            throw error
        }
    }
}
