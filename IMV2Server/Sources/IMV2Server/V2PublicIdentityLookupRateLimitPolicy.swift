import Foundation

public struct V2PublicIdentityLookupRateLimitPolicy: Equatable, Sendable {
    public let maximumQueries: Int
    public let window: TimeInterval

    public init(maximumQueries: Int, window: TimeInterval) throws {
        guard maximumQueries > 0, window > 0, window.isFinite else { throw V2PublicIdentityLookupRateLimitError.invalidPolicy }
        self.maximumQueries = maximumQueries
        self.window = window
    }
}

public enum V2PublicIdentityLookupRateLimitError: Error, Equatable, Sendable { case invalidPolicy }
