import NIOCore

/// EventLoop-confined, exclusively borrowed connection path for small atomic writes.
/// Each packet has its own Sync. Ordinary commands run only after this FIFO drains.
final class IndependentQueryPipeline {
    private struct Key: Hashable {
        let sql: String
        let types: [PostgresDataType]
    }
    private struct Statement {
        let name: String
        var columns: [RowDescription.Column]?
    }
    private final class Cycle {
        let context: IndependentQueryContext
        let key: Key
        let name: String
        let bytes: Int
        let parses: Bool
        let describes: Bool
        var parsed = false
        var bound = false
        var described = false
        var columns: [RowDescription.Column]
        var lookup: [String: Int] = [:]
        var rows: [PostgresRow] = []
        var responseBytes = 0
        var commandTag: String?
        var error: PSQLError?
        init(_ context: IndependentQueryContext, key: Key, statement: Statement,
             bytes: Int, parses: Bool, describes: Bool) {
            self.context = context; self.key = key; name = statement.name
            self.bytes = bytes; self.parses = parses; self.describes = describes
            columns = statement.columns ?? []
            for (index, column) in columns.enumerated() { lookup[column.name] = index }
        }
    }
    enum ReadAction { case pass, consumed, close }
    private var cycles: [Cycle] = [] // At most two; array removal never traverses a large queue.
    private var closed = false
    private var bytes = 0
    private var statements: [Key: Statement] = [:]
    private var nextName: UInt64 = 0
    private var encoder = PostgresFrontendMessageEncoder(buffer: ByteBuffer())
    private let cacheCapacity: Int
    private let sqlPrefixes: [String]
    init(cacheCapacity: Int = 16, sqlPrefixes: [String] = []) {
        self.cacheCapacity = max(0, min(16, cacheCapacity))
        self.sqlPrefixes = sqlPrefixes
    }
    var hasPending: Bool { !cycles.isEmpty }

    func enqueue(_ context: IndependentQueryContext) -> ByteBuffer? {
        let query = context.query
        let estimate = query.sql.utf8.count + query.binds.bytes.readableBytes + query.binds.count * 8 + 256
        guard !closed, cycles.count < 2, query.binds.count <= Int(UInt16.max),
              estimate <= 4 * 1024 * 1024, bytes + estimate <= 8 * 1024 * 1024 else { return nil }
        let key = Key(sql: query.sql, types: query.binds.metadata.map(\.dataType))
        let cached = statements[key]
        let parses = cached == nil
        let statement: Statement
        if let cached { statement = cached }
        else {
            // Cache a bounded set of shapes. Other shapes use an unnamed statement.
            let cacheable = query.sql.utf8.count <= 64 * 1024
                && (sqlPrefixes.isEmpty || sqlPrefixes.contains { query.sql.hasPrefix($0) })
            let name = cacheable && statements.count < cacheCapacity ? "nio-independent-\(nextName)" : ""
            nextName &+= 1
            statement = .init(name: name, columns: nil)
        }
        let describes = statement.columns == nil
        if parses {
            encoder.parse(preparedStatementName: statement.name, query: query.sql, parameters: key.types)
            encoder.describePreparedStatement(statement.name)
        }
        encoder.bind(portalName: "", preparedStatementName: statement.name, bind: query.binds)
        if !parses && describes { encoder.describePortal("") }
        encoder.execute(portalName: "")
        encoder.sync()
        let packet = encoder.flushBuffer()
        guard packet.readableBytes <= 4 * 1024 * 1024,
              bytes + packet.readableBytes <= 8 * 1024 * 1024 else { return nil }
        if parses && !statement.name.isEmpty { statements[key] = statement }
        cycles.append(.init(context, key: key, statement: statement,
            bytes: packet.readableBytes, parses: parses, describes: describes))
        bytes += packet.readableBytes
        return packet
    }

    func receive(_ message: PostgresBackendMessage) -> ReadAction {
        guard let cycle = cycles.first else { return .pass }
        switch message {
        case .notification, .notice, .parameterStatus:
            return .pass
        case .parseComplete:
            guard cycle.parses, !cycle.parsed, cycle.error == nil else { return .close }
            cycle.parsed = true
        case .parameterDescription:
            guard cycle.parses, cycle.parsed, cycle.error == nil else { return .close }
        case .rowDescription(let description):
            guard cycle.describes, !cycle.described, cycle.error == nil else { return .close }
            cycle.columns = description.columns.map { column in var c = column; c.format = .binary; return c }
            cycle.lookup = [:]
            for (index, column) in cycle.columns.enumerated() { cycle.lookup[column.name] = index }
            cycle.described = true
            if statements[cycle.key]?.name == cycle.name { statements[cycle.key]?.columns = cycle.columns }
        case .noData:
            guard cycle.describes, !cycle.described, cycle.error == nil else { return .close }
            cycle.described = true
            if statements[cycle.key]?.name == cycle.name { statements[cycle.key]?.columns = [] }
        case .bindComplete:
            guard !cycle.bound, cycle.error == nil, !cycle.parses || cycle.parsed else { return .close }
            cycle.bound = true
        case .dataRow(let row):
            guard cycle.error == nil, cycle.bound, !cycle.describes || cycle.described,
                  Int(row.columnCount) == cycle.columns.count, cycle.commandTag == nil,
                  cycle.rows.count < 64, cycle.responseBytes + row.bytes.readableBytes <= 64 * 1024 else { return .close }
            cycle.responseBytes += row.bytes.readableBytes
            cycle.rows.append(.init(data: row, lookupTable: cycle.lookup, columns: cycle.columns))
        case .commandComplete(let tag):
            guard cycle.bound, !cycle.describes || cycle.described, cycle.error == nil, cycle.commandTag == nil else { return .close }
            cycle.commandTag = tag
        case .error(let response):
            guard response.fields[.severity] != "FATAL", response.fields[.severity] != "PANIC",
                  response.fields[.sqlState] != nil, cycle.error == nil else { return .close }
            cycle.error = .server(response)
            if cycle.parses && !cycle.parsed && statements[cycle.key]?.name == cycle.name {
                statements[cycle.key] = nil
            }
        case .readyForQuery(let status):
            guard status == .idle, cycle.commandTag != nil || cycle.error != nil else { return .close }
            cycles.removeFirst(); bytes -= cycle.bytes
            if let error = cycle.error { cycle.context.promise.fail(error) }
            else { cycle.context.promise.succeed(.init(rows: cycle.rows, commandTag: cycle.commandTag!)) }
        default:
            return .close
        }
        return .consumed
    }

    func failUnconfirmed() {
        closed = true
        let pending = cycles
        cycles.removeAll(); bytes = 0
        for cycle in pending { cycle.context.promise.fail(PostgresIndependentQueryError.outcomeUnknown) }
    }
}
