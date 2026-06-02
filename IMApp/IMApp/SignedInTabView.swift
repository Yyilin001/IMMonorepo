import SwiftUI
import IMClientKit

enum SignedInTab: Hashable {
    case messages
    case contacts
    case me
}

enum SignedInRoute: Hashable {
    case conversation(String)
    case requests
    case contact(UUID)
    case blockedUsers
    case profile
    case sessions
    case privacy
    case fileTransfer
    case networkStatus
    case diagnostics
}

struct SignedInTabView: View {
    let sessionStore: AppSessionStore
    let contactStore: ContactStore
    let conversationStore: IMConversationStore
    let conversationPresentationStore: IMConversationPresentationStore
    let conversationRuntimeStore: IMConversationRuntimeStore
    let probeManager: ProbeManager
    let fileTransferManager: FileTransferManager

    let user: AuthUser
    let imConnectionStatus: AuthManager.IMConnectionStatus
    let reloadProfile: () async -> Void
    let updateProfile: (String?, UserAvatarPreset?) async -> Bool
    let reconnectIMConnection: () async -> Void
    let logout: () async -> Void
    let loadSessions: () async -> Void
    let signOutCurrentDevice: () async -> Void
    let logoutAllSessions: () async -> Void
    let signOut: (UUID, Bool) async -> Void
    let reloadContacts: () async -> Void
    let reloadContactRequests: () async -> Void
    let loadBlockedUsers: () async -> Void
    let markIncomingContactRequestsSeen: () -> Void
    let sendContactRequest: (String, String, String) async -> ContactOperationResult
    let acceptContactRequest: (UUID, String) async -> ContactOperationResult
    let declineContactRequest: (UUID) async -> ContactOperationResult
    let cancelContactRequest: (UUID) async -> ContactOperationResult
    let updateContactRemark: (UUID, String) async -> ContactOperationResult
    let deleteContact: (UUID) async -> ContactOperationResult
    let blockUser: (UUID) async -> ContactOperationResult
    let unblockUser: (UUID) async -> ContactOperationResult
    let reportUser: (UUID, String, String?) async -> ContactOperationResult
    let createDirectConversation: (String) async -> String?

    @State private var selectedTab: SignedInTab = .messages
    @State private var navigationPath: [SignedInRoute] = []

    init(
        user: AuthUser,
        sessionStore: AppSessionStore,
        contactStore: ContactStore,
        conversationStore: IMConversationStore,
        conversationPresentationStore: IMConversationPresentationStore,
        conversationRuntimeStore: IMConversationRuntimeStore,
        probeManager: ProbeManager,
        fileTransferManager: FileTransferManager,
        imConnectionStatus: AuthManager.IMConnectionStatus,
        reloadProfile: @escaping () async -> Void,
        updateProfile: @escaping (String?, UserAvatarPreset?) async -> Bool,
        reconnectIMConnection: @escaping () async -> Void,
        logout: @escaping () async -> Void,
        loadSessions: @escaping () async -> Void,
        signOutCurrentDevice: @escaping () async -> Void,
        logoutAllSessions: @escaping () async -> Void,
        signOut: @escaping (UUID, Bool) async -> Void,
        reloadContacts: @escaping () async -> Void,
        reloadContactRequests: @escaping () async -> Void,
        loadBlockedUsers: @escaping () async -> Void,
        markIncomingContactRequestsSeen: @escaping () -> Void,
        sendContactRequest: @escaping (String, String, String) async -> ContactOperationResult,
        acceptContactRequest: @escaping (UUID, String) async -> ContactOperationResult,
        declineContactRequest: @escaping (UUID) async -> ContactOperationResult,
        cancelContactRequest: @escaping (UUID) async -> ContactOperationResult,
        updateContactRemark: @escaping (UUID, String) async -> ContactOperationResult,
        deleteContact: @escaping (UUID) async -> ContactOperationResult,
        blockUser: @escaping (UUID) async -> ContactOperationResult,
        unblockUser: @escaping (UUID) async -> ContactOperationResult,
        reportUser: @escaping (UUID, String, String?) async -> ContactOperationResult,
        createDirectConversation: @escaping (String) async -> String?
    ) {
        self.user = user
        self.sessionStore = sessionStore
        self.contactStore = contactStore
        self.conversationStore = conversationStore
        self.conversationPresentationStore = conversationPresentationStore
        self.conversationRuntimeStore = conversationRuntimeStore
        self.probeManager = probeManager
        self.fileTransferManager = fileTransferManager
        self.imConnectionStatus = imConnectionStatus
        self.reloadProfile = reloadProfile
        self.updateProfile = updateProfile
        self.reconnectIMConnection = reconnectIMConnection
        self.logout = logout
        self.loadSessions = loadSessions
        self.signOutCurrentDevice = signOutCurrentDevice
        self.logoutAllSessions = logoutAllSessions
        self.signOut = signOut
        self.reloadContacts = reloadContacts
        self.reloadContactRequests = reloadContactRequests
        self.loadBlockedUsers = loadBlockedUsers
        self.markIncomingContactRequestsSeen = markIncomingContactRequestsSeen
        self.sendContactRequest = sendContactRequest
        self.acceptContactRequest = acceptContactRequest
        self.declineContactRequest = declineContactRequest
        self.cancelContactRequest = cancelContactRequest
        self.updateContactRemark = updateContactRemark
        self.deleteContact = deleteContact
        self.blockUser = blockUser
        self.unblockUser = unblockUser
        self.reportUser = reportUser
        self.createDirectConversation = createDirectConversation
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TabView(selection: $selectedTab) {
                messagesRoot
                    .tabItem {
                        Label("消息", systemImage: "message")
                    }
                    .tag(SignedInTab.messages)
                    .badge(conversationStore.totalUnreadCount)
                    .accessibilityIdentifier("tab.messages")

                contactsRoot
                    .tabItem {
                        Label("通讯录", systemImage: "person.2")
                    }
                    .tag(SignedInTab.contacts)
                    .badge(contactStore.unseenIncomingContactRequestCount)
                    .accessibilityIdentifier("tab.contacts")

                meRoot
                    .tabItem {
                        Label("我的", systemImage: "person.crop.circle")
                    }
                    .tag(SignedInTab.me)
                    .accessibilityIdentifier("tab.me")
            }
            .navigationDestination(for: SignedInRoute.self) { route in
                destination(for: route)
            }
        }
    }

    private var messagesRoot: some View {
        IMConversationView(
            conversationStore: conversationStore,
            presentationStore: conversationPresentationStore,
            runtimeStore: conversationRuntimeStore,
            onOpenConversation: openConversation
        )
    }

    private var contactsRoot: some View {
        ContactsView(
            contactStore: contactStore,
            currentUserID: user.id,
            currentUserEmail: user.email,
            reloadContacts: reloadContacts,
            reloadContactRequests: reloadContactRequests,
            markIncomingContactRequestsSeen: markIncomingContactRequestsSeen,
            sendContactRequest: sendContactRequest,
            onOpenRequests: openContactRequests,
            onOpenBlockedUsers: { navigationPath.append(.blockedUsers) },
            onOpenContact: openContact
        )
    }

    private var meRoot: some View {
        MeView(
            sessionStore: sessionStore,
            user: user,
            imConnectionStatus: imConnectionStatus,
            reloadProfile: reloadProfile,
            updateProfile: updateProfile,
            logout: logout,
            openProfile: { navigationPath.append(.profile) },
            openSessions: { navigationPath.append(.sessions) },
            openPrivacy: { navigationPath.append(.privacy) },
            openFileTransfer: { navigationPath.append(.fileTransfer) },
            openNetworkStatus: { navigationPath.append(.networkStatus) },
            openDiagnostics: { navigationPath.append(.diagnostics) }
        )
    }

    @ViewBuilder
    private func destination(for route: SignedInRoute) -> some View {
        switch route {
        case .conversation(let conversationID):
            IMConversationDetailView(
                conversationStore: conversationStore,
                presentationStore: conversationPresentationStore,
                runtimeStore: conversationRuntimeStore,
                conversationID: conversationID
            )
        case .requests:
            NewContactRequestsView(
                contactStore: contactStore,
                currentUserID: user.id,
                showsCloseButton: false,
                markIncomingContactRequestsSeen: markIncomingContactRequestsSeen,
                reloadContactRequests: reloadContactRequests,
                sendContactRequest: sendContactRequest,
                acceptContactRequest: acceptContactRequest,
                declineContactRequest: declineContactRequest,
                cancelContactRequest: cancelContactRequest,
                createDirectConversation: createDirectConversation,
                onOpenConversation: openConversation
            )
        case .contact(let contactID):
            ContactDetailView(
                contactStore: contactStore,
                contactID: contactID,
                updateContactRemark: updateContactRemark,
                deleteContact: deleteContact,
                blockUser: blockUser,
                reportUser: reportUser,
                createDirectConversation: createDirectConversation,
                onOpenConversation: openConversation
            )
        case .blockedUsers:
            BlockedUsersSheet(
                contactStore: contactStore,
                conversationStore: conversationStore,
                currentUserID: user.id,
                currentUserEmail: user.email,
                showsCloseButton: false,
                loadBlockedUsers: loadBlockedUsers,
                unblockUser: unblockUser,
                sendContactRequest: sendContactRequest
            )
        case .profile:
            EditProfileSheet(
                initialEmail: activeUser.email,
                initialDisplayName: activeUser.displayName,
                initialAvatarPreset: activeUser.avatarPreset,
                isSubmitting: sessionStore.isUpdatingProfile,
                message: sessionStore.profileMessage,
                onSubmit: { displayName, avatarPreset in
                    await updateProfile(displayName, avatarPreset)
                }
            )
        case .sessions:
            SessionManagementView(
                sessionStore: sessionStore,
                loadSessions: loadSessions,
                signOutCurrentDevice: signOutCurrentDevice,
                logoutAllSessions: logoutAllSessions,
                signOut: signOut
            )
        case .privacy:
            PrivacySecurityView(
                openBlockedUsers: { navigationPath.append(.blockedUsers) }
            )
        case .fileTransfer:
            FileTransferView(fileTransferManager: fileTransferManager)
        case .networkStatus:
            NetworkStatusView(
                sessionStore: sessionStore,
                imConnectionStatus: imConnectionStatus,
                reconnectIMConnection: reconnectIMConnection
            )
        case .diagnostics:
            DiagnosticsView(
                probeManager: probeManager,
                conversationHealthSnapshot: conversationStore.healthSnapshot
            )
        }
    }

    private var activeUser: AuthUser {
        sessionStore.currentUser ?? user
    }

    private func openContactRequests() {
        navigationPath.append(.requests)
    }

    private func openContact(_ contactID: UUID) {
        navigationPath.append(.contact(contactID))
    }

    private func openConversation(_ conversationID: String) {
        selectedTab = .messages
        navigationPath.removeAll()
        navigationPath.append(.conversation(conversationID))
    }
}
