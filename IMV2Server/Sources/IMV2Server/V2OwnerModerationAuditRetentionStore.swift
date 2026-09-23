import Foundation

/// Audit copies live beside their room owner, but are not room recovery or
/// idempotency authority. Expiry deletes no moderation operation or event.
/// Visit physical owners with one shared row budget and rotate the first
/// owner so a busy or failing database cannot starve every subsequent owner.
public actor V2OwnerModerationAuditRetentionStore: V2ModerationAuditRetentionStore {
    private let owners: [any V2ModerationAuditRetentionStore]
    private var nextOwner = 0

    public init(owners: [any V2ModerationAuditRetentionStore]) {
        precondition(!owners.isEmpty && owners.count <= 256)
        self.owners = owners
    }

    public func deleteExpiredAuditEntries(now: Date, limit: Int) async throws -> Int {
        guard limit > 0 else { throw V2ModerationStoreError.corruptPersistenceState }
        let first = nextOwner
        nextOwner = (first + 1) % owners.count
        var deleted = 0
        for offset in 0..<owners.count where deleted < limit {
            try Task.checkCancellation()
            let count = try await owners[(first + offset) % owners.count]
                .deleteExpiredAuditEntries(now: now, limit: limit - deleted)
            guard count >= 0, count <= limit - deleted else {
                throw V2ModerationStoreError.corruptPersistenceState
            }
            deleted += count
        }
        return deleted
    }
}
