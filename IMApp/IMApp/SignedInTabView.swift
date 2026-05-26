import SwiftUI
import IMClientKit

enum SignedInTab: Hashable {
    case messages
    case contacts
    case me
}

enum MessageRoute: Hashable {
    case conversation(String)
}

enum ContactsRoute: Hashable {
    case requests
    case contact(UUID)
    case blockedUsers
}

enum MeRoute: Hashable {
    case profile
    case sessions
    case privacy
    case blockedUsers
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
    @State private var messagePath: [MessageRoute] = []
    @State private var contactsPath: [ContactsRoute] = []
    @State private var mePath: [MeRoute] = []

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
    }

    private var messagesRoot: some View {
        NavigationStack(path: $messagePath) {
            IMConversationView(
                conversationStore: conversationStore,
                presentationStore: conversationPresentationStore,
                runtimeStore: conversationRuntimeStore,
                onOpenConversation: openConversation
            )
            .navigationDestination(for: MessageRoute.self) { route in
                switch route {
                case .conversation(let conversationID):
                    IMConversationDetailView(
                        conversationStore: conversationStore,
                        presentationStore: conversationPresentationStore,
                        runtimeStore: conversationRuntimeStore,
                        conversationID: conversationID
                    )
                }
            }
        }
    }

    private var contactsRoot: some View {
        NavigationStack(path: $contactsPath) {
            ContactsView(
                contactStore: contactStore,
                currentUserID: user.id,
                currentUserEmail: user.email,
                reloadContacts: reloadContacts,
                reloadContactRequests: reloadContactRequests,
                markIncomingContactRequestsSeen: markIncomingContactRequestsSeen,
                sendContactRequest: sendContactRequest,
                onOpenRequests: openContactRequests,
                onOpenBlockedUsers: { contactsPath.append(.blockedUsers) },
                onOpenContact: openContact
            )
            .navigationDestination(for: ContactsRoute.self) { route in
                switch route {
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
                }
            }
        }
    }

    private var meRoot: some View {
        NavigationStack(path: $mePath) {
            MeView(
                sessionStore: sessionStore,
                user: user,
                imConnectionStatus: imConnectionStatus,
                reloadProfile: reloadProfile,
                updateProfile: updateProfile,
                logout: logout,
                openProfile: { mePath.append(.profile) },
                openSessions: { mePath.append(.sessions) },
                openPrivacy: { mePath.append(.privacy) },
                openFileTransfer: { mePath.append(.fileTransfer) },
                openNetworkStatus: { mePath.append(.networkStatus) },
                openDiagnostics: { mePath.append(.diagnostics) }
            )
            .navigationDestination(for: MeRoute.self) { route in
                switch route {
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
                        openBlockedUsers: { mePath.append(.blockedUsers) }
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
                case .fileTransfer:
                    FileTransferView(fileTransferManager: fileTransferManager)
                case .networkStatus:
                    NetworkStatusView(
                        sessionStore: sessionStore,
                        imConnectionStatus: imConnectionStatus,
                        reconnectIMConnection: reconnectIMConnection
                    )
                case .diagnostics:
                    DiagnosticsView(probeManager: probeManager)
                }
            }
        }
    }

    private var activeUser: AuthUser {
        sessionStore.currentUser ?? user
    }

    private func openContactRequests() {
        contactsPath.append(.requests)
    }

    private func openContact(_ contactID: UUID) {
        contactsPath.append(.contact(contactID))
    }

    private func openConversation(_ conversationID: String) {
        selectedTab = .messages
        messagePath.append(.conversation(conversationID))
    }
}
