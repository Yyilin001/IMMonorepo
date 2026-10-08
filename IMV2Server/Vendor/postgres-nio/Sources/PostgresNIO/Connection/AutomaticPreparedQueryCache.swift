import NIOConcurrencyHelpers

/// Per physical connection; query() may be called outside its EventLoop.
/// The driver's existing prepared-statement state machine owns preparation,
/// concurrent first-use merging, execution, and connection-close cleanup.
final class AutomaticPreparedQueryCache: Sendable {
    private struct Key: Hashable {
        let sql: String
        let types: [PostgresDataType]
    }
    private let names = NIOLockedValueBox<[Key: String]>([:])
    private let capacity: Int
    private let prefixes: [String]

    init?(options: PostgresConnection.Configuration.Options) {
        guard options.preparedQueryCacheCapacity > 0, !options.preparedQuerySQLPrefixes.isEmpty else { return nil }
        capacity = min(64, options.preparedQueryCacheCapacity)
        prefixes = options.preparedQuerySQLPrefixes
    }

    func name(for query: PostgresQuery) -> String? {
        guard prefixes.contains(where: { query.sql.hasPrefix($0) }) else { return nil }
        let key = Key(sql: query.sql, types: query.binds.metadata.map(\.dataType))
        return names.withLockedValue { names in
            if let name = names[key] { return name }
            guard names.count < capacity else { return nil }
            let name = "nio-postgres-auto-\(names.count)"
            names[key] = name
            return name
        }
    }
}
