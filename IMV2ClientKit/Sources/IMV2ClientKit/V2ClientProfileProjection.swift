import Foundation
import IMV2Core

/// A profile invalidation is durable delivery metadata, not profile content.
/// The repository uses it to coalesce authorized batch reads after the sync
/// transaction commits.
struct V2ClientProfileInvalidation: Equatable, Sendable {
    let userID: UserID
    let minimumRevision: V2ProfileRevision
    let state: V2ProfileState

    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let userID: String
            let minimumRevision: UInt64
            let profileState: String?
            enum CodingKeys: String, CodingKey {
                case userID = "user_id"
                case minimumRevision = "minimum_profile_revision"
                case profileState = "profile_state"
            }
        }
        guard record.projectionKind == "profile_invalidation",
              let wire = try? JSONDecoder().decode(Wire.self, from: record.payload),
              let revision = V2ProfileRevision(rawValue: wire.minimumRevision),
              let state = V2ProfileState(rawValue: wire.profileState ?? V2ProfileState.active.rawValue)
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            userID = try .init(wire.userID)
            minimumRevision = revision
            self.state = state
        } catch {
            throw V2ClientProjectionError.invalidMessagePayload
        }
    }
}
