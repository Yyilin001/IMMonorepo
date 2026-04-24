import Foundation
import IMClientKit

struct ContactsSnapshot: Equatable {
    let contacts: [ContactResponseBody]
    let lastRefreshAt: Date
}

struct ContactRequestsSnapshot: Equatable {
    let requests: [ContactRequestResponseBody]
    let lastRefreshAt: Date
}

@MainActor
final class ContactsController {
    private let sessionClient: SessionClient
    private let contactStateCache: ContactStateCacheHandler

    init(sessionClient: SessionClient, contactStateCache: ContactStateCacheHandler) {
        self.sessionClient = sessionClient
        self.contactStateCache = contactStateCache
    }

    func fetchContacts() async throws -> ContactsSnapshot {
        ContactsSnapshot(
            contacts: try await sessionClient.fetchContacts().sorted { $0.email < $1.email },
            lastRefreshAt: Date()
        )
    }

    func fetchContactRequests() async throws -> ContactRequestsSnapshot {
        ContactRequestsSnapshot(
            requests: try await sessionClient.fetchContactRequests(box: .all),
            lastRefreshAt: Date()
        )
    }

    func sendContactRequest(
        email: String,
        message: String?,
        remark: String?
    ) async throws -> ContactRequestResponseBody {
        try await sessionClient.sendContactRequest(
            email: email,
            message: message,
            remark: remark
        )
    }

    func acceptContactRequest(id requestID: UUID, remark: String?) async throws -> ContactResponseBody {
        try await sessionClient.acceptContactRequest(id: requestID, remark: remark)
    }

    func declineContactRequest(id requestID: UUID) async throws -> ContactRequestResponseBody {
        try await sessionClient.declineContactRequest(id: requestID)
    }

    func cancelContactRequest(id requestID: UUID) async throws -> ContactRequestResponseBody {
        try await sessionClient.cancelContactRequest(id: requestID)
    }

    func updateContact(contactUserID: UUID, remark: String?) async throws -> ContactResponseBody {
        try await sessionClient.updateContact(contactUserID: contactUserID, remark: remark)
    }

    func deleteContact(contactUserID: UUID) async throws {
        _ = try await sessionClient.deleteContact(contactUserID: contactUserID)
    }

    func loadCacheSnapshot(for ownerUserID: UUID) async throws -> ContactStateCacheSnapshot {
        try await contactStateCache.loadSnapshot(for: ownerUserID)
    }

    func saveCacheSnapshot(_ snapshot: ContactStateCacheSnapshot, for ownerUserID: UUID) async throws {
        try await contactStateCache.saveSnapshot(snapshot, for: ownerUserID)
    }

    func clearSnapshot(for ownerUserID: UUID) async throws {
        try await contactStateCache.clearSnapshot(for: ownerUserID)
    }

    func clearAllSnapshots() async throws {
        try await contactStateCache.clearAll()
    }

    func isRequestRelevant(_ request: ContactRequestResponseBody, to currentUserID: UUID) -> Bool {
        request.requester.id == currentUserID || request.addressee.id == currentUserID
    }

    func normalizeRequests(
        _ requests: [ContactRequestResponseBody],
        currentUserID: UUID
    ) -> [ContactRequestResponseBody] {
        var requestsByID: [UUID: ContactRequestResponseBody] = [:]
        for request in requests where isRequestRelevant(request, to: currentUserID) {
            requestsByID[request.id] = request
        }
        return Array(requestsByID.values)
    }

    func sortPendingNewestFirst(
        _ lhs: ContactRequestResponseBody,
        _ rhs: ContactRequestResponseBody
    ) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (lhsDate?, rhsDate?):
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    func sortResolvedNewestFirst(
        _ lhs: ContactRequestResponseBody,
        _ rhs: ContactRequestResponseBody
    ) -> Bool {
        switch (lhs.respondedAt, rhs.respondedAt) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        switch (lhs.updatedAt, rhs.updatedAt) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        return lhs.id.uuidString > rhs.id.uuidString
    }

    func normalizedRemark(_ remark: String?) -> String? {
        let normalized = remark?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(64))
    }

    func normalizedRequestMessage(_ message: String?) -> String? {
        let normalized = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(120))
    }
}
