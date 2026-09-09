import Foundation

public enum V2PushIntentVersionError: Error, Equatable, Sendable {
    case invalidVersion
}

/// Server-granted session epoch plus a client-persisted, monotonically
/// increasing intent revision. This value is not an authorization credential.
public struct V2PushIntentVersion: Equatable, Sendable {
    public let epoch: UInt64
    public let revision: UInt64

    public init(epoch: UInt64, revision: UInt64) throws {
        guard epoch > 0, epoch <= UInt64(Int64.max), revision > 0, revision <= UInt64(Int64.max) else {
            throw V2PushIntentVersionError.invalidVersion
        }
        self.epoch = epoch
        self.revision = revision
    }
}

/// Compare-and-swap session acquisition. Retrying a lost response uses the
/// same request ID and expected epoch; a stale request cannot replace a newer
/// session just because it reaches the server later.
public struct V2PushIntentSessionClaim: Equatable, Sendable {
    public let requestID: UUID
    public let expectedEpoch: UInt64

    public init(requestID: UUID, expectedEpoch: UInt64) throws {
        guard expectedEpoch < UInt64(Int64.max) else { throw V2PushIntentVersionError.invalidVersion }
        self.requestID = requestID
        self.expectedEpoch = expectedEpoch
    }
}
