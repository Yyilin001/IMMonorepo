import SwiftUI
import IMClientKit

struct SignedInTabView: View {
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject var sessionStore: AppSessionStore
    @ObservedObject var contactStore: ContactStore
    @ObservedObject var conversationStore: IMConversationStore

    let user: AuthUser

    @State private var navigationPath: [IMNavigationRoute] = []

    init(
        user: AuthUser,
        sessionStore: AppSessionStore,
        contactStore: ContactStore,
        conversationStore: IMConversationStore
    ) {
        self.user = user
        self.sessionStore = sessionStore
        self.contactStore = contactStore
        self.conversationStore = conversationStore
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TabView {
                HomeView(
                    probeManager: authManager.probeManager,
                    user: user
                )
                .tabItem {
                    Label("首页", systemImage: "house")
                }

                imTab

                contactsTab

                FileTransferView(fileTransferManager: authManager.fileTransferManager)
                    .tabItem {
                        Label("文件", systemImage: "arrow.up.arrow.down.circle")
                    }

                SessionManagementView()
                    .tabItem {
                        Label("设备", systemImage: "iphone.gen2")
                    }
            }
            .navigationDestination(for: IMNavigationRoute.self) { route in
                switch route {
                case .conversation(let conversationID):
                    IMConversationDetailView(
                        conversationStore: conversationStore,
                        presentationStore: authManager.conversationPresentationStore,
                        runtimeStore: authManager.conversationRuntimeStore,
                        conversationID: conversationID
                    )
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
                presentationStore: authManager.conversationPresentationStore,
                runtimeStore: authManager.conversationRuntimeStore,
                onOpenConversation: openConversation
            )
            .tabItem {
                Label("消息", systemImage: "message")
            }
            .badge(unreadCount)
        } else {
            IMConversationView(
                conversationStore: conversationStore,
                presentationStore: authManager.conversationPresentationStore,
                runtimeStore: authManager.conversationRuntimeStore,
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
            ContactsView(contactStore: contactStore, onOpenConversation: openConversation)
                .tabItem {
                    Label("通讯录", systemImage: "person.2")
                }
                .badge(pendingCount)
        } else {
            ContactsView(contactStore: contactStore, onOpenConversation: openConversation)
                .tabItem {
                    Label("通讯录", systemImage: "person.2")
                }
        }
    }

    private func openConversation(_ conversationID: String) {
        navigationPath.append(.conversation(conversationID))
    }
}
