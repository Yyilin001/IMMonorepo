import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct V2GroupInvitationIdentity: Equatable, Sendable {
    public let profile: V2PublicIdentity
    public let isActive: Bool

    public init(profile: V2PublicIdentity, isActive: Bool) {
        self.profile = profile
        self.isActive = isActive
    }
}

/// Bounded control reads performed outside owner transactions. Missing or
/// inactive identities cannot authorize a new room operation. Existing request
/// records still retain their identity when a profile is suspended/deleted.
public protocol V2GroupInvitationIdentityReading: Sendable {
    func read(userIDs: Set<UserID>) async throws -> [UserID: V2GroupInvitationIdentity]
}

public struct PostgresV2GroupInvitationIdentityReader: V2GroupInvitationIdentityReading {
    private let database: any Database
    public init(database: any Database) { self.database = database }

    public func read(userIDs: Set<UserID>) async throws -> [UserID: V2GroupInvitationIdentity] {
        guard userIDs.count <= 100 else { throw V2GroupInvitationServiceError.invalidRequest }
        if userIDs.isEmpty { return [:] }
        let ids = try userIDs.map { id -> UUID in
            guard let uuid = id.uuidValue else { throw V2GroupInvitationServiceError.invalidRequest }
            return uuid
        }
        guard let sql = database as? any SQLDatabase else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        let rows = try await sql.raw("""
            SELECT p.user_id, p.public_handle, p.display_name, p.account_kind,
                   (p.state = 'active' AND NOT EXISTS (
                       SELECT 1 FROM im_v2.account_disables d WHERE d.user_id = p.user_id
                   )) AS is_active
            FROM im_v2.public_user_profiles p WHERE p.user_id = ANY(\(bind: ids)::uuid[])
            """).all(decoding: InvitationIdentityRow.self)
        return try Dictionary(uniqueKeysWithValues: rows.map { row in
            guard let kind = V2AccountKind(rawValue: row.accountKind) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            let id = UserID(uuid: row.userID)
            return (id, .init(profile: try .init(userID: id, handle: .init(row.publicHandle), displayName: row.displayName, accountKind: kind), isActive: row.isActive))
        })
    }
}

private struct InvitationIdentityRow: Decodable {
    let userID: UUID
    let publicHandle: String, displayName: String, accountKind: String
    let isActive: Bool
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", publicHandle = "public_handle", displayName = "display_name"
        case accountKind = "account_kind", isActive = "is_active"
    }
}
