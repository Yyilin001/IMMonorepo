import NIOCore

/// A bounded result published only after this query's own Sync reaches idle.
public struct PostgresIndependentQueryResult: Sendable {
    public let rows: [PostgresRow]
    public let commandTag: String
}

public enum PostgresIndependentQueryError: Error, Sendable {
    /// No bytes for this query were submitted; retrying through an exclusive path is safe.
    case notSubmitted
    /// The connection closed or the response exceeded its bound before commit confirmation.
    case outcomeUnknown
}

final class IndependentQueryContext: Sendable {
    let query: PostgresQuery
    let promise: EventLoopPromise<PostgresIndependentQueryResult>
    init(query: PostgresQuery, promise: EventLoopPromise<PostgresIndependentQueryResult>) {
        self.query = query
        self.promise = promise
    }
}
