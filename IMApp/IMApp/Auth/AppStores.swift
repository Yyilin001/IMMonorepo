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
        static let contactStateRefreshTTL: TimeInterval = 60
    }

    var contacts: [ContactResponseBody] = []
    var isLoadingContacts = false
    var contactRequests: [ContactRequestResponseBody] = []
    var unseenIncomingContactRequestCount = 0
    var isLoadingContactRequests = false
    var acceptingRequestIDs: Set<UUID> = []
    var decliningRequestIDs: Set<UUID> = []
    var cancellingRequestIDs: Set<UUID> = []
    var directRelationshipNotices: [String: DirectRelationshipNotice] = [:]
    var sendingDirectConversationFriendRequestConversationIDs: Set<String> = []
    var blockedUsers: [UserBlockResponseBody] = []
    var isLoadingBlockedUsers = false
    var notices: [ContactNotice] = []
    var knownUserDisplayCache = KnownContactUserDisplayCache()

    var lastContactStateRefreshAt: Date?
    var lastSeenIncomingContactRequestAt: Date?

    @ObservationIgnored
    private let contactStateStore = ContactStateStore()

    func notice(for scope: ContactNoticeScope) -> ContactNotice? {
        notices
            .filter { $0.scope == scope }
            .max { $0.createdAt < $1.createdAt }
    }

    func setNotice(
        _ message: String,
        scope: ContactNoticeScope,
        tone: ContactNoticeTone,
        createdAt: Date = Date()
    ) {
        clearNotice(scope: scope)
        notices.append(ContactNotice(
            scope: scope,
            tone: tone,
            message: message,
            createdAt: createdAt
        ))
    }

    func clearNotice(scope: ContactNoticeScope) {
        notices.removeAll { $0.scope == scope }
    }

    func setDirectRelationshipNotice(
        _ message: String,
        conversationID: String,
        tone: ContactNoticeTone,
        createdAt: Date = Date()
    ) {
        directRelationshipNotices[conversationID] = DirectRelationshipNotice(
            conversationID: conversationID,
            tone: tone,
            message: message,
            createdAt: createdAt
        )
    }

    func clearDirectRelationshipNotice(conversationID: String) {
        directRelationshipNotices.removeValue(forKey: conversationID)
    }

    func shouldRefreshContactState(now: Date = Date(), ttl: TimeInterval = Constants.contactStateRefreshTTL) -> Bool {
        guard let lastContactStateRefreshAt else {
            return true
        }
        return now.timeIntervalSince(lastContactStateRefreshAt) >= ttl
    }

    func cacheKnownUserDisplay(_ display: KnownContactUserDisplay) {
        knownUserDisplayCache.cache(display)
    }

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

    func filteredContacts(query: String) -> [ContactResponseBody] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return contacts
        }

        return contacts.filter { contact in
            [
                contact.email,
                contact.remark,
                contact.profileDisplayName,
                contact.displayName
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
        }
    }

    func contactRequestPresentations(
        currentUserID: UUID?,
        now: Date = Date()
    ) -> [ContactRequestPresentation] {
        contactRequests
            .map { request in
                ContactRequestPresentation(
                    request: request,
                    currentUserID: currentUserID,
                    state: ContactRequestPresentationState.resolve(
                        request: request,
                        currentUserID: currentUserID,
                        now: now
                    )
                )
            }
            .sorted(by: sortContactRequestPresentationsNewestFirst)
    }

    func pendingIncomingCount(currentUserID: UUID?, now: Date = Date()) -> Int {
        contactRequestPresentations(currentUserID: currentUserID, now: now)
            .filter { $0.state == .incomingPending }
            .count
    }

    func pendingOutgoingCount(currentUserID: UUID?, now: Date = Date()) -> Int {
        contactRequestPresentations(currentUserID: currentUserID, now: now)
            .filter { $0.state == .outgoingPending }
            .count
    }

    func totalPendingCount(currentUserID: UUID?, now: Date = Date()) -> Int {
        pendingIncomingCount(currentUserID: currentUserID, now: now)
            + pendingOutgoingCount(currentUserID: currentUserID, now: now)
    }

    func expiredRequestCount(currentUserID: UUID?, now: Date = Date()) -> Int {
        contactRequestPresentations(currentUserID: currentUserID, now: now)
            .filter { $0.state == .expired }
            .count
    }

    func knownUserDisplay(for userID: UUID) -> KnownContactUserDisplay? {
        if let display = knownUserDisplayCache.display(for: userID) {
            return display
        }

        if let contact = contacts.first(where: { $0.id == userID }) {
            return KnownContactUserDisplay(
                id: contact.id,
                displayName: contact.displayName,
                email: contact.email,
                avatarPreset: contact.avatarPreset
            )
        }

        for request in contactRequests {
            if request.requester.id == userID {
                return KnownContactUserDisplay(
                    id: request.requester.id,
                    displayName: request.requester.preferredDisplayName,
                    email: request.requester.email,
                    avatarPreset: request.requester.avatarPreset
                )
            }

            if request.addressee.id == userID {
                return KnownContactUserDisplay(
                    id: request.addressee.id,
                    displayName: request.addressee.preferredDisplayName,
                    email: request.addressee.email,
                    avatarPreset: request.addressee.avatarPreset
                )
            }
        }

        return nil
    }

    private func sortContactRequestPresentationsNewestFirst(
        _ lhs: ContactRequestPresentation,
        _ rhs: ContactRequestPresentation
    ) -> Bool {
        let leftDate = lhs.request.updatedAt ?? lhs.request.createdAt ?? .distantPast
        let rightDate = rhs.request.updatedAt ?? rhs.request.createdAt ?? .distantPast
        if leftDate == rightDate {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return leftDate > rightDate
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
        respondedAt: Date
    ) {
        contactStateStore.updateRequestStatus(
            requestID: requestID,
            status: status,
            respondedAt: respondedAt,
            contactRequests: &contactRequests
        )
    }

    func apply(
        domainEvent payload: IMTCPChatDomainEventPayload,
        currentUserID: UUID?,
        isRelevant: (ContactRequestResponseBody, UUID) -> Bool,
        normalize: ([ContactRequestResponseBody], UUID) -> [ContactRequestResponseBody],
        sortPendingNewestFirst: (ContactRequestResponseBody, ContactRequestResponseBody) -> Bool
    ) -> EventApplyResult {
        guard let currentUserID else {
            return .ignored
        }
        guard case .contactChanged(let request, let contact, let contactUserID) = payload.body else {
            return .ignored
        }

        switch payload.eventType {
        case .contactRequestCreated:
            guard let request,
                  isRelevant(request, currentUserID)
            else {
                return .needsCorrection("contact_request_created payload is incomplete")
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

        case .contactRequestAccepted:
            guard let request,
                  isRelevant(request, currentUserID),
                  let contact
            else {
                return .needsCorrection("contact_request_accepted payload is incomplete")
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

        case .contactRequestUpdated:
            if contact == nil, let contactUserID {
                removeContact(userID: contactUserID)
                return .applied
            }

            guard let request,
                  isRelevant(request, currentUserID)
            else {
                return .needsCorrection("contact_request_updated payload is incomplete")
            }

            upsertRequest(
                request,
                currentUserID: currentUserID,
                isRelevant: isRelevant,
                normalize: normalize
            )
            if let contact {
                upsertContact(contact)
            }
            recomputeIncomingUnread(
                currentUserID: currentUserID,
                sortPendingNewestFirst: sortPendingNewestFirst
            )
            return .applied

        default:
            return .ignored
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
        notices = []
        isLoadingContacts = false
        contactRequests = []
        unseenIncomingContactRequestCount = 0
        directRelationshipNotices = [:]
        isLoadingContactRequests = false
        acceptingRequestIDs = []
        decliningRequestIDs = []
        cancellingRequestIDs = []
        sendingDirectConversationFriendRequestConversationIDs = []
        blockedUsers = []
        isLoadingBlockedUsers = false
        knownUserDisplayCache.removeAll()
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
