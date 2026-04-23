import Fluent

struct BackfillReciprocalUserContacts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let contacts = try await UserContact.query(on: database).all()

        for contact in contacts {
            let ownerUserID = contact.$owner.id
            let contactUserID = contact.$contact.id

            guard ownerUserID != contactUserID else {
                continue
            }

            let hasReverse = try await UserContact.query(on: database)
                .filter(\.$owner.$id == contactUserID)
                .filter(\.$contact.$id == ownerUserID)
                .first() != nil

            guard !hasReverse else {
                continue
            }

            let reverseContact = UserContact(
                ownerUserID: contactUserID,
                contactUserID: ownerUserID,
                remark: nil
            )
            try await reverseContact.create(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        // Historical contact data is intentionally left intact.
    }
}
