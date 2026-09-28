import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// A current control-authority observation for one room creation. This is not
/// a durable send permission and is never cached as account authorization.
public struct V2DirectRoomIdentitySnapshot: Sendable {
    public let actorUserID: UserID
    public let targetUserID: UserID
    public let actorIsActive: Bool
    public let targetIsActive: Bool
    public let targetProfile: V2PublicIdentity?
    public let targetRevision: UInt64?
    public let targetUpdatedAt: Date?
    public init(actorUserID: UserID, targetUserID: UserID, actorIsActive: Bool, targetIsActive: Bool,
                targetProfile: V2PublicIdentity?, targetRevision: UInt64?, targetUpdatedAt: Date?) {
        self.actorUserID = actorUserID; self.targetUserID = targetUserID
        self.actorIsActive = actorIsActive; self.targetIsActive = targetIsActive
        self.targetProfile = targetProfile; self.targetRevision = targetRevision; self.targetUpdatedAt = targetUpdatedAt
    }
}

public protocol V2DirectRoomIdentityReading: Sendable {
    func read(actorUserID: UserID, targetUserID: UserID) async throws -> V2DirectRoomIdentitySnapshot
}

/// One bounded plain query. No control transaction or row lock survives the
/// read, including when the owner performs it under its operation/pair locks.
public struct PostgresV2DirectRoomIdentityReader: V2DirectRoomIdentityReading {
    private let database: any Database
    public init(database: any Database) { self.database = database }
    public func read(actorUserID: UserID, targetUserID: UserID) async throws -> V2DirectRoomIdentitySnapshot {
        guard let actor = actorUserID.uuidValue, let target = targetUserID.uuidValue,
              actor != target, let sql = database as? any SQLDatabase else { throw V2DirectMessagingStoreError.corruptPersistenceState }
        let rows = try await sql.raw("""
            SELECT p.user_id, p.public_handle, p.display_name, p.account_kind, p.revision, p.updated_at,
                   (p.state='active' AND NOT EXISTS
                    (SELECT 1 FROM im_v2.account_disables d WHERE d.user_id=p.user_id)) AS is_active
            FROM im_v2.public_user_profiles p WHERE p.user_id = ANY(\(bind: [actor,target])::uuid[])
            """).all(decoding: DirectIdentityRow.self)
        let actorRow = rows.first { $0.userID == actor }, targetRow = rows.first { $0.userID == target }
        let profile: V2PublicIdentity?
        if let row = targetRow {
            guard let kind = V2AccountKind(rawValue: row.accountKind), row.revision >= 0,
                  v2PostgresTimestampCanEncode(row.updatedAt) else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            profile = try .init(userID: targetUserID, handle: .init(row.publicHandle), displayName: row.displayName, accountKind: kind)
        } else { profile = nil }
        return .init(actorUserID: actorUserID, targetUserID: targetUserID,
            actorIsActive: actorRow?.isActive == true, targetIsActive: targetRow?.isActive == true,
            targetProfile: profile, targetRevision: targetRow.map { UInt64($0.revision) }, targetUpdatedAt: targetRow?.updatedAt)
    }
}
private struct DirectIdentityRow: Decodable {
    let userID: UUID
    let publicHandle: String, displayName: String, accountKind: String
    let revision: Int64
    let updatedAt: Date
    let isActive: Bool
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", publicHandle = "public_handle", displayName = "display_name", accountKind = "account_kind"
        case revision, updatedAt = "updated_at", isActive = "is_active"
    }
}
