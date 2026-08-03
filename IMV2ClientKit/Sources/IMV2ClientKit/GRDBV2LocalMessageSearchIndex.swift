import Foundation
import GRDB
import IMV2Core

/// The character-gram index is a derived local projection. Keeping it in a
/// dedicated extension makes its rebuild lifecycle independent from command
/// queues and authoritative sync-record application.
extension GRDBV2LocalSyncStore {
    public func rebuildMessageSearchIndex() async throws {
        while !Task.isCancelled {
            let generation = try await databasePool.write { db in
                try Self.beginMessageSearchIndexRebuild(db: db)
            }
            var lastRowID: Int64 = 0

            while !Task.isCancelled {
                let pageStart = lastRowID
                let outcome = try await databasePool.write { db -> V2MessageSearchRebuildOutcome in
                    guard try Self.messageSearchIndexGeneration(db: db) == generation else {
                        return .restartRequired
                    }
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT rowid, message_id, room_id, room_sequence, sender_user_id,
                               text_body, server_created_at, is_withdrawn
                        FROM v2_message_projections
                        WHERE rowid > ?
                        ORDER BY rowid
                        LIMIT 250
                        """,
                        arguments: [pageStart]
                    )
                    guard let last = rows.last else {
                        try Self.finishMessageSearchIndexRebuild(generation: generation, db: db)
                        return .finished
                    }
                    for row in rows {
                        try Self.writeMessageSearchIndex(row: row, db: db)
                    }
                    let nextRowID: Int64 = last["rowid"]
                    return .advanced(nextRowID)
                }
                switch outcome {
                case .advanced(let nextRowID):
                    lastRowID = nextRowID
                    await Task.yield()
                case .finished:
                    return
                case .restartRequired:
                    // A snapshot commit fully rebuilt the derived index inside
                    // its own transaction. Do not discard that fresh index and
                    // start a redundant second pass.
                    if try messageSearchIndexState() == .ready {
                        return
                    }
                    break
                }
                if case .restartRequired = outcome { break }
            }
            try Task.checkCancellation()
        }
        throw CancellationError()
    }

    /// Ensures the derived index is available without needlessly rebuilding a
    /// valid index on every authenticated session activation.
    public func prepareMessageSearchIndex() async throws {
        guard try messageSearchIndexState() != .ready else { return }
        do {
            try await rebuildMessageSearchIndex()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? await databasePool.write { db in
                try db.execute(sql: "UPDATE v2_message_search_state SET state = 'failed' WHERE singleton = 1")
            }
            throw error
        }
    }

    public func messageSearchIndexState() throws -> V2MessageSearchIndexState {
        try databasePool.read { db in try Self.readMessageSearchIndexState(db: db) }
    }

    /// FTS is a candidate index; the normalized Swift substring check is the
    /// final semantic authority for every returned hit.
    public func searchMessages(_ request: V2MessageSearchRequest) throws -> V2MessageSearchPage {
        guard (1 ... 100).contains(request.limit) else { throw V2MessageSearchError.invalidPageSize }
        let tokenizer = V2CharacterGramTokenizer()
        let query = tokenizer.tokenize(request.query)
        // Media-category search is useful even before a text term is entered.
        // Keep an unbounded all-message browse impossible on large histories.
        guard !query.unigrams.isEmpty || request.contentFilter != .all else {
            throw V2MessageSearchError.emptyQuery
        }
        return try databasePool.read { db in
            let state = try Self.readMessageSearchIndexState(db: db)
            guard state == .ready else { throw V2MessageSearchError.indexUnavailable(state) }
            return try Self.searchMessages(request, query: query, db: db)
        }
    }

    static func readMessageSearchIndexState(db: Database) throws -> V2MessageSearchIndexState {
        guard let row = try Row.fetchOne(db, sql: "SELECT index_version, state FROM v2_message_search_state WHERE singleton = 1"),
              let version: Int = row["index_version"],
              let raw: String = row["state"],
              let state = V2MessageSearchIndexState(storageValue: raw)
        else { throw V2ClientProjectionError.invalidMessagePayload }
        return version == V2CharacterGramTokenizer.version ? state : .building
    }

    static func messageSearchIndexGeneration(db: Database) throws -> Int64 {
        guard let generation: Int64 = try Row.fetchOne(db, sql: "SELECT generation FROM v2_message_search_state WHERE singleton = 1")?["generation"]
        else { throw V2ClientProjectionError.invalidMessagePayload }
        return generation
    }

    @discardableResult
    private static func beginMessageSearchIndexRebuild(db: Database) throws -> Int64 {
        let generation = try messageSearchIndexGeneration(db: db)
        guard generation < Int64.max else { throw V2ClientProjectionError.invalidMessagePayload }
        let nextGeneration = generation + 1
        try db.execute(sql: "DELETE FROM v2_message_char_fts")
        try db.execute(
            sql: "UPDATE v2_message_search_state SET index_version = ?, state = 'building', generation = ? WHERE singleton = 1",
            arguments: [V2CharacterGramTokenizer.version, nextGeneration]
        )
        return nextGeneration
    }

    static func resetMessageSearchIndex(db: Database) throws {
        _ = try beginMessageSearchIndexRebuild(db: db)
    }

    static func finishMessageSearchIndexRebuild(generation: Int64, db: Database) throws {
        guard try messageSearchIndexGeneration(db: db) == generation else { return }
        try db.execute(sql: "UPDATE v2_message_search_state SET state = 'ready' WHERE singleton = 1")
    }

    static func refreshMessageSearchIndex(messageID: MessageID, db: Database) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT rowid, message_id, room_id, room_sequence, sender_user_id, text_body, server_created_at, is_withdrawn FROM v2_message_projections WHERE message_id = ?",
            arguments: [messageID.rawValue]
        ) else { return }
        try writeMessageSearchIndex(row: row, db: db)
    }

    private static func writeMessageSearchIndex(row: Row, db: Database) throws {
        let rowID: Int64 = row["rowid"]
        try db.execute(sql: "DELETE FROM v2_message_char_fts WHERE rowid = ?", arguments: [rowID])
        let isWithdrawn: Bool = row["is_withdrawn"]
        let text: String = row["text_body"]
        guard !isWithdrawn, !text.isEmpty else { return }
        let tokens = V2CharacterGramTokenizer().tokenize(text)
        guard !tokens.unigrams.isEmpty else { return }
        let roomID: String = row["room_id"]
        let senderUserID: String = row["sender_user_id"]
        try db.execute(
            sql: "INSERT INTO v2_message_char_fts (rowid, room_scope, sender_scope, unigrams, bigrams) VALUES (?, ?, ?, ?, ?)",
            arguments: [
                rowID,
                V2CharacterGramTokenizer.scopeToken(prefix: "r", identifier: roomID),
                V2CharacterGramTokenizer.scopeToken(prefix: "s", identifier: senderUserID),
                tokens.unigrams.joined(separator: " "),
                tokens.bigrams.joined(separator: " ")
            ]
        )
    }

    private static func searchMessages(_ request: V2MessageSearchRequest, query: V2CharacterGramTokenizer.Tokens, db: Database) throws -> V2MessageSearchPage {
        let match = messageSearchMatch(scope: request.scope, query: query)
        let filterFingerprint = searchFilterFingerprint(request)
        var cursor = try validatedSearchCursor(request.cursor, for: request.scope, filterFingerprint: filterFingerprint)
        var scanCursor = cursor
        var hits: [V2MessageSearchHit] = []
        let batchSize = max(128, request.limit * 2)
        while true {
            let rows = try searchCandidateRows(match: match, request: request, cursor: scanCursor, limit: batchSize, db: db)
            guard !rows.isEmpty else { return .init(hits: hits, nextCursor: nil) }
            for row in rows {
                let candidate = try searchCandidate(row)
                let candidateCursor = searchCursor(for: candidate, scope: request.scope, filterFingerprint: filterFingerprint)
                scanCursor = candidateCursor
                guard query.characterCount == 0 || V2CharacterGramTokenizer.normalize(candidate.text).range(of: query.normalized) != nil else { continue }
                if hits.count == request.limit {
                    // The query has at least one further verified result, so
                    // the cursor after the final included hit is meaningful.
                    return .init(hits: hits, nextCursor: cursor)
                }
                hits.append(candidate)
                cursor = candidateCursor
            }
            if rows.count < batchSize { return .init(hits: hits, nextCursor: nil) }
        }
    }

    private static func messageSearchMatch(scope: V2MessageSearchScope, query: V2CharacterGramTokenizer.Tokens) -> String? {
        var clauses: [String] = []
        switch scope {
        case .room(let roomID):
            clauses.append("room_scope : " + V2CharacterGramTokenizer.scopeToken(prefix: "r", identifier: roomID.rawValue))
        case .allMessages:
            break
        case .sender(let userID):
            clauses.append("sender_scope : " + V2CharacterGramTokenizer.scopeToken(prefix: "s", identifier: userID.rawValue))
        }
        if query.characterCount == 0 {
            // Room and sender constraints are applied to the projection SQL.
            // Do not join FTS here: media-only messages intentionally have no
            // text token and consequently no FTS row.
            return nil
        } else if query.characterCount == 1 {
            clauses.append("unigrams : " + query.unigrams[0])
        } else {
            clauses.append("bigrams : \"" + query.bigrams.joined(separator: " ") + "\"")
        }
        return clauses.joined(separator: " AND ")
    }

    private static func validatedSearchCursor(_ cursor: V2MessageSearchCursor?, for scope: V2MessageSearchScope, filterFingerprint: String) throws -> V2MessageSearchCursor? {
        guard let cursor else { return nil }
        guard cursor.filterFingerprint == filterFingerprint else { throw V2MessageSearchError.cursorDoesNotMatchScope }
        switch (scope, cursor.storage) {
        case (.room(let scopeRoomID), .room(let cursorRoomID, _, _)) where scopeRoomID == cursorRoomID:
            return cursor
        case (.room, _), (.allMessages, .room), (.sender, .room):
            throw V2MessageSearchError.cursorDoesNotMatchScope
        case (.allMessages, .global), (.sender, .global):
            return cursor
        }
    }

    private static func searchCandidateRows(match: String?, request: V2MessageSearchRequest, cursor: V2MessageSearchCursor?, limit: Int, db: Database) throws -> [Row] {
        var clauses = ["p.is_withdrawn = 0"]
        var arguments: [DatabaseValueConvertible] = []
        let from: String
        if let match {
            from = "v2_message_char_fts JOIN v2_message_projections p ON p.rowid = v2_message_char_fts.rowid"
            clauses.append("v2_message_char_fts MATCH ?")
            arguments.append(match)
        } else {
            from = "v2_message_projections p"
        }
        switch request.scope {
        case .room(let roomID): clauses.append("p.room_id = ?"); arguments.append(roomID.rawValue)
        case .allMessages: break
        case .sender(let userID): clauses.append("p.sender_user_id = ?"); arguments.append(userID.rawValue)
        }
        if let senderUserID = request.senderUserID {
            clauses.append("p.sender_user_id = ?")
            arguments.append(senderUserID.rawValue)
        }
        switch request.contentFilter {
        case .all: break
        case .media: clauses.append("json_array_length(p.media_ids) > 0")
        case .image, .video, .file, .audio:
            clauses.append("EXISTS (SELECT 1 FROM json_each(p.media_presentations) WHERE json_extract(json_each.value, '$.kind') = ?)")
            arguments.append(request.contentFilter.rawValue)
        }
        let base = "SELECT p.message_id, p.room_id, p.room_sequence, p.sender_user_id, p.text_body, p.server_created_at FROM \(from) WHERE \(clauses.joined(separator: " AND "))"
        switch (request.scope, cursor?.storage) {
        case (.room, nil):
            arguments.append(limit)
            return try Row.fetchAll(db, sql: base + " ORDER BY p.room_sequence DESC, p.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        case (.room, .room(_, let sequence, let messageID)):
            arguments += [try storageInteger(sequence), try storageInteger(sequence), messageID.rawValue, limit]
            return try Row.fetchAll(db, sql: base + " AND (p.room_sequence < ? OR (p.room_sequence = ? AND p.message_id < ?)) ORDER BY p.room_sequence DESC, p.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        case (.allMessages, nil), (.sender, nil):
            arguments.append(limit)
            return try Row.fetchAll(db, sql: base + " ORDER BY p.server_created_at DESC, p.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        case (.allMessages, .global(let createdAt, let messageID)), (.sender, .global(let createdAt, let messageID)):
            arguments += [createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, messageID.rawValue, limit]
            return try Row.fetchAll(db, sql: base + " AND (p.server_created_at < ? OR (p.server_created_at = ? AND p.message_id < ?)) ORDER BY p.server_created_at DESC, p.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        default:
            throw V2MessageSearchError.cursorDoesNotMatchScope
        }
    }

    private static func searchCandidate(_ row: Row) throws -> V2MessageSearchHit {
        try .init(messageID: .init(row["message_id"] as String), roomID: .init(row["room_id"] as String), roomSequence: UInt64(row["room_sequence"] as Int64), senderUserID: .init(row["sender_user_id"] as String), text: row["text_body"], createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double))
    }

    private static func searchCursor(for hit: V2MessageSearchHit, scope: V2MessageSearchScope, filterFingerprint: String) -> V2MessageSearchCursor {
        switch scope {
        case .room:
            .init(storage: .room(roomID: hit.roomID, roomSequence: hit.roomSequence, messageID: hit.messageID), filterFingerprint: filterFingerprint)
        case .allMessages, .sender:
            .init(storage: .global(createdAt: hit.createdAt, messageID: hit.messageID), filterFingerprint: filterFingerprint)
        }
    }

    private static func searchFilterFingerprint(_ request: V2MessageSearchRequest) -> String {
        let scope: String = switch request.scope {
        case .room(let roomID): "room:\(roomID.rawValue)"
        case .allMessages: "all"
        case .sender(let userID): "sender:\(userID.rawValue)"
        }
        return "\(scope)|\(request.contentFilter.rawValue)|\(request.senderUserID?.rawValue ?? "")"
    }
}
