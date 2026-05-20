import SwiftUI
import IMClientKit
import Combine
import QuickLook
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

enum IMNavigationRoute: Hashable {
    case conversation(String)
}

enum IMConversationDestructiveAction: Identifiable {
    case clear
    case delete

    var id: String {
        switch self {
        case .clear:
            return "clear"
        case .delete:
            return "delete"
        }
    }
}

enum IMSelectionActionState: Equatable {
    case idle
    case forwarding
    case favoriting
    case deleting
}

enum IMConversationListFilter: String, CaseIterable, Identifiable {
    case all
    case groups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .groups:
            return "群聊"
        }
    }

    var conversationKind: IMConversationKind? {
        switch self {
        case .all:
            return nil
        case .groups:
            return .group
        }
    }
}

struct IMConversationView: View {
    @ObservedObject var conversationStore: IMConversationStore
    @ObservedObject var presentationStore: IMConversationPresentationStore
    @ObservedObject var runtimeStore: IMConversationRuntimeStore

    let onOpenConversation: (String) -> Void

    @State var isPresentingCreateConversation = false
    @State var isPresentingFavorites = false
    @State var conversationListFilter: IMConversationListFilter = .all

    var body: some View {
        List {
            Section {
                IMConnectionSummaryCard(
                    title: connectionTitle,
                    message: connectionMessage,
                    icon: connectionIcon,
                    tint: connectionColor
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                if let message = conversationStore.statusMessage, !message.isEmpty {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                Picker("会话类型", selection: $conversationListFilter) {
                    ForEach(IMConversationListFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                if conversationStore.filteredConversations.isEmpty {
                    IMConversationEmptyState {
                        isPresentingCreateConversation = true
                    }
                    .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
                    .listRowBackground(Color.clear)
                } else {
                    Button {
                        isPresentingCreateConversation = true
                    } label: {
                        Label("新建私聊或群聊", systemImage: "square.and.pencil")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

                    ForEach(conversationStore.filteredConversations) { conversation in
                        Button {
                            onOpenConversation(conversation.id)
                        } label: {
                            IMConversationRow(
                                conversation: conversation,
                                identity: presentationStore.conversationIdentityPresentation(for: conversation),
                                isActive: conversation.id == conversationStore.selectedConversationID
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if conversationStore.isLoadingMoreConversationSummaries {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    } else if conversationStore.hasMoreConversationSummaries {
                        Button {
                            loadMoreHistoricalConversations()
                        } label: {
                            Label("加载更多历史会话", systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(conversationStore.isLoadingMoreConversationSummaries)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                            .onAppear {
                                loadMoreHistoricalConversations()
                            }
                    }
                }
            } header: {
                HStack {
                    Text("会话")

                    Spacer()

                    if conversationStore.isLoadingConversations {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        isPresentingCreateConversation = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("新建会话")
                }
            } footer: {
                if !conversationStore.conversations.isEmpty {
                    Text("下拉可刷新会话列表，点进会话后再查看历史消息和发送内容。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("消息")
        .background(Color(.systemGroupedBackground))
        .searchable(
            text: Binding(
                get: { conversationStore.searchText },
                set: { conversationStore.setConversationSearchText($0) }
            ),
            prompt: "搜索会话、公告、预览"
        )
        .task {
            if conversationStore.conversations.isEmpty {
                await runtimeStore.reloadConversations(
                    force: true,
                    kind: conversationListFilter.conversationKind
                )
            }
        }
        .refreshable {
            await runtimeStore.reloadConversations(
                force: true,
                kind: conversationListFilter.conversationKind
            )
        }
        .onChange(of: conversationListFilter) { _, newValue in
            Task {
                await runtimeStore.reloadConversations(
                    force: true,
                    kind: newValue.conversationKind
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task {
                        await runtimeStore.reloadConversations(
                            force: true,
                            kind: conversationListFilter.conversationKind
                        )
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(conversationStore.isLoadingConversations)

                Button {
                    isPresentingCreateConversation = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }

                Button {
                    isPresentingFavorites = true
                } label: {
                    Image(systemName: "star.fill")
                }
                .accessibilityLabel("我的收藏")
            }
        }
        .sheet(isPresented: $isPresentingCreateConversation) {
            NavigationStack {
                IMCreateConversationSheet(conversationStore: conversationStore)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isPresentingFavorites) {
            NavigationStack {
                IMFavoritesSheet(
                    conversationStore: conversationStore,
                    runtimeStore: runtimeStore,
                    onSelect: { conversationID, messageID in
                        isPresentingFavorites = false
                        onOpenConversation(conversationID)
                        Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            await runtimeStore.jumpToMessage(messageID, in: conversationID)
                        }
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
    }

    func loadMoreHistoricalConversations() {
        let anchorConversationID = conversationStore.conversationSummaryPaginationAnchorID
        Task {
            await runtimeStore.loadMoreConversationSummariesIfNeeded(
                anchorConversationID: anchorConversationID,
                kind: conversationListFilter.conversationKind
            )
        }
    }

    var connectionTitle: String {
        switch presentationStore.imConnectionStatus {
        case .disconnected:
            return "IM 长连接未建立"
        case .connecting:
            return "IM 正在连接"
        case .connected:
            return "IM 长连接在线"
        case .failed:
            return "IM 长连接异常"
        }
    }

    var connectionMessage: String {
        switch presentationStore.imConnectionStatus {
        case .disconnected:
            return "当前只有 HTTP 登录态，实时消息不会到达，新发送消息会先进入待发送队列。"
        case .connecting:
            return "正在建立 TCP 握手，连接完成后会进入实时收发状态。"
        case .connected:
            return "会话列表和历史消息通过 HTTP 拉取，实时新消息通过 TCP 同步。"
        case .failed(let message):
            return message
        }
    }

    var connectionIcon: String {
        switch presentationStore.imConnectionStatus {
        case .disconnected:
            return "bolt.slash"
        case .connecting:
            return "arrow.trianglehead.2.clockwise"
        case .connected:
            return "bolt.horizontal.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    var connectionColor: Color {
        switch presentationStore.imConnectionStatus {
        case .disconnected:
            return .secondary
        case .connecting:
            return .blue
        case .connected:
            return .green
        case .failed:
            return .orange
        }
    }
}

struct IMConversationDetailView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var conversationStore: IMConversationStore
    @ObservedObject var presentationStore: IMConversationPresentationStore
    @ObservedObject var runtimeStore: IMConversationRuntimeStore

    let conversationID: String

    @State var composerText = ""
    @State var isPresentingAddMembers = false
    @State var isPresentingManageMembers = false
    @State var isPresentingLeaveConfirmation = false
    @State var isPresentingRenameGroup = false
    @State var isPresentingEditMetadata = false
    @State var isPresentingInvites = false
    @State var isPresentingMemberNickname = false
    @State var isPresentingSearch = false
    @State var isPresentingMediaImporter = false
    @State var isPresentingBatchSender = false
    @State var isPresentingForwardPicker = false
    @State var isSelectionMode = false
    @State var selectedMessageIDs: Set<String> = []
    @State var pendingForwardMessageIDs: [String] = []
    @State var favoritedMessageIDs: Set<String> = []
    @State var selectionActionState: IMSelectionActionState = .idle
    @State var destructiveAction: IMConversationDestructiveAction?
    @State var replyTarget: IMConversationMessage?
    @State var editingTarget: IMConversationMessage?
    @State var highlightedMessageID: String?
    @State var mediaDownloadStates: [String: IMMediaDownloadState] = [:]
    @State var mediaDownloadTasks: [String: Task<Void, Never>] = [:]
    @State var previewedMediaItem: IMDownloadedMediaPreviewItem?

    var body: some View {
        detailContent
    }

    var detailContent: some View {
        ScrollViewReader { proxy in
            decoratedDetailView(proxy: proxy)
        }
    }

    func decoratedDetailView(proxy: ScrollViewProxy) -> some View {
        applyingDraftStateHandlers(
            to: applyingPresentationModifiers(
                to: applyingScrollStateHandlers(
                    to: detailBaseView,
                    proxy: proxy
                )
            )
        )
    }

    var detailBaseView: some View {
        detailScrollView
            .navigationTitle(conversationIdentity.title)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: conversationID) {
                await runtimeStore.openConversation(conversationID)
                await loadConversationFavoriteCache()
            }
            .onDisappear {
                pauseAllMediaDownloads()
                resetSelection()
            }
            .toolbar {
                detailToolbarContent
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    selectionToolbar
                } else {
                    composerBar
                }
            }
    }
}
