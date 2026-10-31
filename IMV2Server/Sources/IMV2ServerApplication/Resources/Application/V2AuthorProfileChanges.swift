import Foundation
import IMV2Core

/// Committed content invalidation, never a presentation or an access grant.
public struct V2AuthorProfileChange: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        case publicProfile(UserID)
        case contactAlias(owner: UserID, target: UserID)
        case relationship(UserID, UserID)
        case userBlock(actor: UserID, target: UserID)
    }
    public let sequence: UInt64
    public let scope: Scope
    public let revision: UInt64
    public init(sequence: UInt64, userID: UserID, revision: UInt64) throws {
        try self.init(sequence: sequence, scope: .publicProfile(userID), revision: revision)
    }
    public init(sequence: UInt64, scope: Scope, revision: UInt64) throws {
        let users: [UserID]
        switch scope {
        case .publicProfile(let user): users = [user]
        case .contactAlias(let a, let b), .relationship(let a, let b), .userBlock(let a, let b): users = [a, b]
        }
        guard sequence > 0, sequence <= UInt64(Int64.max), users.allSatisfy({ $0.uuidValue != nil }),
              Set(users).count == users.count,
              revision > 0, revision <= UInt64(Int64.max) else { throw V2ResourceValidationError.invalidPresentationLease }
        self.sequence = sequence; self.scope = scope; self.revision = revision
    }
}

/// A reset is a retention/startup boundary. Readers must refresh the complete
/// current visible set before relying on this cursor, including on reconnect.
public struct V2AuthorProfileChangeBatch: Sendable {
    public let head: UInt64
    public let resetRequired: Bool
    public let changes: [V2AuthorProfileChange]
    public init(head: UInt64, resetRequired: Bool, changes: [V2AuthorProfileChange]) throws {
        guard head <= UInt64(Int64.max), changes.count <= 128,
              !resetRequired || changes.isEmpty,
              changes.allSatisfy({ $0.sequence <= head }),
              zip(changes, changes.dropFirst()).allSatisfy({ $0.sequence + 1 == $1.sequence }) else {
            throw V2ResourceValidationError.invalidPresentationLease
        }
        self.head = head; self.resetRequired = resetRequired; self.changes = changes
    }
}

public protocol V2AuthorProfileChangeReading: Sendable {
    /// nil establishes a fresh boundary. Every call uses one database snapshot.
    func readChanges(after cursor: UInt64?) async throws -> V2AuthorProfileChangeBatch
}
