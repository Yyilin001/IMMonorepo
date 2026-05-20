import Combine
import Foundation
import IMClientKit
import SwiftUI
import UIKit

enum DirectPeerRelationshipState: Equatable {
    case friend
    case none
    case outgoingPending
    case incomingPending
    case resolving
    case unavailable
}

struct DirectPeerRelationshipPresentation: Equatable {
    let state: DirectPeerRelationshipState
    let message: String
    let peerUserID: UUID?
    let peerEmail: String?
    let requestID: UUID?
}

struct IMConversationIdentityPresentation: Equatable {
    let title: String
    let detailSummary: String
    let rowSecondaryLabel: String?
}

@MainActor
final class AuthManager: ObservableObject {
    enum IMHistoryPage {
        static let refreshDebounceNanoseconds: UInt64 = 400_000_000
        static let cachePersistDebounceNanoseconds: UInt64 = 300_000_000
        static let resolvedContactRequestHistoryLimit = 50
    }

    enum Phase: Equatable {
        case launching
        case signedOut(message: String?)
        case signedIn(AuthUser)
    }

    enum AuthAction {
        case login
        case register
    }

    enum ServerStatus: Equatable {
        case unknown
        case online
        case offline(message: String)
    }

    enum IMConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(message: String)
    }

    let appRootStore: AppRootStore
    let sessionStore: AppSessionStore
    let contactStore: ContactStore

    var phase: Phase {
        get { sessionStore.phase }
        set { sessionStore.phase = newValue }
    }

    var isBusy: Bool {
        get { sessionStore.isBusy }
        set { sessionStore.isBusy = newValue }
    }

    var sessions: [SessionSnapshot] {
        get { sessionStore.sessions }
        set { sessionStore.sessions = newValue }
    }

    var isLoadingSessions: Bool {
        get { sessionStore.isLoadingSessions }
        set { sessionStore.isLoadingSessions = newValue }
    }

    var sessionsMessage: String? {
        get { sessionStore.sessionsMessage }
        set { sessionStore.sessionsMessage = newValue }
    }

    var contacts: [ContactResponseBody] {
        get { contactStore.contacts }
        set { contactStore.contacts = newValue }
    }

    var isLoadingContacts: Bool {
        get { contactStore.isLoadingContacts }
        set { contactStore.isLoadingContacts = newValue }
    }

    var contactsMessage: String? {
        get { contactStore.contactsMessage }
        set { contactStore.contactsMessage = newValue }
    }

    var contactRequests: [ContactRequestResponseBody] {
        get { contactStore.contactRequests }
        set { contactStore.contactRequests = newValue }
    }

    var unseenIncomingContactRequestCount: Int {
        get { contactStore.unseenIncomingContactRequestCount }
        set { contactStore.unseenIncomingContactRequestCount = newValue }
    }

    var isLoadingContactRequests: Bool {
        get { contactStore.isLoadingContactRequests }
        set { contactStore.isLoadingContactRequests = newValue }
    }

    var contactRequestsLoadMessage: String? {
        get { contactStore.contactRequestsLoadMessage }
        set { contactStore.contactRequestsLoadMessage = newValue }
    }

    var contactRequestActionMessage: String? {
        get { contactStore.contactRequestActionMessage }
        set { contactStore.contactRequestActionMessage = newValue }
    }

    var isUpdatingProfile: Bool {
        get { sessionStore.isUpdatingProfile }
        set { sessionStore.isUpdatingProfile = newValue }
    }

    var profileMessage: String? {
        get { sessionStore.profileMessage }
        set { sessionStore.profileMessage = newValue }
    }

    var acceptingRequestIDs: Set<UUID> {
        get { contactStore.acceptingRequestIDs }
        set { contactStore.acceptingRequestIDs = newValue }
    }

    var decliningRequestIDs: Set<UUID> {
        get { contactStore.decliningRequestIDs }
        set { contactStore.decliningRequestIDs = newValue }
    }

    var cancellingRequestIDs: Set<UUID> {
        get { contactStore.cancellingRequestIDs }
        set { contactStore.cancellingRequestIDs = newValue }
    }

    var directConversationRelationshipActionMessages: [String: String] {
        get { contactStore.directConversationRelationshipActionMessages }
        set { contactStore.directConversationRelationshipActionMessages = newValue }
    }

    var sendingDirectConversationFriendRequestConversationIDs: Set<String> {
        get { contactStore.sendingDirectConversationFriendRequestConversationIDs }
        set { contactStore.sendingDirectConversationFriendRequestConversationIDs = newValue }
    }

    var blockedUsers: [UserBlockResponseBody] {
        get { contactStore.blockedUsers }
        set { contactStore.blockedUsers = newValue }
    }

    var isLoadingBlockedUsers: Bool {
        get { contactStore.isLoadingBlockedUsers }
        set { contactStore.isLoadingBlockedUsers = newValue }
    }

    var blockedUserIDs: Set<UUID> {
        Set(blockedUsers.map(\.blockedUserID))
    }

    var serverStatus: ServerStatus {
        get { sessionStore.serverStatus }
        set { sessionStore.serverStatus = newValue }
    }

    @Published var imConnectionStatus: IMConnectionStatus = .disconnected
    @Published private(set) var isFlushingQueuedIMTextMessages = false

    var incomingContactRequests: [ContactRequestResponseBody] {
        incomingPendingContactRequests
    }

    var outgoingContactRequests: [ContactRequestResponseBody] {
        outgoingPendingContactRequests
    }

    var incomingPendingContactRequests: [ContactRequestResponseBody] {
        contactStore.incomingPendingContactRequests(
            currentUserID: currentUser?.id,
            sort: sessionFacade.sortPendingNewestFirst
        )
    }

    var outgoingPendingContactRequests: [ContactRequestResponseBody] {
        contactStore.outgoingPendingContactRequests(
            currentUserID: currentUser?.id,
            sort: sessionFacade.sortPendingNewestFirst
        )
    }

    var recentResolvedContactRequests: [ContactRequestResponseBody] {
        contactStore.recentResolvedContactRequests(sort: sessionFacade.sortResolvedNewestFirst)
    }

    var pendingIncomingContactRequestCount: Int {
        incomingPendingContactRequests.count
    }

    var totalPendingContactRequestCount: Int {
        incomingPendingContactRequests.count + outgoingPendingContactRequests.count
    }

    var hasUnreadIncomingContactRequests: Bool {
        unseenIncomingContactRequestCount > 0
    }

    var hasAnyContactRequests: Bool {
        !contactRequests.isEmpty
    }

    let sessionClient: SessionClient
    let sessionFacade: SessionFacade
    let openIMConnection: @Sendable () async throws -> IMTCPConnection
    let backgroundTransferMonitor: any BackgroundTransferMonitoring
    let imConversationCache: IMConversationCacheHandler
    var storeCancellables: Set<AnyCancellable> = []
    var restoreTask: Task<Void, Never>?
    var restoreGeneration: UInt64 = 0
    var imConversationListTask: Task<Void, Never>?
    var contactStateCorrectionTask: Task<Void, Never>?
    var imConversationCachePersistTask: Task<Void, Never>?
    var contactStateCachePersistTask: Task<Void, Never>?
    var lastIMConversationSummaryRefreshAt: Date?
    var imConversationSummarySyncToken: String?
    var latestIMConversationSummaries: [IMConversationSummaryResponseBody] = []
    var lastContactStateRefreshAt: Date? {
        get { contactStore.lastContactStateRefreshAt }
        set { contactStore.lastContactStateRefreshAt = newValue }
    }
    var lastSeenIncomingContactRequestAt: Date? {
        get { contactStore.lastSeenIncomingContactRequestAt }
        set { contactStore.lastSeenIncomingContactRequestAt = newValue }
    }
    let probeManager: ProbeManager
    let fileTransferManager: FileTransferManager
    let imConversationStore: IMConversationStore
    lazy var conversationRuntimeController = makeConversationRuntimeController()
    lazy var conversationPresentationStore = IMConversationPresentationStore(authManager: self)
    lazy var conversationRuntimeStore = IMConversationRuntimeStore(authManager: self)

    convenience init(
        network: NetworkEnvironment,
        imConnectionConfiguration: IMTCPClientConfiguration,
        tokenStore: KeychainStore = KeychainStore(),
        userCache: UserDefaultsSessionCache = UserDefaultsSessionCache(),
        backgroundTransferMonitor: any BackgroundTransferMonitoring = BackgroundTransferCoordinator.shared,
        imConversationCache: IMConversationCacheHandler = ClientPersistenceFactory().makeIMConversationCacheHandler(),
        contactStateCache: ContactStateCacheHandler = ClientPersistenceFactory().makeContactStateCacheHandler(),
        shouldRestoreSession: Bool = true
    ) {
        let sessionClient = SessionClient(
            network: network,
            tokenStore: tokenStore,
            userCache: userCache
        )
        self.init(
            dependencies: AuthManagerDependencies(
                sessionClient: sessionClient,
                openIMConnection: {
                    try await sessionClient.openIMConnection(configuration: imConnectionConfiguration)
                },
                backgroundTransferMonitor: backgroundTransferMonitor,
                imConversationCache: imConversationCache,
                contactStateCache: contactStateCache,
                shouldRestoreSession: shouldRestoreSession
            )
        )
    }

    convenience init<TokenStoreType: TokenStore, UserCacheType: UserSessionCache>(
        httpClient: HTTPClient,
        fileTransferClient: FileTransferClient? = nil,
        tokenStore: TokenStoreType,
        userCache: UserCacheType,
        openIMConnection: (@Sendable () async throws -> IMTCPConnection)? = nil,
        backgroundTransferMonitor: any BackgroundTransferMonitoring = BackgroundTransferCoordinator.shared,
        imConversationCache: IMConversationCacheHandler = IMConversationCacheHandler(NoopIMConversationCache()),
        contactStateCache: ContactStateCacheHandler = ContactStateCacheHandler(NoopContactStateCache()),
        shouldRestoreSession: Bool = true
    ) {
        let sessionClient = SessionClient(
            httpClient: httpClient,
            fileTransferClient: fileTransferClient,
            tokenStore: tokenStore,
            userCache: userCache
        )
        self.init(
            dependencies: AuthManagerDependencies(
                sessionClient: sessionClient,
                openIMConnection: openIMConnection ?? {
                    throw URLError(.notConnectedToInternet)
                },
                backgroundTransferMonitor: backgroundTransferMonitor,
                imConversationCache: imConversationCache,
                contactStateCache: contactStateCache,
                shouldRestoreSession: shouldRestoreSession
            )
        )
    }

    init(dependencies: AuthManagerDependencies) {
        let sessionClient = dependencies.sessionClient
        self.sessionClient = sessionClient
        let authSessionController = AuthSessionController(sessionClient: sessionClient)
        let contactsController = ContactsController(
            sessionClient: sessionClient,
            contactStateCache: dependencies.contactStateCache
        )
        self.sessionFacade = SessionFacade(
            authSessionController: authSessionController,
            contactsController: contactsController
        )
        self.openIMConnection = dependencies.openIMConnection
        self.backgroundTransferMonitor = dependencies.backgroundTransferMonitor
        self.imConversationCache = dependencies.imConversationCache
        let sessionStore = AppSessionStore()
        let contactStore = ContactStore()
        let conversationStore = IMConversationStore()
        self.sessionStore = sessionStore
        self.contactStore = contactStore
        self.imConversationStore = conversationStore
        self.appRootStore = AppRootStore(
            sessionStore: sessionStore,
            contactStore: contactStore,
            conversationStore: conversationStore
        )
        self.probeManager = ProbeManager(sessionClient: sessionClient)
        self.fileTransferManager = FileTransferManager(
            fileAPI: FileAPI(sessionClient: sessionClient),
            sessionClient: sessionClient,
            backgroundTransferMonitor: dependencies.backgroundTransferMonitor
        )
        self.probeManager.delegate = self
        self.fileTransferManager.delegate = self
        bindChildStores()

        if dependencies.shouldRestoreSession {
            scheduleRestoreSession()
        } else {
            phase = .signedOut(message: nil)
        }
    }

    func bindChildStores() {
        sessionStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &storeCancellables)

        contactStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &storeCancellables)
    }

    func makeConversationRuntimeController() -> ConversationRuntimeController {
        ConversationRuntimeFactory.make(context: AuthRuntimeContext(
            sessionClient: sessionClient,
            openIMConnection: openIMConnection,
            imConversationStore: imConversationStore,
            currentUserProvider: { [weak self] in
                self?.currentUser
            },
            isSignedInProvider: { [weak self] in
                guard let self else {
                    return false
                }
                if case .signedIn = self.phase {
                    return true
                }
                return false
            },
            latestConversationSummariesProvider: { [weak self] in
                self?.latestIMConversationSummaries ?? []
            },
            setLatestConversationSummaries: { [weak self] summaries in
                self?.latestIMConversationSummaries = summaries
            },
            conversationSummaryRefreshAtProvider: { [weak self] in
                self?.lastIMConversationSummaryRefreshAt
            },
            setConversationSummaryRefreshAt: { [weak self] date in
                self?.lastIMConversationSummaryRefreshAt = date
            },
            conversationSummarySyncTokenProvider: { [weak self] in
                self?.imConversationSummarySyncToken
            },
            setConversationSummarySyncToken: { [weak self] token in
                self?.imConversationSummarySyncToken = token
            },
            markServerOnline: { [weak self] in
                self?.markServerOnline()
            },
            clearSession: { [weak self] message in
                await self?.clearSession(message: message)
            },
            handleIMDataRequestError: { [weak self] error in
                await self?.handleIMDataRequestError(error)
            },
            syncContactStateAfterConnection: { [weak self] in
                await self?.syncContactStateAfterConnection()
            },
            scheduleConversationCachePersist: { [weak self] in
                self?.scheduleIMConversationCachePersist()
            },
            flushConversationCache: { [weak self] in
                await self?.flushIMConversationCache()
            },
            flushContactStateCache: { [weak self] in
                await self?.flushContactStateCache()
            },
            applyContactEvent: { [weak self] payload in
                self?.applyContactEvent(payload)
            },
            setConnectionStatus: { [weak self] status in
                self?.imConnectionStatus = status
            },
            setQueuedFlushActive: { [weak self] isActive in
                self?.isFlushingQueuedIMTextMessages = isActive
            },
            backgroundTransferMonitor: backgroundTransferMonitor
        ))
    }
}
