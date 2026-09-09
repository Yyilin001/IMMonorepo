import Foundation

/// Deployment-owned parameters for account-handle failure limiting. There are
/// deliberately no source-code defaults: operators must select values
/// appropriate for their recovery and support policy.
public struct V2PasswordLoginRateLimitPolicy: Equatable, Sendable {
    public let maximumFailures: Int
    public let window: TimeInterval
    public let lockout: TimeInterval

    public init(maximumFailures: Int, window: TimeInterval, lockout: TimeInterval) throws {
        guard maximumFailures > 0, maximumFailures <= Int(Int32.max),
              v2RateLimitDurationIsRepresentable(window),
              v2RateLimitDurationIsRepresentable(lockout) else {
            throw V2PasswordLoginRateLimitError.invalidPolicy
        }
        self.maximumFailures = maximumFailures
        self.window = window
        self.lockout = lockout
    }
}

public enum V2PasswordLoginRateLimitError: Error, Equatable, Sendable {
    case invalidPolicy
    case unavailable
}
