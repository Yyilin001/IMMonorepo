import Foundation
import IMClientKit

struct ContactStateStore {
    func upsertContact(
        _ contact: ContactResponseBody,
        contacts: inout [ContactResponseBody]
    ) {
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }
        contacts.sort { $0.email < $1.email }
    }

    func removeContact(
        userID: UUID,
        contacts: inout [ContactResponseBody]
    ) {
        contacts.removeAll { $0.id == userID }
    }

    func replaceRequests(
        _ requests: [ContactRequestResponseBody],
        currentUserID: UUID,
        contactRequests: inout [ContactRequestResponseBody],
        normalize: ([ContactRequestResponseBody], UUID) -> [ContactRequestResponseBody]
    ) {
        contactRequests = normalize(requests, currentUserID)
    }

    func upsertRequest(
        _ request: ContactRequestResponseBody,
        currentUserID: UUID,
        contactRequests: inout [ContactRequestResponseBody],
        isRelevant: (ContactRequestResponseBody, UUID) -> Bool,
        normalize: ([ContactRequestResponseBody], UUID) -> [ContactRequestResponseBody]
    ) {
        guard isRelevant(request, currentUserID) else {
            return
        }

        contactRequests.removeAll { $0.id == request.id }
        contactRequests.append(request)
        contactRequests = normalize(contactRequests, currentUserID)
    }

    func updateRequestStatus(
        requestID: UUID,
        status: ContactRequestStatus,
        respondedAt: Date,
        contactRequests: inout [ContactRequestResponseBody]
    ) {
        guard let index = contactRequests.firstIndex(where: { $0.id == requestID }) else {
            return
        }

        let current = contactRequests[index]
        contactRequests[index] = ContactRequestResponseBody(
            id: current.id,
            requester: current.requester,
            addressee: current.addressee,
            status: status,
            message: current.message,
            requesterRemark: current.requesterRemark,
            addresseeRemark: current.addresseeRemark,
            createdAt: current.createdAt,
            updatedAt: respondedAt,
            respondedAt: respondedAt
        )
    }

    func unseenIncomingRequestCount(
        requests: [ContactRequestResponseBody],
        currentUserID: UUID,
        lastSeenIncomingContactRequestAt: Date?,
        sortPendingNewestFirst: (ContactRequestResponseBody, ContactRequestResponseBody) -> Bool
    ) -> Int {
        let pendingIncoming = requests
            .filter { $0.status == .pending && $0.addressee.id == currentUserID }
            .sorted(by: sortPendingNewestFirst)

        guard !pendingIncoming.isEmpty else {
            return 0
        }

        if let lastSeenIncomingContactRequestAt {
            return pendingIncoming.reduce(into: 0) { count, request in
                guard let createdAt = request.createdAt, createdAt > lastSeenIncomingContactRequestAt else {
                    return
                }
                count += 1
            }
        }

        return pendingIncoming.reduce(into: 0) { count, request in
            guard request.createdAt != nil else {
                return
            }
            count += 1
        }
    }
}
