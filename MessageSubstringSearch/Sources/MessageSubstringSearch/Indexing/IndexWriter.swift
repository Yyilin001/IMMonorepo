import Foundation
import CryptoKit

struct StoredEvent {
    let sequence: Int64
    let change: IndexChange
}

package enum FaultPoint: String, CaseIterable, Sendable {
    case afterAccept, afterOldIndexRemoval, beforeProgress, beforeCommit, beforeGenerationSwitch, afterGenerationSwitch
}

actor IndexWriter {
    nonisolated let executor = DatabaseExecutor("MessageSubstringSearch.writer")
    nonisolated let stop = OperationControl()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    let configuration: SearchConfiguration
    private var database: SQLiteConnection?
    private var lease: StoreLease?
    private var pump: Task<Void, Never>?
    private var metrics = IndexMetrics()
    private var fault: (@Sendable (FaultPoint) throws -> Void)?
    init(_ configuration: SearchConfiguration) { self.configuration = configuration }
    private var db: SQLiteConnection { get throws { guard let database else { throw SearchIndexError.closed }; return database } }

    func initialize() throws -> SQLiteCapabilities {
        let lease = try StoreLease(path: configuration.path)
        let database = try SQLiteConnection(path: configuration.path, cacheCapacity: configuration.statementCacheCapacity)
        try Schema.open(database, configuration: configuration)
        self.lease = lease; self.database = database
        return try database.capabilities()
    }
    func close() throws {
        pump?.cancel(); pump = nil
        try database?.close(); database = nil; lease = nil
    }
    func purge() throws {
        guard database != nil, lease != nil else { throw SearchIndexError.closed }
        pump?.cancel(); pump = nil
        try database?.close(); database = nil
        // 删除完成前持有文件锁，防止另一个实例在 close 与 remove 之间重新打开。
        defer { lease = nil }
        for suffix in ["", "-wal", "-shm"] {
            let path = configuration.path + suffix
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        }
    }
    func setFault(_ fault: (@Sendable (FaultPoint) throws -> Void)?) { self.fault = fault }
    func limitDatabaseGrowthForTesting() throws {
        let db = try db, pages = try db.integer("PRAGMA page_count")
        try db.execute("PRAGMA max_page_count=\(pages)")
    }
    func diagnostics(reset: Bool) -> IndexMetrics { let result = metrics; if reset { metrics = IndexMetrics() }; return result }
    func status() throws -> IndexStatus { try readStatus(db, path: configuration.path) }
    func setCoverage(_ coverage: SourceCoverage) throws {
        let db = try db
        try db.transaction {
            if case .caughtUp(let cursor) = coverage {
                let status = try readStatus(db, path: configuration.path)
                guard status.acceptedEventsIndexed, status.acceptedSourceCheckpoint == cursor,
                      status.indexedSourceCheckpoint == cursor else { throw SearchIndexError.checkpointConflict }
            }
            try db.setMeta("sourceCoverage", String(decoding: JSONEncoder().encode(coverage), as: UTF8.self))
        }
    }

    func enqueue(_ changes: [IndexChange], checkpoint: SourceCheckpoint?, requestedAt: UInt64, control: OperationControl) throws -> IndexReceipt {
        let control = OperationControl(parents: [control, stop])
        let start = DispatchTime.now().uptimeNanoseconds, db = try db
        if configuration.metricsEnabled { metrics.queueWait.record(elapsedMilliseconds(since: requestedAt)) }
        try control.check()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let prepared = try changes.map { change -> (IndexChange, String, Data) in
            try control.check()
            let data = try encoder.encode(change)
            return (change, String(decoding: data, as: UTF8.self), Self.digest(data))
        }
        guard prepared.reduce(0, { $0 + $1.1.utf8.count }) <= configuration.maximumBatchBytes else {
            throw SearchIndexError.invalidArgument("encoded batch byte limit exceeded")
        }
        var accepted: Int64 = 0, duplicates: Int64 = 0
        let receipt = try db.transaction {
            if let checkpoint, try db.meta("acceptedCursor") != checkpoint.expected { throw SearchIndexError.checkpointConflict }
            var pendingBytes = try db.integer("SELECT coalesce(sum(bytes),0) FROM events WHERE state IN (0,2)")
            var pendingCount = try db.integer("SELECT count(*) FROM events WHERE state IN (0,2)")
            for (change, payload, hash) in prepared {
                try control.check()
                let old = try db.blob("SELECT hash FROM events WHERE id=?", [.text(change.eventID)])
                if !old.isEmpty {
                    guard old == hash else { throw SearchIndexError.conflictingEvent(change.eventID) }
                    duplicates += 1; continue
                }
                pendingBytes += Int64(payload.utf8.count); pendingCount += 1
                guard pendingBytes <= configuration.maximumInboxBytes, pendingCount <= configuration.maximumInboxCount else {
                    throw SearchIndexError.backpressure
                }
                try db.run("INSERT INTO events(id,hash,bytes,accepted) VALUES(?,?,?,?)",
                    [.text(change.eventID), .blob(hash), .integer(Int64(payload.utf8.count)),
                     .text(String(Date().timeIntervalSince1970))])
                // 临时大 payload 与长期去重台账分离，消费后整行释放供后续批次复用。
                try db.run("INSERT INTO event_payloads VALUES(last_insert_rowid(),?)", [.text(payload)])
                accepted += 1
            }
            let sequence = try db.integer("SELECT coalesce(max(seq),0) FROM events")
            if let checkpoint {
                try db.setMeta("acceptedCursor", checkpoint.next)
                try db.run("INSERT INTO checkpoints VALUES(?,?) ON CONFLICT(seq) DO UPDATE SET cursor=excluded.cursor",
                           [.integer(sequence), .text(checkpoint.next)])
                try advanceProgress(db)
            }
            try control.check()
            return try IndexReceipt(sequence: sequence, storeID: db.meta("store"))
        }
        if configuration.metricsEnabled { metrics.accepted += accepted; metrics.duplicates += duplicates; metrics.enqueue.record(elapsedMilliseconds(since: start)) }
        try fault?(.afterAccept)
        if configuration.automaticallyProcess { startProcessing() }
        return receipt
    }

    func startProcessing() {
        guard pump == nil, database != nil else { return }
        // 后台 pump 有明确所有者；关闭会取消，错误保留在持久队列，状态接口可观察。
        pump = Task { [weak self] in await self?.drain() }
    }
    private func drain() async {
        defer { pump = nil }
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        while !Task.isCancelled {
            do {
                guard try processBatch(control: OperationControl()) > 0 else { return }
            } catch { return }
            await Task.yield()
        }
    }

    func processBatch(control: OperationControl) throws -> Int {
        let control = OperationControl(parents: [control, stop])
        let db = try db
        try control.check()
        var events: [StoredEvent] = [], bytes = 0
        var invalidPayloadSequence: Int64?
        try db.statement("SELECT e.seq,p.payload,e.bytes FROM events e LEFT JOIN event_payloads p ON p.seq=e.seq WHERE e.state=0 ORDER BY e.seq LIMIT ?",
                         values: [.integer(Int64(configuration.processingBatchCount))]) { statement in
            while try db.step(statement) {
                let size = Int(db.int(statement, 2))
                if !events.isEmpty && bytes + size > configuration.processingBatchBytes { break }
                let sequence = db.int(statement, 0)
                do {
                    events.append(StoredEvent(sequence: sequence,
                        change: try JSONDecoder().decode(IndexChange.self, from: Data(db.text(statement, 1).utf8))))
                } catch {
                    invalidPayloadSequence = sequence; break
                }
                bytes += size
            }
        }
        if let sequence = invalidPayloadSequence {
            // 损坏的队列记录必须成为可观察失败，不能让后台 pump 退出后永远显示“等待中”。
            try db.run("UPDATE events SET state=2,error='invalidPayload' WHERE seq=?", [.integer(sequence)])
            if configuration.metricsEnabled { metrics.failedBatches += 1 }
            throw SearchIndexError.failedEvent(sequence: sequence, code: "invalidPayload")
        }
        guard !events.isEmpty else { return 0 }
        var current: Int64 = events[0].sequence
        let previousMetrics = metrics
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try db.controlled(control) {
                try db.execute("BEGIN IMMEDIATE")
                do {
                    for event in events {
                        current = event.sequence; try control.check()
                        try apply(event.change.operation, db: db, control: control)
                        try db.run("UPDATE events SET state=1,bytes=0,error='' WHERE seq=?", [.integer(current)])
                        try db.run("DELETE FROM event_payloads WHERE seq=?", [.integer(current)])
                    }
                    try fault?(.beforeProgress)
                    try advanceProgress(db)
                    try fault?(.beforeCommit)
                    try control.check()
                    let commitStart = DispatchTime.now().uptimeNanoseconds
                    try db.execute("COMMIT")
                    if configuration.metricsEnabled { metrics.commit.record(elapsedMilliseconds(since: commitStart)) }
                } catch { try? db.execute("ROLLBACK"); throw error }
            }
        } catch {
            metrics = previousMetrics
            if error is CancellationError || error as? SearchIndexError == .timeout { throw error }
            // 失败批次已回滚。只标记失败事件，不让 checkpoint 越过缺口；原 payload 保留供重试。
            let code = Self.errorCode(error)
            try db.run("UPDATE events SET state=2,error=? WHERE seq=?", [.text(code), .integer(current)])
            if configuration.metricsEnabled { metrics.failedBatches += 1 }
            throw SearchIndexError.failedEvent(sequence: current, code: code)
        }
        if configuration.metricsEnabled { metrics.indexed += Int64(events.count); metrics.transaction.record(elapsedMilliseconds(since: start)) }
        return events.count
    }

    func retryFailed() throws {
        try db.run("UPDATE events SET state=0,error='' WHERE state=2")
        if configuration.automaticallyProcess { startProcessing() }
    }
    func checkReceipt(_ receipt: IndexReceipt) throws -> Bool {
        let db = try db
        guard try receipt.storeID == db.meta("store"), try receipt.sequence <= db.integer("SELECT coalesce(max(seq),0) FROM events") else {
            throw SearchIndexError.invalidArgument("receipt belongs to another store")
        }
        try db.statement("SELECT seq,error FROM events WHERE state=2 AND seq<=? ORDER BY seq LIMIT 1", values: [.integer(receipt.sequence)]) {
            if try db.step($0) { throw SearchIndexError.failedEvent(sequence: db.int($0, 0), code: db.text($0, 1)) }
        }
        return try receipt.sequence <= (Int64(db.meta("indexed")) ?? 0)
    }
    private func advanceProgress(_ db: SQLiteConnection) throws {
        let firstUnfinished = try db.integer("SELECT coalesce(min(seq),0) FROM events WHERE state IN (0,2)")
        let complete = try firstUnfinished == 0 ? db.integer("SELECT coalesce(max(seq),0) FROM events") : firstUnfinished - 1
        try db.setMeta("indexed", String(complete))
        let cursor = try db.string("SELECT cursor FROM checkpoints WHERE seq<=? ORDER BY seq DESC LIMIT 1", [.integer(complete)])
        try db.setMeta("indexedCursor", cursor)
    }

    private func apply(_ operation: IndexOperation, db: SQLiteConnection, control: OperationControl) throws {
        switch operation {
        case .upsert(let document): try upsert(document, db: db, control: control)
        case .delete(let id, let version):
            let oldVersion = try db.integer("SELECT coalesce(max(version),-1) FROM documents WHERE id=?", [.text(id)])
            let tombstone = try db.integer("SELECT coalesce(max(version),-1) FROM tombstones WHERE id=?", [.text(id)])
            if version < max(oldVersion, tombstone) { if configuration.metricsEnabled { metrics.staleChanges += 1 }; return }
            try db.run("INSERT INTO tombstones VALUES(?,?) ON CONFLICT(id) DO UPDATE SET version=max(version,excluded.version)", [.text(id), .integer(version)])
            let pk = try db.integer("SELECT pk FROM documents WHERE id=?", [.text(id)])
            if pk != 0 { try removeDocument(pk, db: db) }
        case .clearGroup(let group, let version):
            let old = try db.integer("SELECT coalesce(max(version),-1) FROM group_epochs WHERE id=?", [.text(group)])
            guard version > old else { if configuration.metricsEnabled { metrics.staleChanges += 1 }; return }
            let affected = [SQLValue.text(group), .integer(old), .integer(version)]
            let count = try db.integer("SELECT count(*) FROM documents WHERE group_id=? AND version>? AND version<=?", affected)
            let previews = try db.integer("SELECT count(*) FROM documents WHERE group_id=? AND version>? AND version<=? AND coverage='previewOnly'", affected)
            try adjustCounts(documents: -count, previews: -previews, db: db)
            try db.run("INSERT INTO group_epochs VALUES(?,?) ON CONFLICT(id) DO UPDATE SET version=excluded.version", [.text(group), .integer(version)])
            // 先提交逻辑屏障，查询立即排除旧消息；物理删除交给有界维护批次。
        }
    }

    private func upsert(_ document: SearchDocument, db: SQLiteConnection, control: OperationControl) throws {
        let barrier = try max(db.integer("SELECT coalesce(max(version),-1) FROM tombstones WHERE id=?", [.text(document.id)]),
                             db.integer("SELECT coalesce(max(version),-1) FROM group_epochs WHERE id=?", [.text(document.groupID)]),
                             db.integer("SELECT coalesce(max(g.version),-1) FROM documents d JOIN group_epochs g ON g.id=d.group_id WHERE d.id=?", [.text(document.id)]))
        let oldVersion = try db.integer("SELECT coalesce(max(version),-1) FROM documents WHERE id=?", [.text(document.id)])
        guard document.version > barrier, document.version >= oldVersion else {
            if configuration.metricsEnabled { metrics.staleChanges += 1 }; return
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let hash = Self.digest(try encoder.encode(document.fields))
        let oldHash = try db.blob("SELECT hash FROM documents WHERE id=?", [.text(document.id)])
        if oldVersion == document.version {
            let existing = try loadDocument(db, id: document.id)
            guard existing == document else { throw SearchIndexError.invalidArgument("conflicting document version") }
            if configuration.metricsEnabled { metrics.unchangedContents += 1 }; return
        }
        let oldVisible = try db.integer("SELECT count(*) FROM documents d WHERE id=? AND NOT EXISTS(SELECT 1 FROM group_epochs g WHERE g.id=d.group_id AND g.version>=d.version)", [.text(document.id)])
        let oldPreview = try db.string("SELECT coverage FROM documents WHERE id=?", [.text(document.id)]) == ContentCoverage.previewOnly.rawValue
        try adjustCounts(documents: 1 - oldVisible,
                         previews: (document.coverage == .previewOnly ? 1 : 0) - (oldPreview ? oldVisible : 0), db: db)
        try db.run("""
            INSERT INTO documents(id,group_id,version,timestamp,kind,coverage,hash) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET group_id=excluded.group_id,version=excluded.version,timestamp=excluded.timestamp,
              kind=excluded.kind,coverage=excluded.coverage,hash=excluded.hash
            """, [.text(document.id), .text(document.groupID), .integer(document.version), .integer(document.timestamp),
                   .text(document.kind), .text(document.coverage.rawValue), .blob(hash)])
        let pk = try db.integer("SELECT pk FROM documents WHERE id=?", [.text(document.id)])
        if oldHash == hash { if configuration.metricsEnabled { metrics.unchangedContents += 1 }; return }
        try removeFields(pk, db: db)
        try fault?(.afterOldIndexRemoval)
        let generation = Int64(try db.meta("generation")) ?? 1, building = Int64(try db.meta("building")) ?? 0
        for field in document.fields {
            try db.run("INSERT INTO fields(document,id,body) VALUES(?,?,?)", [.integer(pk), .text(field.id), .text(field.text)])
            let fieldPK = try db.integer("SELECT last_insert_rowid()")
            try addChunks(field: fieldPK, text: field.text, generation: generation, db: db, control: control)
            if building != 0 { try addChunks(field: fieldPK, text: field.text, generation: building, db: db, control: control) }
        }
    }

    private func addChunks(field: Int64, text: String, generation: Int64, db: SQLiteConnection, control: OperationControl) throws {
        let startTime = DispatchTime.now().uptimeNanoseconds
        let modeKey = String(generation) == (try db.meta("building")) ? "buildingMode" : "mode"
        guard let mode = SearchTextMode(rawValue: try db.meta(modeKey)) else { throw SearchIndexError.incompatibleIndex }
        // 记录完整字素边界对应的 UTF-8 范围，按需重建只处理当前块，不重复遍历整篇长文。
        let text = try CharacterTokenizer.tokenize(text, mode: mode, byteLimit: configuration.maximumDocumentBytes, check: control.check)
        if configuration.metricsEnabled { metrics.tokenize.record(elapsedMilliseconds(since: startTime)) }
        let stride = configuration.chunkCharacters - configuration.maximumQueryCharacters + 1
        // 整个合法查询必落入一个块；不能让非重叠块边界造成漏搜。
        var start = 0
        while start < text.tokens.count {
            try control.check()
            var nextStart = start + min(stride, text.tokens.count - start)
            while nextStart < text.tokens.count && text.sourceBytes[nextStart].lowerBound < text.sourceBytes[nextStart - 1].upperBound {
                nextStart += 1
            }
            var end = nextStart + min(text.tokens.count - nextStart, configuration.maximumQueryCharacters - 1)
            while end < text.tokens.count && text.sourceBytes[end].lowerBound < text.sourceBytes[end - 1].upperBound { end += 1 }
            let encoded = text.encoded(start..<end)
            try db.run("INSERT INTO chunks(field,generation,byte_start,byte_count,mode) VALUES(?,?,?,?,?)", [.integer(field), .integer(generation), .integer(Int64(text.sourceBytes[start].lowerBound)), .integer(Int64(text.sourceBytes[end - 1].upperBound - text.sourceBytes[start].lowerBound)), .text(mode.rawValue)])
            let pk = try db.integer("SELECT last_insert_rowid()")
            try db.run("INSERT INTO chunk_fts(rowid,tokens) VALUES(?,?)", [.integer(pk), .text(encoded)])
            if end == text.tokens.count { break }
            start = nextStart
        }
    }
    private func removeChunks(_ predicate: String, values: [SQLValue], db: SQLiteConnection) throws {
        // external-content 删除必须使用旧 tokens，与内容删除处于同一事务。
        try db.run("INSERT INTO chunk_fts(chunk_fts,rowid,tokens) SELECT 'delete',pk,tokens FROM chunk_content WHERE pk IN (SELECT pk FROM chunks WHERE " + predicate + ")", values)
        try db.run("DELETE FROM chunks WHERE " + predicate, values)
    }
    private func removeFields(_ pk: Int64, db: SQLiteConnection) throws {
        try removeChunks("field IN (SELECT pk FROM fields WHERE document=?)", values: [.integer(pk)], db: db)
        try db.run("DELETE FROM fields WHERE document=?", [.integer(pk)])
    }
    private func removeDocument(_ pk: Int64, db: SQLiteConnection) throws {
        let visible = try db.integer("SELECT count(*) FROM documents d WHERE pk=? AND NOT EXISTS(SELECT 1 FROM group_epochs g WHERE g.id=d.group_id AND g.version>=d.version)", [.integer(pk)])
        let preview = try db.string("SELECT coverage FROM documents WHERE pk=?", [.integer(pk)]) == ContentCoverage.previewOnly.rawValue
        try adjustCounts(documents: -visible, previews: preview ? -visible : 0, db: db)
        try removeFields(pk, db: db); try db.run("DELETE FROM documents WHERE pk=?", [.integer(pk)])
    }
    private func adjustCounts(documents: Int64, previews: Int64, db: SQLiteConnection) throws {
        // 覆盖计数与文档/屏障共事务更新，查询不用扫描整个业务表来显示进度。
        if documents != 0 { try db.run("UPDATE meta SET value=CAST(value AS INTEGER)+? WHERE key='visibleDocuments'", [.integer(documents)]) }
        if previews != 0 { try db.run("UPDATE meta SET value=CAST(value AS INTEGER)+? WHERE key='previewDocuments'", [.integer(previews)]) }
    }

    func beginRebuild(mode: SearchTextMode? = nil) throws {
        let db = try db
        if try db.meta("building") != "0" {
            if let mode, try db.meta("buildingMode") != mode.rawValue { throw SearchIndexError.invalidArgument("different rebuild already in progress") }
            return
        }
        try db.transaction {
            try db.setMeta("building", String((Int64(db.meta("generation")) ?? 1) + 1))
            try db.setMeta("buildingMode", mode?.rawValue ?? db.meta("mode"))
            try db.setMeta("rebuildCursor", "0")
        }
    }
    /// 每步独立事务。补建期间新增/修改双写 generation，崩溃后从持久游标继续。
    func rebuildStep(count: Int, control: OperationControl) throws -> Bool {
        let control = OperationControl(parents: [control, stop])
        let db = try db, start = DispatchTime.now().uptimeNanoseconds
        let generation = Int64(try db.meta("building")) ?? 0
        guard generation != 0 else { return true }
        let cursor = Int64(try db.meta("rebuildCursor")) ?? 0
        var documents: [Int64] = []
        try db.statement("SELECT pk FROM documents WHERE pk>? ORDER BY pk LIMIT ?", values: [.integer(cursor), .integer(Int64(count))]) {
            while try db.step($0) { documents.append(db.int($0, 0)) }
        }
        try db.controlled(control) {
            try db.transaction {
                for pk in documents {
                    try control.check()
                    try removeChunks("generation=? AND field IN (SELECT pk FROM fields WHERE document=?)", values: [.integer(generation), .integer(pk)], db: db)
                    var fields: [(Int64, String)] = []
                    try db.statement("SELECT pk,body FROM fields WHERE document=?", values: [.integer(pk)]) {
                        while try db.step($0) { fields.append((db.int($0, 0), db.text($0, 1))) }
                    }
                    for (field, text) in fields { try addChunks(field: field, text: text, generation: generation, db: db, control: control) }
                    try db.setMeta("rebuildCursor", String(pk))
                }
                if documents.count < count {
                    try fault?(.beforeGenerationSwitch)
                    try db.setMeta("generation", String(generation)); try db.setMeta("mode", db.meta("buildingMode"))
                    try db.setMeta("building", "0")
                }
                try control.check()
            }
        }
        if configuration.metricsEnabled { metrics.maintenance.record(elapsedMilliseconds(since: start)) }
        if documents.count < count { try fault?(.afterGenerationSwitch) }
        return documents.count < count
    }

    func maintain() throws {
        let db = try db, start = DispatchTime.now().uptimeNanoseconds
        let active = Int64(try db.meta("generation")) ?? 1
        try db.transaction {
            var expired: [(Int64, String, Int64)] = []
            try db.statement("SELECT d.pk,d.id,g.version FROM group_epochs g CROSS JOIN documents d ON d.group_id=g.id WHERE d.version<=g.version LIMIT 100") {
                while try db.step($0) { expired.append((db.int($0, 0), db.text($0, 1), db.int($0, 2))) }
            }
            for (pk, id, version) in expired {
                try db.run("INSERT INTO tombstones VALUES(?,?) ON CONFLICT(id) DO UPDATE SET version=max(version,excluded.version)", [.text(id), .integer(version)])
                try removeDocument(pk, db: db)
            }
            try removeChunks("pk IN (SELECT pk FROM chunks WHERE generation<? LIMIT 1000)", values: [.integer(active)], db: db)
            try db.run("INSERT INTO chunk_fts(chunk_fts,rank) VALUES('merge',32)")
        }
        try db.execute("PRAGMA wal_checkpoint(PASSIVE)")
        if configuration.metricsEnabled { metrics.maintenance.record(elapsedMilliseconds(since: start)) }
    }
    func integrityCheck() throws {
        let db = try db
        guard try db.string("PRAGMA integrity_check") == "ok" else { throw SearchIndexError.incompatibleIndex }
        try db.run("INSERT INTO chunk_fts(chunk_fts,rank) VALUES('integrity-check',1)")
        guard try db.integer("SELECT count(*) FROM pragma_foreign_key_check") == 0 else { throw SearchIndexError.incompatibleIndex }
        let visible = try db.integer("SELECT count(*) FROM documents d WHERE NOT EXISTS(SELECT 1 FROM group_epochs g WHERE g.id=d.group_id AND g.version>=d.version)")
        let previews = try db.integer("SELECT count(*) FROM documents d WHERE coverage='previewOnly' AND NOT EXISTS(SELECT 1 FROM group_epochs g WHERE g.id=d.group_id AND g.version>=d.version)")
        guard try visible == Int64(db.meta("visibleDocuments")), try previews == Int64(db.meta("previewDocuments")) else {
            throw SearchIndexError.incompatibleIndex
        }
    }
    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private static func errorCode(_ error: Error) -> String {
        if case SearchIndexError.sqlite(let code, _) = error { return "sqlite:\(code)" }
        if case SearchIndexError.invalidArgument = error { return "invalidArgument" }
        return "indexingFailure"
    }
}

func loadDocument(_ db: SQLiteConnection, id: String) throws -> SearchDocument? {
    try db.statement("SELECT pk,group_id,version,timestamp,kind,coverage FROM documents WHERE id=?", values: [.text(id)]) { statement in
        guard try db.step(statement) else { return nil }
        var fields: [SearchField] = []
        try db.statement("SELECT id,body FROM fields WHERE document=? ORDER BY pk", values: [.integer(db.int(statement, 0))]) {
            while try db.step($0) { fields.append(SearchField(id: db.text($0, 0), text: db.text($0, 1))) }
        }
        return SearchDocument(id: id, groupID: db.text(statement, 1), version: db.int(statement, 2), timestamp: db.int(statement, 3),
                              kind: db.text(statement, 4), coverage: ContentCoverage(rawValue: db.text(statement, 5)) ?? .previewOnly, fields: fields)
    }
}
