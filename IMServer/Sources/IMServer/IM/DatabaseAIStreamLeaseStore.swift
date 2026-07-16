import Fluent
import Foundation
import SQLKit
import Vapor

/// PostgreSQL-backed lease store for Redis/Valkey Cluster deployments.
///
/// A reservation locks the user and conversation quota domains in one primary
/// database transaction. This preserves the existing two-dimensional limit
/// without depending on a multi-key Redis script spanning Cluster slots.
final class DatabaseAIStreamLeaseStore: AIStreamLeaseStore, @unchecked Sendable {
    private static let userLimit = 2
    private static let conversationLimit = 5

    private let database: any Database
    private let nodeID: String
    private let leaseTTL: TimeInterval

    init(
        database: any Database,
        nodeID: String,
        leaseTTL: TimeInterval = 180
    ) {
        self.database = database
        self.nodeID = nodeID
        self.leaseTTL = max(1, leaseTTL)
    }

    func start(app _: Application) async throws { }

    func shutdown() async { }

    func reserve(streamID: String, conversationID: UUID, userID: UUID) async throws {
        try await database.transaction { database in
            try await self.lockQuotaDomains(on: database, userID: userID, conversationID: conversationID)
            let now = Date()
            try await self.removeExpiredLeases(
                on: database,
                userID: userID,
                conversationID: conversationID,
                now: now
            )

            if let existing = try await AIStreamLease.find(streamID, on: database) {
                guard existing.userID == userID, existing.conversationID == conversationID else {
                    throw Abort(.conflict, reason: "AI stream lease belongs to another stream context.")
                }
                if existing.expiresAt > now {
                    return
                }
                try await existing.delete(on: database)
            }

            let userCount = try await self.activeLeaseCount(
                on: database,
                field: \AIStreamLease.$userID,
                value: userID,
                now: now
            )
            guard userCount < Self.userLimit else {
                throw Abort(.tooManyRequests, reason: "AI stream concurrency limit reached.")
            }

            let conversationCount = try await self.activeLeaseCount(
                on: database,
                field: \AIStreamLease.$conversationID,
                value: conversationID,
                now: now
            )
            guard conversationCount < Self.conversationLimit else {
                throw Abort(.tooManyRequests, reason: "Conversation AI stream concurrency limit reached.")
            }

            try await AIStreamLease(
                streamID: streamID,
                conversationID: conversationID,
                userID: userID,
                nodeID: self.nodeID,
                expiresAt: now.addingTimeInterval(self.leaseTTL),
                now: now
            ).create(on: database)
        }
    }

    func attach(streamID: String) async throws {
        guard let lease = try await AIStreamLease.find(streamID, on: database), lease.expiresAt > Date() else {
            return
        }
        lease.state = "attached"
        lease.updatedAt = Date()
        try await lease.update(on: database)
    }

    func requestCancel(streamID: String) async throws {
        guard let lease = try await AIStreamLease.find(streamID, on: database), lease.expiresAt > Date() else {
            return
        }
        lease.cancelRequested = true
        lease.updatedAt = Date()
        try await lease.update(on: database)
    }

    func cancelRequested(streamID: String) async throws -> Bool {
        guard let lease = try await AIStreamLease.find(streamID, on: database) else {
            return false
        }
        return lease.expiresAt > Date() && lease.cancelRequested
    }

    func finish(streamID: String, conversationID: UUID, userID: UUID) async throws {
        guard let lease = try await AIStreamLease.find(streamID, on: database) else {
            return
        }
        guard lease.conversationID == conversationID, lease.userID == userID else {
            return
        }
        try await lease.delete(on: database)
    }

    func heartbeat(streamID: String, conversationID: UUID, userID: UUID) async throws -> Bool {
        guard let lease = try await AIStreamLease.find(streamID, on: database),
              lease.conversationID == conversationID,
              lease.userID == userID,
              lease.expiresAt > Date()
        else {
            return false
        }
        let now = Date()
        lease.expiresAt = now.addingTimeInterval(leaseTTL)
        lease.updatedAt = now
        try await lease.update(on: database)
        return true
    }

    func isActive(streamID: String) async throws -> Bool {
        guard let lease = try await AIStreamLease.find(streamID, on: database) else {
            return false
        }
        return lease.expiresAt > Date()
    }

    func activeCounts(conversationID: UUID, userID: UUID) async throws -> AIStreamLeaseCounts {
        let now = Date()
        return try await database.transaction { database in
            try await self.removeExpiredLeases(
                on: database,
                userID: userID,
                conversationID: conversationID,
                now: now
            )
            return AIStreamLeaseCounts(
                userCount: try await self.activeLeaseCount(
                    on: database,
                    field: \AIStreamLease.$userID,
                    value: userID,
                    now: now
                ),
                conversationCount: try await self.activeLeaseCount(
                    on: database,
                    field: \AIStreamLease.$conversationID,
                    value: conversationID,
                    now: now
                )
            )
        }
    }

    private func lockQuotaDomains(
        on database: any Database,
        userID: UUID,
        conversationID: UUID
    ) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return
        }

        // Always acquire the same two lock classes in this order. A user lock
        // serializes cross-shard user quotas; the conversation lock does the
        // same for independent users starting streams in one conversation.
        for domain in [
            "ai-stream:user:\(userID.uuidString.lowercased())",
            "ai-stream:conversation:\(conversationID.uuidString.lowercased())"
        ] {
            try await sql.raw(
                "SELECT pg_advisory_xact_lock(hashtextextended(\(bind: domain), 0))"
            ).run()
        }
    }

    private func removeExpiredLeases(
        on database: any Database,
        userID: UUID,
        conversationID: UUID,
        now: Date
    ) async throws {
        try await AIStreamLease.query(on: database)
            .group(.or) { group in
                group.filter(\.$userID == userID)
                group.filter(\.$conversationID == conversationID)
            }
            .filter(\.$expiresAt < now)
            .delete()
    }

    private func activeLeaseCount<Value>(
        on database: any Database,
        field: KeyPath<AIStreamLease, FieldProperty<AIStreamLease, Value>>,
        value: Value,
        now: Date
    ) async throws -> Int where Value: Codable & Sendable {
        try await AIStreamLease.query(on: database)
            .filter(field == value)
            .filter(\.$expiresAt > now)
            .count()
    }
}
