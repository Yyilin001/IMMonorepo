import Foundation
import IMClientKit

private enum ContactRuntimeTiming {
    static let correctionDebounceNanoseconds: UInt64 = 400_000_000
    static let cachePersistDebounceNanoseconds: UInt64 = 300_000_000
}

@MainActor
struct ContactRuntimeContext {
    let sessionFacade: SessionFacade
    let sessionClient: SessionClient
    let contactStore: ContactStore
    let currentUserProvider: () -> AuthUser?
    let markServerOnline: () -> Void
    let markServerUnavailableIfNeeded: (Error) async -> Void
    let shouldPreserveSession: (Error) async -> Bool
    let clearSession: (String?) async -> Void
    let handleIMDataRequestError: (Error) async -> Void
}

@MainActor
final class ContactRuntimeController {
    private let context: ContactRuntimeContext
    private var correctionTask: Task<Void, Never>?
    private var cachePersistTask: Task<Void, Never>?

    init(context: ContactRuntimeContext) {
        self.context = context
    }

    func syncAfterConnection() async {
        guard context.currentUserProvider() != nil else {
            return
        }

        await reloadContacts()
        await reloadContactRequests()
        await loadBlockedUsers()
    }

    func reloadContacts() async {
        guard let user = context.currentUserProvider() else {
            context.contactStore.contacts = []
            return
        }

        context.contactStore.isLoadingContacts = true
        defer { context.contactStore.isLoadingContacts = false }

        do {
            let snapshot = try await context.sessionFacade.fetchContacts()
            guard context.currentUserProvider()?.id == user.id else {
                return
            }

            context.markServerOnline()
            context.contactStore.contacts = snapshot.contacts
            context.contactStore.contactsMessage = nil
            context.contactStore.lastContactStateRefreshAt = snapshot.lastRefreshAt
            scheduleCachePersist()
        } catch {
            await handleContactRequestError(error)
        }
    }

    func reloadContactRequests() async {
        guard let user = context.currentUserProvider() else {
            context.contactStore.contactRequests = []
            context.contactStore.unseenIncomingContactRequestCount = 0
            return
        }

        context.contactStore.isLoadingContactRequests = true
        defer { context.contactStore.isLoadingContactRequests = false }

        do {
            let snapshot = try await context.sessionFacade.fetchContactRequests()
            guard context.currentUserProvider()?.id == user.id else {
                return
            }

            context.markServerOnline()
            replaceContactRequests(snapshot.requests, currentUserID: user.id)
            context.contactStore.contactRequestsLoadMessage = nil
            context.contactStore.lastContactStateRefreshAt = snapshot.lastRefreshAt
            scheduleCachePersist()
        } catch {
            await handleContactRequestsLoadError(error)
        }
    }

    func sendContactRequest(email: String, message: String? = nil, remark: String? = nil) async -> Bool {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMessage = context.sessionFacade.normalizedRequestMessage(message)
        let normalizedRemark = context.sessionFacade.normalizedRemark(remark)
        guard !normalizedEmail.isEmpty else {
            context.contactStore.contactRequestActionMessage = "好友邮箱不能为空。"
            return false
        }

        context.contactStore.contactRequestActionMessage = nil
        do {
            let request = try await context.sessionFacade.sendContactRequest(
                email: normalizedEmail,
                message: normalizedMessage,
                remark: normalizedRemark
            )
            context.markServerOnline()
            upsertContactRequest(request)
            context.contactStore.contactRequestActionMessage = "好友申请已发送。"
            scheduleCachePersist()
            return true
        } catch {
            await handleContactRequestsActionError(error)
            return false
        }
    }

    func acceptContactRequest(id requestID: UUID, remark: String? = nil) async -> Bool {
        guard !context.contactStore.acceptingRequestIDs.contains(requestID) else {
            return false
        }

        context.contactStore.acceptingRequestIDs.insert(requestID)
        context.contactStore.contactRequestActionMessage = nil
        defer { context.contactStore.acceptingRequestIDs.remove(requestID) }

        do {
            let contact = try await context.sessionFacade.acceptContactRequest(
                id: requestID,
                remark: context.sessionFacade.normalizedRemark(remark)
            )
            context.markServerOnline()
            upsertContact(contact)
            updateContactRequestStatus(
                id: requestID,
                status: .accepted,
                respondedAt: Date()
            )
            context.contactStore.contactRequestActionMessage = "已添加好友。"
            scheduleCachePersist()
            await reloadContacts()
            return true
        } catch {
            await handleContactRequestsActionError(error)
            return false
        }
    }

    func declineContactRequest(id requestID: UUID) async -> Bool {
        guard !context.contactStore.decliningRequestIDs.contains(requestID) else {
            return false
        }

        context.contactStore.decliningRequestIDs.insert(requestID)
        context.contactStore.contactRequestActionMessage = nil
        defer { context.contactStore.decliningRequestIDs.remove(requestID) }

        do {
            _ = try await context.sessionFacade.declineContactRequest(id: requestID)
            context.markServerOnline()
            updateContactRequestStatus(
                id: requestID,
                status: .declined,
                respondedAt: Date()
            )
            context.contactStore.contactRequestActionMessage = "已拒绝好友申请。"
            scheduleCachePersist()
            return true
        } catch {
            await handleContactRequestsActionError(error)
            return false
        }
    }

    func cancelContactRequest(id requestID: UUID) async -> Bool {
        guard !context.contactStore.cancellingRequestIDs.contains(requestID) else {
            return false
        }

        context.contactStore.cancellingRequestIDs.insert(requestID)
        context.contactStore.contactRequestActionMessage = nil
        defer { context.contactStore.cancellingRequestIDs.remove(requestID) }

        do {
            _ = try await context.sessionFacade.cancelContactRequest(id: requestID)
            context.markServerOnline()
            updateContactRequestStatus(
                id: requestID,
                status: .cancelled,
                respondedAt: Date()
            )
            context.contactStore.contactRequestActionMessage = "好友申请已取消。"
            scheduleCachePersist()
            return true
        } catch {
            await handleContactRequestsActionError(error)
            return false
        }
    }

    func updateContactRemark(contactUserID: UUID, remark: String) async -> Bool {
        do {
            let contact = try await context.sessionFacade.updateContact(
                contactUserID: contactUserID,
                remark: context.sessionFacade.normalizedRemark(remark)
            )
            context.markServerOnline()
            upsertContact(contact)
            context.contactStore.contactsMessage = "联系人备注已更新。"
            scheduleCachePersist()
            return true
        } catch {
            await handleContactRequestError(error)
            return false
        }
    }

    func deleteContact(_ contactUserID: UUID) async -> Bool {
        do {
            try await context.sessionFacade.deleteContact(contactUserID: contactUserID)
            context.markServerOnline()
            context.contactStore.contacts.removeAll { $0.id == contactUserID }
            context.contactStore.contactsMessage = "已删除联系人。"
            scheduleCachePersist()
            return true
        } catch {
            await handleContactRequestError(error)
            return false
        }
    }

    func blockUser(_ userID: UUID, reason: String? = nil) async -> Bool {
        do {
            let block = try await context.sessionClient.blockUser(userID: userID, reason: reason)
            context.contactStore.blockedUsers.removeAll { $0.blockedUserID == block.blockedUserID }
            context.contactStore.blockedUsers.append(block)
            context.contactStore.blockedUsers.sort { $0.createdAt > $1.createdAt }
            context.markServerOnline()
            return true
        } catch {
            await context.handleIMDataRequestError(error)
            return false
        }
    }

    func unblockUser(_ userID: UUID) async -> Bool {
        do {
            _ = try await context.sessionClient.unblockUser(userID: userID)
            context.contactStore.blockedUsers.removeAll { $0.blockedUserID == userID }
            context.markServerOnline()
            return true
        } catch {
            await context.handleIMDataRequestError(error)
            return false
        }
    }

    func loadBlockedUsers() async {
        guard context.currentUserProvider() != nil else {
            return
        }

        context.contactStore.isLoadingBlockedUsers = true
        defer {
            context.contactStore.isLoadingBlockedUsers = false
        }

        do {
            context.contactStore.blockedUsers = try await context.sessionClient.fetchBlocks()
                .sorted { $0.createdAt > $1.createdAt }
            context.markServerOnline()
        } catch {
            await context.handleIMDataRequestError(error)
        }
    }

    func restoreCacheIfAvailable(for user: AuthUser) async {
        do {
            let snapshot = try await context.sessionFacade.loadContactStateCacheSnapshot(for: user.id)
            guard context.currentUserProvider()?.id == user.id else {
                return
            }

            context.contactStore.contacts = snapshot.contacts.map(\.contact).sorted { $0.email < $1.email }
            context.contactStore.contactRequests = context.sessionFacade.normalizeRequests(
                snapshot.incomingRequests.map(\.request)
                    + snapshot.outgoingRequests.map(\.request)
                    + snapshot.resolvedRequests.map(\.request),
                currentUserID: user.id
            )
            context.contactStore.lastContactStateRefreshAt = snapshot.lastRefreshAt
            context.contactStore.lastSeenIncomingContactRequestAt = snapshot.lastSeenIncomingContactRequestAt
            recomputeIncomingUnreadState()
        } catch {
            // Ignore cache restore failures and fall back to HTTP recovery.
        }
    }

    func applyContactEvent(_ payload: IMTCPContactEventPayload) {
        let result = context.contactStore.apply(
            event: payload,
            currentUserID: context.currentUserProvider()?.id,
            isRelevant: { [context] request, currentUserID in
                context.sessionFacade.isRequestRelevant(request, to: currentUserID)
            },
            normalize: { [context] requests, currentUserID in
                context.sessionFacade.normalizeRequests(requests, currentUserID: currentUserID)
            },
            sortPendingNewestFirst: { [context] lhs, rhs in
                context.sessionFacade.sortPendingNewestFirst(lhs, rhs)
            }
        )

        switch result {
        case .applied:
            scheduleCachePersist()
        case .needsCorrection(let reason):
            scheduleCorrection(reason: reason)
        case .ignored:
            break
        }
    }

    func upsertContact(_ contact: ContactResponseBody) {
        context.contactStore.upsertContact(contact)
    }

    func replaceContactRequests(_ requests: [ContactRequestResponseBody], currentUserID: UUID) {
        context.contactStore.replaceRequests(
            requests,
            currentUserID: currentUserID,
            normalize: { [context] requests, currentUserID in
                context.sessionFacade.normalizeRequests(requests, currentUserID: currentUserID)
            }
        )
        recomputeIncomingUnreadState()
    }

    func upsertContactRequest(_ request: ContactRequestResponseBody) {
        guard let currentUserID = context.currentUserProvider()?.id else {
            return
        }

        context.contactStore.upsertRequest(
            request,
            currentUserID: currentUserID,
            isRelevant: { [context] request, currentUserID in
                context.sessionFacade.isRequestRelevant(request, to: currentUserID)
            },
            normalize: { [context] requests, currentUserID in
                context.sessionFacade.normalizeRequests(requests, currentUserID: currentUserID)
            }
        )
        recomputeIncomingUnreadState()
    }

    func updateContactRequestStatus(
        id requestID: UUID,
        status: ContactRequestStatus,
        respondedAt: Date
    ) {
        guard let currentUserID = context.currentUserProvider()?.id else {
            return
        }
        context.contactStore.updateRequestStatus(
            id: requestID,
            status: status,
            respondedAt: respondedAt,
            currentUserID: currentUserID,
            normalize: { [context] requests, currentUserID in
                context.sessionFacade.normalizeRequests(requests, currentUserID: currentUserID)
            }
        )
        recomputeIncomingUnreadState()
    }

    func scheduleCorrection(force: Bool = false, reason _: String? = nil) {
        correctionTask?.cancel()
        correctionTask = Task { [weak self] in
            guard let self else {
                return
            }

            if !force {
                try? await Task.sleep(nanoseconds: ContactRuntimeTiming.correctionDebounceNanoseconds)
            }

            guard !Task.isCancelled else {
                return
            }

            await self.syncAfterConnection()
            self.correctionTask = nil
        }
    }

    func scheduleCachePersist() {
        guard context.currentUserProvider() != nil else {
            return
        }

        cachePersistTask?.cancel()
        cachePersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ContactRuntimeTiming.cachePersistDebounceNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await self?.flushCache()
        }
    }

    func flushCache() async {
        cachePersistTask?.cancel()
        cachePersistTask = nil

        guard let user = context.currentUserProvider() else {
            return
        }

        do {
            try await context.sessionFacade.saveContactStateCacheSnapshot(
                makeCacheSnapshot(),
                for: user.id
            )
        } catch {
            // Ignore cache persistence failures and keep the in-memory state authoritative.
        }
    }

    func cancelRuntimeTasksForSignedOut() {
        correctionTask?.cancel()
        correctionTask = nil
        cachePersistTask?.cancel()
        cachePersistTask = nil
    }

    func markIncomingRequestsSeen() {
        if let latestIncomingContactRequestAt {
            context.contactStore.lastSeenIncomingContactRequestAt = latestIncomingContactRequestAt
        }

        recomputeIncomingUnreadState()
        scheduleCachePersist()
    }

    func recomputeIncomingUnreadState() {
        guard let currentUserID = context.currentUserProvider()?.id else {
            context.contactStore.unseenIncomingContactRequestCount = 0
            return
        }
        context.contactStore.recomputeIncomingUnread(
            currentUserID: currentUserID,
            sortPendingNewestFirst: { [context] lhs, rhs in
                context.sessionFacade.sortPendingNewestFirst(lhs, rhs)
            }
        )
    }

    func makeCacheSnapshot() -> ContactStateCacheSnapshot {
        ContactStateCacheSnapshot(
            contacts: context.contactStore.contacts.map(CachedContactState.init),
            incomingRequests: incomingPendingContactRequests.map(CachedContactRequestState.init),
            outgoingRequests: outgoingPendingContactRequests.map(CachedContactRequestState.init),
            resolvedRequests: recentResolvedContactRequests.map(CachedContactRequestState.init),
            lastRefreshAt: context.contactStore.lastContactStateRefreshAt,
            lastSeenIncomingContactRequestAt: context.contactStore.lastSeenIncomingContactRequestAt
        )
    }

    var latestIncomingContactRequestAt: Date? {
        incomingPendingContactRequests.compactMap(\.createdAt).max()
    }

    private var incomingPendingContactRequests: [ContactRequestResponseBody] {
        context.contactStore.incomingPendingContactRequests(
            currentUserID: context.currentUserProvider()?.id,
            sort: context.sessionFacade.sortPendingNewestFirst
        )
    }

    private var outgoingPendingContactRequests: [ContactRequestResponseBody] {
        context.contactStore.outgoingPendingContactRequests(
            currentUserID: context.currentUserProvider()?.id,
            sort: context.sessionFacade.sortPendingNewestFirst
        )
    }

    private var recentResolvedContactRequests: [ContactRequestResponseBody] {
        context.contactStore.recentResolvedContactRequests(sort: context.sessionFacade.sortResolvedNewestFirst)
    }

    private func handleContactRequestError(_ error: Error) async {
        context.contactStore.contactsMessage = error.localizedDescription
        await handleSessionError(error)
    }

    private func handleContactRequestsLoadError(_ error: Error) async {
        context.contactStore.contactRequestsLoadMessage = error.localizedDescription
        await handleSessionError(error)
    }

    private func handleContactRequestsActionError(_ error: Error) async {
        context.contactStore.contactRequestActionMessage = error.localizedDescription
        await handleSessionError(error)
    }

    private func handleSessionError(_ error: Error) async {
        if await context.shouldPreserveSession(error) {
            await context.markServerUnavailableIfNeeded(error)
        } else {
            await context.clearSession(error.localizedDescription)
        }
    }
}
