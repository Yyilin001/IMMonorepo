import Foundation

package enum V2PolicyAuthorizationScope: Hashable, Sendable {
    case account(UUID)
    case stranger(UUID)
    case pair(UUID, UUID)

    package var key: String {
        switch self {
        case .stranger(let user): "stranger:" + user.uuidString.lowercased()
        case .account(let user): "account:" + user.uuidString.lowercased()
        case .pair(let first, let second):
            "pair:" + [first, second].map { $0.uuidString.lowercased() }.sorted().joined(separator: ":")
        }
    }

    package var isValid: Bool {
        if case .pair(let first, let second) = self { return first != second }
        return true
    }
}

/// All times in this durable contract come from PostgreSQL after row locks.
/// Transport consumers convert expiry to a conservative local clock deadline;
/// a wall-clock timestamp alone is never authority to release an SQL execution.
package struct V2PolicyOwnerLease: Sendable, Equatable {
    package let scope: V2PolicyAuthorizationScope
    package let ownerID: UUID
    package let epoch: Int64
    package let revision: Int64
    package let validUntil: Date
    package init(scope: V2PolicyAuthorizationScope, ownerID: UUID, epoch: Int64, revision: Int64, validUntil: Date) {
        self.scope = scope; self.ownerID = ownerID; self.epoch = epoch
        self.revision = revision; self.validUntil = validUntil
    }
}

package struct V2PolicyAuthorizationHolder: Sendable, Equatable {
    package let registrationID: UUID
    package let roomID: UUID
    package let activationID: UUID
    package let roomOwnerEpoch: Int64
    package let generation: Int64
    /// Server-owned route locator. Never accept this from a client payload.
    package let endpoint: String
    package let validUntil: Date
    package init(registrationID: UUID, roomID: UUID, activationID: UUID, roomOwnerEpoch: Int64,
                 generation: Int64, endpoint: String, validUntil: Date) {
        self.registrationID = registrationID; self.roomID = roomID; self.activationID = activationID
        self.roomOwnerEpoch = roomOwnerEpoch; self.generation = generation
        self.endpoint = endpoint; self.validUntil = validUntil
    }
}

package struct V2PolicyAuthorizationChange: Sendable, Equatable {
    package let operationKey: String
    package let scopeKey: String
    package let fingerprint: Data
    package let commandJSON: String
    package let expectedRevision: Int64
    package let nextRevision: Int64
    package let committed: Bool
    package let receipt: Data?
    package init(operationKey: String, scopeKey: String, fingerprint: Data, commandJSON: String,
                 expectedRevision: Int64, nextRevision: Int64, committed: Bool, receipt: Data?) {
        self.operationKey = operationKey; self.scopeKey = scopeKey; self.fingerprint = fingerprint
        self.commandJSON = commandJSON; self.expectedRevision = expectedRevision
        self.nextRevision = nextRevision; self.committed = committed; self.receipt = receipt
    }
}

package enum V2PolicyAuthorizationLifecycleError: Error, Equatable {
    case invalidRequest, ownerChanged, busy, staleVersion, identityConflict, closed
    case notDrained, invalidTarget, corruptPersistence
}
