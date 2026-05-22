import SwiftUI
import IMClientKit

enum AppRoute: Hashable {
    case conversation(String)
    case contactRequests
    case sessionManagement
    case fileTransferDetail
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
    let sendContactRequest: (String, String, String) async -> Bool
    let acceptContactRequest: (UUID, String) async -> Bool
    let declineContactRequest: (UUID) async -> Bool
    let cancelContactRequest: (UUID) async -> Bool
    let updateContactRemark: (UUID, String) async -> Bool
    let deleteContact: (UUID) async -> Bool
    let blockUser: (UUID) async -> Bool
    let unblockUser: (UUID) async -> Bool
    let createDirectConversation: (String) async -> String?

    @State private var navigationPath: [AppRoute] = []

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
        sendContactRequest: @escaping (String, String, String) async -> Bool,
        acceptContactRequest: @escaping (UUID, String) async -> Bool,
        declineContactRequest: @escaping (UUID) async -> Bool,
        cancelContactRequest: @escaping (UUID) async -> Bool,
        updateContactRemark: @escaping (UUID, String) async -> Bool,
        deleteContact: @escaping (UUID) async -> Bool,
        blockUser: @escaping (UUID) async -> Bool,
        unblockUser: @escaping (UUID) async -> Bool,
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
        self.createDirectConversation = createDirectConversation
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TabView {
                HomeView(
                    sessionStore: sessionStore,
                    probeManager: probeManager,
                    user: user,
                    imConnectionStatus: imConnectionStatus,
                    reloadProfile: reloadProfile,
                    updateProfile: updateProfile,
                    reconnectIMConnection: reconnectIMConnection,
                    logout: logout
                )
                .tabItem {
                    Label("首页", systemImage: "house")
                }

                imTab

                contactsTab

                FileTransferView(fileTransferManager: fileTransferManager)
                    .tabItem {
                        Label("文件", systemImage: "arrow.up.arrow.down.circle")
                    }

                SessionManagementView(
                    sessionStore: sessionStore,
                    loadSessions: loadSessions,
                    signOutCurrentDevice: signOutCurrentDevice,
                    logoutAllSessions: logoutAllSessions,
                    signOut: signOut
                )
                    .tabItem {
                        Label("设备", systemImage: "iphone.gen2")
                    }
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .conversation(let conversationID):
                    IMConversationDetailView(
                        conversationStore: conversationStore,
                        presentationStore: conversationPresentationStore,
                        runtimeStore: conversationRuntimeStore,
                        conversationID: conversationID
                    )
                case .contactRequests:
            NewContactRequestsView(
                contactStore: contactStore,
                currentUserID: user.id,
                markIncomingContactRequestsSeen: markIncomingContactRequestsSeen,
                reloadContactRequests: reloadContactRequests,
                acceptContactRequest: acceptContactRequest,
                declineContactRequest: declineContactRequest,
                cancelContactRequest: cancelContactRequest,
                createDirectConversation: createDirectConversation,
                onOpenConversation: openConversation
            )
                case .sessionManagement:
                    SessionManagementView(
                        sessionStore: sessionStore,
                        loadSessions: loadSessions,
                        signOutCurrentDevice: signOutCurrentDevice,
                        logoutAllSessions: logoutAllSessions,
                        signOut: signOut
                    )
                case .fileTransferDetail:
                    FileTransferView(fileTransferManager: fileTransferManager)
                }
            }
        }
    }

    @ViewBuilder
    private var imTab: some View {
        let unreadCount = conversationStore.totalUnreadCount

        if unreadCount > 0 {
            IMConversationView(
                conversationStore: conversationStore,
                presentationStore: conversationPresentationStore,
                runtimeStore: conversationRuntimeStore,
                onOpenConversation: openConversation
            )
            .tabItem {
                Label("消息", systemImage: "message")
            }
            .badge(unreadCount)
        } else {
            IMConversationView(
                conversationStore: conversationStore,
                presentationStore: conversationPresentationStore,
                runtimeStore: conversationRuntimeStore,
                onOpenConversation: openConversation
            )
            .tabItem {
                Label("消息", systemImage: "message")
            }
        }
    }

    @ViewBuilder
    private var contactsTab: some View {
        let pendingCount = contactStore.unseenIncomingContactRequestCount

        if pendingCount > 0 {
            ContactsView(
                contactStore: contactStore,
                currentUserID: user.id,
                reloadContacts: reloadContacts,
                reloadContactRequests: reloadContactRequests,
                loadBlockedUsers: loadBlockedUsers,
                markIncomingContactRequestsSeen: markIncomingContactRequestsSeen,
                sendContactRequest: sendContactRequest,
                acceptContactRequest: acceptContactRequest,
                declineContactRequest: declineContactRequest,
                cancelContactRequest: cancelContactRequest,
                updateContactRemark: updateContactRemark,
                deleteContact: deleteContact,
                blockUser: blockUser,
                unblockUser: unblockUser,
                createDirectConversation: createDirectConversation,
                onOpenConversation: openConversation
            )
                .tabItem {
                    Label("通讯录", systemImage: "person.2")
                }
                .badge(pendingCount)
        } else {
            ContactsView(
                contactStore: contactStore,
                currentUserID: user.id,
                reloadContacts: reloadContacts,
                reloadContactRequests: reloadContactRequests,
                loadBlockedUsers: loadBlockedUsers,
                markIncomingContactRequestsSeen: markIncomingContactRequestsSeen,
                sendContactRequest: sendContactRequest,
                acceptContactRequest: acceptContactRequest,
                declineContactRequest: declineContactRequest,
                cancelContactRequest: cancelContactRequest,
                updateContactRemark: updateContactRemark,
                deleteContact: deleteContact,
                blockUser: blockUser,
                unblockUser: unblockUser,
                createDirectConversation: createDirectConversation,
                onOpenConversation: openConversation
            )
                .tabItem {
                    Label("通讯录", systemImage: "person.2")
                }
        }
    }

    private func openConversation(_ conversationID: String) {
        navigationPath.append(.conversation(conversationID))
    }
}
