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
    private var contactRefreshTask: Task<Void, Never>?
    private var contactRequestsRefreshTask: Task<Void, Never>?
    private var blockedUsersRefreshTask: Task<Void, Never>?
    private var contactRefreshToken: UUID?
    private var contactRequestsRefreshToken: UUID?
    private var blockedUsersRefreshToken: UUID?

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
        if let contactRefreshTask {
            await contactRefreshTask.value
            return
        }

        let token = UUID()
        contactRefreshToken = token
        let task = Task { @MainActor [weak self] in
            await self?.reloadContactsImmediately()
            if self?.contactRefreshToken == token {
                self?.contactRefreshTask = nil
                self?.contactRefreshToken = nil
            }
        }
        contactRefreshTask = task
        await task.value
    }

    private func reloadContactsImmediately() async {
        guard let user = context.currentUserProvider() else {
            context.contactStore.contacts = []
            return
        }

        context.contactStore.isLoadingContacts = true
        defer { context.contactStore.isLoadingContacts = false }

        do {
            let snapshot = try await context.sessionFacade.fetchContacts()
            guard !Task.isCancelled else {
                return
            }
            guard context.currentUserProvider()?.id == user.id else {
                return
            }

            context.markServerOnline()
            context.contactStore.contacts = snapshot.contacts
            context.contactStore.lastContactStateRefreshAt = snapshot.lastRefreshAt
            scheduleCachePersist()
        } catch {
            await handleContactRequestError(error)
        }
    }

    func reloadContactRequests() async {
        if let contactRequestsRefreshTask {
            await contactRequestsRefreshTask.value
            return
        }

        let token = UUID()
        contactRequestsRefreshToken = token
        let task = Task { @MainActor [weak self] in
            await self?.reloadContactRequestsImmediately()
            if self?.contactRequestsRefreshToken == token {
                self?.contactRequestsRefreshTask = nil
                self?.contactRequestsRefreshToken = nil
            }
        }
        contactRequestsRefreshTask = task
        await task.value
    }

    private func reloadContactRequestsImmediately() async {
        guard let user = context.currentUserProvider() else {
            context.contactStore.contactRequests = []
            context.contactStore.unseenIncomingContactRequestCount = 0
            return
        }

        context.contactStore.isLoadingContactRequests = true
        defer { context.contactStore.isLoadingContactRequests = false }

        do {
            let snapshot = try await context.sessionFacade.fetchContactRequests()
            guard !Task.isCancelled else {
                return
            }
            guard context.currentUserProvider()?.id == user.id else {
                return
            }

            context.markServerOnline()
            replaceContactRequests(snapshot.requests, currentUserID: user.id)
            context.contactStore.lastContactStateRefreshAt = snapshot.lastRefreshAt
            scheduleCachePersist()
        } catch {
            await handleContactRequestsLoadError(error)
        }
    }

    func sendContactRequestResult(email: String, message: String? = nil, remark: String? = nil) async -> ContactOperationResult {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMessage = context.sessionFacade.normalizedRequestMessage(message)
        let normalizedRemark = context.sessionFacade.normalizedRemark(remark)
        guard !normalizedEmail.isEmpty else {
            return .warning("好友邮箱不能为空。")
        }

        do {
            let request = try await context.sessionFacade.sendContactRequest(
                email: normalizedEmail,
                message: normalizedMessage,
                remark: normalizedRemark
            )
            guard !Task.isCancelled else {
                return .failure("")
            }
            context.markServerOnline()
            upsertContactRequest(request)
            scheduleCachePersist()
            return .success("好友申请已发送。")
        } catch {
            return await contactActionFailureResult(error)
        }
    }

    func acceptContactRequestResult(id requestID: UUID, remark: String? = nil) async -> ContactOperationResult {
        guard !context.contactStore.acceptingRequestIDs.contains(requestID) else {
            return .warning("好友申请正在处理。")
        }

        context.contactStore.acceptingRequestIDs.insert(requestID)
        defer { context.contactStore.acceptingRequestIDs.remove(requestID) }

        do {
            let contact = try await context.sessionFacade.acceptContactRequest(
                id: requestID,
                remark: context.sessionFacade.normalizedRemark(remark)
            )
            guard !Task.isCancelled else {
                return .failure("")
            }
            context.markServerOnline()
            upsertContact(contact)
            updateContactRequestStatus(
                id: requestID,
                status: .accepted,
                respondedAt: Date()
            )
            scheduleCachePersist()
            await reloadContactsAfterContactAction()
            return .success("已添加好友。")
        } catch {
            return await contactActionFailureResult(error)
        }
    }

    func declineContactRequestResult(id requestID: UUID) async -> ContactOperationResult {
        guard !context.contactStore.decliningRequestIDs.contains(requestID) else {
            return .warning("好友申请正在处理。")
        }

        context.contactStore.decliningRequestIDs.insert(requestID)
        defer { context.contactStore.decliningRequestIDs.remove(requestID) }

        do {
            _ = try await context.sessionFacade.declineContactRequest(id: requestID)
            guard !Task.isCancelled else {
                return .failure("")
            }
            context.markServerOnline()
            updateContactRequestStatus(
                id: requestID,
                status: .declined,
                respondedAt: Date()
            )
            scheduleCachePersist()
            return .success("已拒绝好友申请。")
        } catch {
            return await contactActionFailureResult(error)
        }
    }

    func cancelContactRequestResult(id requestID: UUID) async -> ContactOperationResult {
        guard !context.contactStore.cancellingRequestIDs.contains(requestID) else {
            return .warning("好友申请正在处理。")
        }

        context.contactStore.cancellingRequestIDs.insert(requestID)
        defer { context.contactStore.cancellingRequestIDs.remove(requestID) }

        do {
            _ = try await context.sessionFacade.cancelContactRequest(id: requestID)
            guard !Task.isCancelled else {
                return .failure("")
            }
            context.markServerOnline()
            updateContactRequestStatus(
                id: requestID,
                status: .cancelled,
                respondedAt: Date()
            )
            scheduleCachePersist()
            return .success("好友申请已取消。")
        } catch {
            return await contactActionFailureResult(error)
        }
    }

    func updateContactRemarkResult(contactUserID: UUID, remark: String) async -> ContactOperationResult {
        do {
            let contact = try await context.sessionFacade.updateContact(
                contactUserID: contactUserID,
                remark: context.sessionFacade.normalizedRemark(remark)
            )
            guard !Task.isCancelled else {
                return .failure("")
            }
            context.markServerOnline()
            upsertContact(contact)
            scheduleCachePersist()
            return .success("联系人备注已更新。")
        } catch {
            guard !(error is CancellationError) else {
                return .failure("")
            }
            await handleSessionError(error)
            return .failure(ContactOperationErrorMapper.message(for: error))
        }
    }

    func deleteContactResult(_ contactUserID: UUID) async -> ContactOperationResult {
        do {
            try await context.sessionFacade.deleteContact(contactUserID: contactUserID)
            guard !Task.isCancelled else {
                return .failure("")
            }
            context.markServerOnline()
            context.contactStore.contacts.removeAll { $0.id == contactUserID }
            scheduleCachePersist()
            return .success("已删除联系人。")
        } catch {
            guard !(error is CancellationError) else {
                return .failure("")
            }
            await handleSessionError(error)
            return .failure(ContactOperationErrorMapper.message(for: error))
        }
    }

    func blockUserResult(_ userID: UUID, reason: String? = nil) async -> ContactOperationResult {
        do {
            let display = context.contactStore.knownUserDisplay(for: userID)
            let block = try await context.sessionClient.blockUser(userID: userID, reason: reason)
            guard !Task.isCancelled else {
                return .failure("")
            }
            if let display {
                context.contactStore.cacheKnownUserDisplay(display)
            }
            context.contactStore.blockedUsers.removeAll { $0.blockedUserID == block.blockedUserID }
            context.contactStore.blockedUsers.append(block)
            context.contactStore.blockedUsers.sort { $0.createdAt > $1.createdAt }
            context.contactStore.removeContact(userID: block.blockedUserID)
            context.markServerOnline()
            scheduleCachePersist()
            return .success("已拉入黑名单。")
        } catch {
            guard !(error is CancellationError) else {
                return .failure("")
            }
            await context.handleIMDataRequestError(error)
            return .failure(ContactOperationErrorMapper.message(for: error))
        }
    }

    func unblockUserResult(_ userID: UUID) async -> ContactOperationResult {
        do {
            _ = try await context.sessionClient.unblockUser(userID: userID)
            guard !Task.isCancelled else {
                return .failure("")
            }
            context.contactStore.blockedUsers.removeAll { $0.blockedUserID == userID }
            context.markServerOnline()
            return .success("已解除黑名单，可重新添加好友。")
        } catch {
            guard !(error is CancellationError) else {
                return .failure("")
            }
            await context.handleIMDataRequestError(error)
            return .failure(ContactOperationErrorMapper.message(for: error))
        }
    }

    func loadBlockedUsers() async {
        if let blockedUsersRefreshTask {
            await blockedUsersRefreshTask.value
            return
        }

        let token = UUID()
        blockedUsersRefreshToken = token
        let task = Task { @MainActor [weak self] in
            await self?.loadBlockedUsersImmediately()
            if self?.blockedUsersRefreshToken == token {
                self?.blockedUsersRefreshTask = nil
                self?.blockedUsersRefreshToken = nil
            }
        }
        blockedUsersRefreshTask = task
        await task.value
    }

    private func loadBlockedUsersImmediately() async {
        guard context.currentUserProvider() != nil else {
            return
        }

        context.contactStore.isLoadingBlockedUsers = true
        defer {
            context.contactStore.isLoadingBlockedUsers = false
        }

        do {
            let blockedUsers = try await context.sessionClient.fetchBlocks()
            guard !Task.isCancelled else {
                return
            }
            context.contactStore.blockedUsers = blockedUsers
                .sorted { $0.createdAt > $1.createdAt }
            context.markServerOnline()
        } catch {
            guard !(error is CancellationError) else {
                return
            }
            await context.handleIMDataRequestError(error)
        }
    }

    func restoreCacheIfAvailable(for user: AuthUser) async {
        do {
            let snapshot = try await context.sessionFacade.loadContactStateCacheSnapshot(for: user.id)
            guard context.currentUserProvider()?.id == user.id else {
                return
            }

            guard context.contactStore.contacts.isEmpty,
                  context.contactStore.contactRequests.isEmpty
            else {
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
        context.contactStore.updateRequestStatus(
            id: requestID,
            status: status,
            respondedAt: respondedAt
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
        contactRefreshTask?.cancel()
        contactRefreshTask = nil
        contactRefreshToken = nil
        contactRequestsRefreshTask?.cancel()
        contactRequestsRefreshTask = nil
        contactRequestsRefreshToken = nil
        blockedUsersRefreshTask?.cancel()
        blockedUsersRefreshTask = nil
        blockedUsersRefreshToken = nil
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

    private func contactActionFailureResult(_ error: Error) async -> ContactOperationResult {
        guard !(error is CancellationError) else {
            return .failure("")
        }
        await handleSessionError(error)
        return .failure(ContactOperationErrorMapper.message(for: error))
    }

    private func reloadContactsAfterContactAction() async {
        guard let user = context.currentUserProvider() else {
            context.contactStore.contacts = []
            return
        }

        do {
            let snapshot = try await context.sessionFacade.fetchContacts()
            guard !Task.isCancelled else {
                return
            }
            guard context.currentUserProvider()?.id == user.id else {
                return
            }

            context.markServerOnline()
            context.contactStore.contacts = snapshot.contacts
            context.contactStore.lastContactStateRefreshAt = snapshot.lastRefreshAt
            scheduleCachePersist()
        } catch {
            guard !(error is CancellationError) else {
                return
            }
            await handleSessionError(error)
        }
    }

    private func handleContactRequestError(_ error: Error) async {
        guard !(error is CancellationError) else {
            return
        }
        context.contactStore.setNotice(ContactOperationErrorMapper.message(for: error), scope: .contactsHome, tone: .error)
        await handleSessionError(error)
    }

    private func handleContactRequestsLoadError(_ error: Error) async {
        guard !(error is CancellationError) else {
            return
        }
        context.contactStore.setNotice(ContactOperationErrorMapper.message(for: error), scope: .requests, tone: .error)
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
