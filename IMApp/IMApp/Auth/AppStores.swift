import Combine
import Foundation
import IMClientKit

@MainActor
final class AppSessionStore: ObservableObject {
    @Published var phase: AuthManager.Phase = .launching
    @Published var isBusy = false
    @Published var sessions: [SessionSnapshot] = []
    @Published var isLoadingSessions = false
    @Published var sessionsMessage: String?
    @Published var isUpdatingProfile = false
    @Published var profileMessage: String?
    @Published var serverStatus: AuthManager.ServerStatus = .unknown

    var currentUser: AuthUser? {
        guard case .signedIn(let user) = phase else {
            return nil
        }
        return user
    }

    func resetForSignedOut(message: String?) {
        sessions = []
        sessionsMessage = nil
        isUpdatingProfile = false
        profileMessage = nil
        serverStatus = .unknown
        phase = .signedOut(message: message)
    }
}

@MainActor
final class ContactStore: ObservableObject {
    enum EventApplyResult: Equatable {
        case applied
        case ignored
        case needsCorrection(String)
    }

    private enum Constants {
        static let resolvedContactRequestHistoryLimit = 50
    }

    @Published var contacts: [ContactResponseBody] = []
    @Published var isLoadingContacts = false
    @Published var contactsMessage: String?
    @Published var contactRequests: [ContactRequestResponseBody] = []
    @Published var unseenIncomingContactRequestCount = 0
    @Published var isLoadingContactRequests = false
    @Published var contactRequestsLoadMessage: String?
    @Published var contactRequestActionMessage: String?
    @Published var acceptingRequestIDs: Set<UUID> = []
    @Published var decliningRequestIDs: Set<UUID> = []
    @Published var cancellingRequestIDs: Set<UUID> = []
    @Published var directConversationRelationshipActionMessages: [String: String] = [:]
    @Published var sendingDirectConversationFriendRequestConversationIDs: Set<String> = []
    @Published var blockedUsers: [UserBlockResponseBody] = []
    @Published var isLoadingBlockedUsers = false

    var lastContactStateRefreshAt: Date?
    var lastSeenIncomingContactRequestAt: Date?

    private let contactStateStore = ContactStateStore()

    func incomingPendingContactRequests(
        currentUserID: UUID?,
        sort: (ContactRequestResponseBody, ContactRequestResponseBody) -> Bool
    ) -> [ContactRequestResponseBody] {
        guard let currentUserID else {
            return []
        }

        return contactRequests
            .filter { $0.status == .pending && $0.addressee.id == currentUserID }
            .sorted(by: sort)
    }

    func outgoingPendingContactRequests(
        currentUserID: UUID?,
        sort: (ContactRequestResponseBody, ContactRequestResponseBody) -> Bool
    ) -> [ContactRequestResponseBody] {
        guard let currentUserID else {
            return []
        }

        return contactRequests
            .filter { $0.status == .pending && $0.requester.id == currentUserID }
            .sorted(by: sort)
    }

    func recentResolvedContactRequests(
        sort: (ContactRequestResponseBody, ContactRequestResponseBody) -> Bool
    ) -> [ContactRequestResponseBody] {
        Array(
            contactRequests
                .filter { $0.status != .pending }
                .sorted(by: sort)
                .prefix(Constants.resolvedContactRequestHistoryLimit)
        )
    }

    func upsertContact(_ contact: ContactResponseBody) {
        contactStateStore.upsertContact(contact, contacts: &contacts)
    }

    func removeContact(userID: UUID) {
        contactStateStore.removeContact(userID: userID, contacts: &contacts)
    }

    func replaceRequests(
        _ requests: [ContactRequestResponseBody],
        currentUserID: UUID,
        normalize: ([ContactRequestResponseBody], UUID) -> [ContactRequestResponseBody]
    ) {
        contactStateStore.replaceRequests(
            requests,
            currentUserID: currentUserID,
            contactRequests: &contactRequests,
            normalize: normalize
        )
    }

    func upsertRequest(
        _ request: ContactRequestResponseBody,
        currentUserID: UUID,
        isRelevant: (ContactRequestResponseBody, UUID) -> Bool,
        normalize: ([ContactRequestResponseBody], UUID) -> [ContactRequestResponseBody]
    ) {
        contactStateStore.upsertRequest(
            request,
            currentUserID: currentUserID,
            contactRequests: &contactRequests,
            isRelevant: isRelevant,
            normalize: normalize
        )
    }

    func updateRequestStatus(
        id requestID: UUID,
        status: ContactRequestStatus,
        respondedAt: Date,
        currentUserID: UUID,
        normalize: ([ContactRequestResponseBody], UUID) -> [ContactRequestResponseBody]
    ) {
        contactStateStore.updateRequestStatus(
            requestID: requestID,
            status: status,
            respondedAt: respondedAt,
            currentUserID: currentUserID,
            contactRequests: &contactRequests,
            normalize: normalize
        )
    }

    func apply(
        event payload: IMTCPContactEventPayload,
        currentUserID: UUID?,
        isRelevant: (ContactRequestResponseBody, UUID) -> Bool,
        normalize: ([ContactRequestResponseBody], UUID) -> [ContactRequestResponseBody],
        sortPendingNewestFirst: (ContactRequestResponseBody, ContactRequestResponseBody) -> Bool
    ) -> EventApplyResult {
        guard let currentUserID else {
            return .ignored
        }

        switch payload.eventType {
        case .friendRequestCreated:
            guard let request = payload.request,
                  isRelevant(request, currentUserID)
            else {
                return .needsCorrection("friend_request_created payload is incomplete")
            }

            upsertRequest(
                request,
                currentUserID: currentUserID,
                isRelevant: isRelevant,
                normalize: normalize
            )
            recomputeIncomingUnread(
                currentUserID: currentUserID,
                sortPendingNewestFirst: sortPendingNewestFirst
            )
            return .applied

        case .friendRequestAccepted:
            guard let request = payload.request,
                  isRelevant(request, currentUserID),
                  let contact = payload.contact
            else {
                return .needsCorrection("friend_request_accepted payload is incomplete")
            }

            upsertRequest(
                request,
                currentUserID: currentUserID,
                isRelevant: isRelevant,
                normalize: normalize
            )
            upsertContact(contact)
            recomputeIncomingUnread(
                currentUserID: currentUserID,
                sortPendingNewestFirst: sortPendingNewestFirst
            )
            return .applied

        case .friendRequestDeclined, .friendRequestCancelled:
            guard let request = payload.request,
                  isRelevant(request, currentUserID)
            else {
                return .needsCorrection("\(payload.eventType.rawValue) payload is incomplete")
            }

            upsertRequest(
                request,
                currentUserID: currentUserID,
                isRelevant: isRelevant,
                normalize: normalize
            )
            recomputeIncomingUnread(
                currentUserID: currentUserID,
                sortPendingNewestFirst: sortPendingNewestFirst
            )
            return .applied

        case .contactRemoved:
            guard let contactUserID = payload.contactUserID else {
                return .needsCorrection("contact_removed payload is incomplete")
            }

            removeContact(userID: contactUserID)
            return .applied
        }
    }

    func recomputeIncomingUnread(
        currentUserID: UUID?,
        sortPendingNewestFirst: (ContactRequestResponseBody, ContactRequestResponseBody) -> Bool
    ) {
        guard let currentUserID else {
            unseenIncomingContactRequestCount = 0
            return
        }

        unseenIncomingContactRequestCount = contactStateStore.unseenIncomingRequestCount(
            requests: contactRequests,
            currentUserID: currentUserID,
            lastSeenIncomingContactRequestAt: lastSeenIncomingContactRequestAt,
            sortPendingNewestFirst: sortPendingNewestFirst
        )
    }

    func resetForSignedOut() {
        contacts = []
        contactsMessage = nil
        isLoadingContacts = false
        contactRequests = []
        unseenIncomingContactRequestCount = 0
        contactRequestsLoadMessage = nil
        contactRequestActionMessage = nil
        directConversationRelationshipActionMessages = [:]
        isLoadingContactRequests = false
        acceptingRequestIDs = []
        decliningRequestIDs = []
        cancellingRequestIDs = []
        sendingDirectConversationFriendRequestConversationIDs = []
        lastContactStateRefreshAt = nil
        lastSeenIncomingContactRequestAt = nil
    }
}

@MainActor
final class AppRootStore: ObservableObject {
    let sessionStore: AppSessionStore
    let contactStore: ContactStore
    let conversationStore: IMConversationStore

    init(
        sessionStore: AppSessionStore,
        contactStore: ContactStore,
        conversationStore: IMConversationStore
    ) {
        self.sessionStore = sessionStore
        self.contactStore = contactStore
        self.conversationStore = conversationStore
    }
}
