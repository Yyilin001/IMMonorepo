import Foundation

/// 审计副本与房间所有者存放在一起，但不承担房间恢复或幂等性权威。
/// 过期清理不会删除任何管理操作或事件。
/// 访问物理所有者时共用一个行数预算，并轮换起始所有者，
/// 避免繁忙或故障数据库使后续所有者始终得不到处理。
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
