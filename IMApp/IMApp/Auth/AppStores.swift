import Foundation
import IMClientKit
import Observation

@MainActor
@Observable
final class AppSessionStore {
    var authRouteState: AuthRouteState = .launching {
        didSet {
            if case .signedOut(let notice) = authRouteState {
                authNotice = notice
            }
        }
    }
    var authOperationState: AuthOperationState = .idle
    var authNotice: AuthNotice?
    var isBusy = false
    var sessions: [SessionSnapshot] = []
    var isLoadingSessions = false
    var sessionsMessage: String?
    var isUpdatingProfile = false
    var profileMessage: String?
    var serverStatus: AuthManager.ServerStatus = .unknown {
        didSet {
            syncAvailabilityWithServerStatus()
        }
    }

    var currentUser: AuthUser? {
        guard case .signedIn(let user, _) = authRouteState else {
            return nil
        }
        return user
    }

    func setSignedOut(notice: AuthNotice?) {
        authNotice = notice
        authRouteState = .signedOut(notice)
    }

    func setSignedIn(
        _ user: AuthUser,
        availability: AuthAvailability = .online
    ) {
        authNotice = nil
        authRouteState = .signedIn(user, availability: availability)
    }

    func setOperation(_ operation: AuthOperationState) {
        authOperationState = operation
        isBusy = operation.isBusy
        isLoadingSessions = operation == .loadingSessions
        isUpdatingProfile = operation == .updatingProfile
    }

    func resetForSignedOut(message: String?) {
        sessions = []
        sessionsMessage = nil
        isUpdatingProfile = false
        profileMessage = nil
        serverStatus = .unknown
        setOperation(.idle)
        setSignedOut(notice: AuthClientErrorMapper.notice(forMessage: message))
    }

    private func syncAvailabilityWithServerStatus() {
        guard case .signedIn(let user, _) = authRouteState else {
            return
        }
        authRouteState = .signedIn(user, availability: availabilityFromServerStatus())
    }

    private func availabilityFromServerStatus() -> AuthAvailability {
        switch serverStatus {
        case .offline(let message):
            return .offline(message: message)
        case .unknown, .online:
            return .online
        }
    }
}

@MainActor
@Observable
final class ContactStore {
    enum EventApplyResult: Equatable {
        case applied
        case ignored
        case needsCorrection(String)
    }

    private enum Constants {
        static let resolvedContactRequestHistoryLimit = 50
    }

    var contacts: [ContactResponseBody] = []
    var isLoadingContacts = false
    var contactsMessage: String?
    var contactRequests: [ContactRequestResponseBody] = []
    var unseenIncomingContactRequestCount = 0
    var isLoadingContactRequests = false
    var contactRequestsLoadMessage: String?
    var contactRequestActionMessage: String?
    var acceptingRequestIDs: Set<UUID> = []
    var decliningRequestIDs: Set<UUID> = []
    var cancellingRequestIDs: Set<UUID> = []
    var directConversationRelationshipActionMessages: [String: String] = [:]
    var sendingDirectConversationFriendRequestConversationIDs: Set<String> = []
    var blockedUsers: [UserBlockResponseBody] = []
    var isLoadingBlockedUsers = false

    var lastContactStateRefreshAt: Date?
    var lastSeenIncomingContactRequestAt: Date?

    @ObservationIgnored
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
@Observable
final class AppRootStore {
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
