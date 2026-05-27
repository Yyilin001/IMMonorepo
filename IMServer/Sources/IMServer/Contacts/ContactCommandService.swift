import Fluent
import Vapor

struct ContactCommandService {
    private let friendRequestService = FriendRequestService()

    func updateContact(
        ownerUserID: UUID,
        contactUserID: UUID,
        remark: String?,
        on db: any Database
    ) async throws -> ContactResponse {
        try await db.transaction { database in
            guard let contact = try await UserContact.query(on: database)
                .filter(\.$owner.$id == ownerUserID)
                .filter(\.$contact.$id == contactUserID)
                .with(\.$contact)
                .first()
            else {
                throw Abort(.notFound, reason: "联系人不存在。")
            }

            contact.remark = normalizedContactRemark(remark)
            try await contact.update(on: database)
            let response = try ContactResponse(contact: contact)
            try await ContactOutboxService(db: database).enqueue(
                type: .contactRequestUpdated,
                ownerUserIDs: [ownerUserID],
                aggregateID: contactUserID,
                actorUserID: ownerUserID,
                payloadForOwner: { _ in
                    .contactUpdated(contact: response, contactUserID: contactUserID)
                },
                on: database
            )
            return response
        }
    }

    func deleteContact(
        ownerUserID: UUID,
        contactUserID: UUID,
        on db: any Database
    ) async throws {
        try await db.transaction { database in
            guard let contact = try await UserContact.query(on: database)
                .filter(\.$owner.$id == ownerUserID)
                .filter(\.$contact.$id == contactUserID)
                .first()
            else {
                throw Abort(.notFound, reason: "联系人不存在。")
            }

            try await contact.delete(on: database)
            if let reverseContact = try await UserContact.query(on: database)
                .filter(\.$owner.$id == contactUserID)
                .filter(\.$contact.$id == ownerUserID)
                .first()
            {
                try await reverseContact.delete(on: database)
            }

            let affectedDirectConversationIDs = try await IMDirectConversationStateService().updateExistingDirectConversations(
                between: ownerUserID,
                and: contactUserID,
                to: .frozenAfterUnfriend,
                on: database
            )
            try await ContactOutboxService(db: database).enqueue(
                type: .contactRemoved,
                ownerUserIDs: [ownerUserID, contactUserID],
                aggregateID: contactUserID,
                actorUserID: ownerUserID,
                payloadForOwner: { ownerID in
                    .contactRemoved(
                        contactUserID: ownerID == ownerUserID ? contactUserID : ownerUserID,
                        affectedConversationIDs: affectedDirectConversationIDs
                    )
                },
                on: database
            )
        }
    }

    func sendContactRequest(
        from user: User,
        body: ContactRequestCreateRequest,
        on db: any Database
    ) async throws -> FriendRequestResponse {
        try await db.transaction { database in
            let requesterUserID = try user.requireID()
            let normalizedEmail = User.normalize(body.email)
            if let addressee = try await User.query(on: database)
                .filter(\.$email == normalizedEmail)
                .first(),
               try await hasBlockBetween(requesterUserID, and: addressee.requireID(), on: database)
            {
                throw Abort(.forbidden, reason: "当前无法发送好友申请。")
            }
            let response = try await friendRequestService.sendRequest(
                from: user,
                email: body.email,
                message: body.message,
                remark: body.remark,
                on: database
            )
            try await ContactOutboxService(db: database).enqueue(
                type: .contactRequestCreated,
                ownerUserIDs: [response.requester.id, response.addressee.id],
                aggregateID: response.id,
                actorUserID: response.requester.id,
                payloadForOwner: { _ in .requestCreated(request: response) },
                on: database
            )
            return response
        }
    }

    func acceptContactRequest(
        requestID: UUID,
        addresseeUserID: UUID,
        remark: String?,
        on db: any Database
    ) async throws -> ContactResponse {
        try await db.transaction { database in
            let result = try await friendRequestService.acceptRequest(
                id: requestID,
                addresseeUserID: addresseeUserID,
                remark: remark,
                on: database
            )
            try await ContactOutboxService(db: database).enqueue(
                type: .contactRequestAccepted,
                ownerUserIDs: [result.request.requester.id, result.request.addressee.id],
                aggregateID: result.request.id,
                actorUserID: result.request.addressee.id,
                payloadForOwner: { ownerID in
                    .requestAccepted(
                        request: result.request,
                        contact: ownerID == result.request.requester.id ? result.requesterContact : result.addresseeContact,
                        contactUserID: ownerID == result.request.requester.id
                            ? result.request.addressee.id
                            : result.request.requester.id,
                        affectedConversationIDs: result.affectedDirectConversationIDs
                    )
                },
                on: database
            )
            return result.addresseeContact
        }
    }

    func declineContactRequest(
        requestID: UUID,
        addresseeUserID: UUID,
        on db: any Database
    ) async throws -> FriendRequestResponse {
        try await db.transaction { database in
            let response = try await friendRequestService.declineRequest(
                id: requestID,
                addresseeUserID: addresseeUserID,
                on: database
            )
            try await ContactOutboxService(db: database).enqueue(
                type: .contactRequestUpdated,
                ownerUserIDs: [response.requester.id, response.addressee.id],
                aggregateID: response.id,
                actorUserID: response.addressee.id,
                payloadForOwner: { _ in .requestUpdated(request: response) },
                on: database
            )
            return response
        }
    }

    func cancelContactRequest(
        requestID: UUID,
        requesterUserID: UUID,
        on db: any Database
    ) async throws -> FriendRequestResponse {
        try await db.transaction { database in
            let response = try await friendRequestService.cancelRequest(
                id: requestID,
                requesterUserID: requesterUserID,
                on: database
            )
            try await ContactOutboxService(db: database).enqueue(
                type: .contactRequestUpdated,
                ownerUserIDs: [response.requester.id, response.addressee.id],
                aggregateID: response.id,
                actorUserID: response.requester.id,
                payloadForOwner: { _ in .requestUpdated(request: response) },
                on: database
            )
            return response
        }
    }

    private func normalizedContactRemark(_ remark: String?) -> String? {
        let normalized = remark?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(64))
    }

    private func hasBlockBetween(_ lhs: UUID, and rhs: UUID, on db: any Database) async throws -> Bool {
        let lhsBlocked = try await UserBlock.find(
            UserBlock.recordID(ownerUserID: lhs, blockedUserID: rhs),
            on: db
        ) != nil
        let rhsBlocked = try await UserBlock.find(
            UserBlock.recordID(ownerUserID: rhs, blockedUserID: lhs),
            on: db
        ) != nil
        return lhsBlocked || rhsBlocked
    }
}
