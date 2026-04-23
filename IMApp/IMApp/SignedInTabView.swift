import SwiftUI
import IMClientKit

struct SignedInTabView: View {
    @EnvironmentObject private var authManager: AuthManager

    let user: AuthUser

    @State private var navigationPath: [IMNavigationRoute] = []

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

                ContactsView(onOpenConversation: openConversation)
                    .tabItem {
                        Label("通讯录", systemImage: "person.2")
                    }

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
                        conversationStore: authManager.imConversationStore,
                        conversationID: conversationID
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var imTab: some View {
        let unreadCount = authManager.imConversationStore.totalUnreadCount

        if unreadCount > 0 {
            IMConversationView(
                conversationStore: authManager.imConversationStore,
                onOpenConversation: openConversation
            )
            .tabItem {
                Label("消息", systemImage: "message")
            }
            .badge(unreadCount)
        } else {
            IMConversationView(
                conversationStore: authManager.imConversationStore,
                onOpenConversation: openConversation
            )
            .tabItem {
                Label("消息", systemImage: "message")
            }
        }
    }

    private func openConversation(_ conversationID: String) {
        navigationPath.append(.conversation(conversationID))
    }
}
