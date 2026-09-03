import Foundation

public struct V2PublicIdentityLookupRateLimitPolicy: Equatable, Sendable {
    public let maximumQueries: Int
    public let window: TimeInterval

    public init(maximumQueries: Int, window: TimeInterval) throws {
        // PostgreSQL stores query_count as a signed 32-bit integer. Reserve
        // one value above the budget as the saturated/denied sentinel.
        guard maximumQueries > 0,
              maximumQueries < Int(Int32.max),
              window > 0,
              window.isFinite
        else { throw V2PublicIdentityLookupRateLimitError.invalidPolicy }
        self.maximumQueries = maximumQueries
        self.window = window
    }
}

public enum V2PublicIdentityLookupRateLimitError: Error, Equatable, Sendable { case invalidPolicy }
