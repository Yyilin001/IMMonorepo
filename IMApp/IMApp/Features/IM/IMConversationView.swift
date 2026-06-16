import SwiftUI
import IMClientKit
import OSLog
import QuickLook
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

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

struct IMConversationListPendingAction: Identifiable {
    let id = UUID()
    let conversationID: String
    let title: String
    let action: IMConversationRowAction

    var confirmationMessage: String {
        switch action {
        case .clearHistory:
            return "清空「\(title)」的聊天记录？"
        case .delete:
            return "删除「\(title)」会话？"
        case .pin, .mute, .markRead, .markUnread:
            return ""
        }
    }

    var confirmationButtonTitle: String {
        switch action {
        case .clearHistory:
            return "清空聊天记录"
        case .delete:
            return "删除会话"
        case .pin, .mute, .markRead, .markUnread:
            return "确认"
        }
    }
}

enum IMSelectionActionState: Equatable {
    case idle
    case forwarding
    case favoriting
    case deleting
}

struct IMConversationListObservedStoreMetadata: Equatable {
    let statusMessage: String?
    let isLoadingConversations: Bool
    let isLoadingMoreConversationSummaries: Bool
    let hasMoreConversationSummaries: Bool
}

enum IMConversationRelationshipActionKey: Hashable, Sendable {
    case sendRequest(String)
    case accept(String)
    case decline(String)
    case cancel(String)
    case block(UUID)
    case unblock(UUID)
    case report(UUID)
}

enum IMConversationListFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case unread
    case groups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .unread:
            return "未读"
        case .groups:
            return "群聊"
        }
    }

    var conversationKind: IMConversationKind? {
        switch self {
        case .all, .unread:
            return nil
        case .groups:
            return .group
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .all:
            return "messages.filter.all"
        case .unread:
            return "messages.filter.unread"
        case .groups:
            return "messages.filter.groups"
        }
    }
}

struct IMConversationView: View {
    let conversationStore: IMConversationStore
    let presentationStore: IMConversationPresentationStore
    let runtimeStore: IMConversationRuntimeStore
    let snapshotStore: IMConversationSnapshotStore

    let onOpenConversation: (String) -> Void

    @State var isPresentingCreateConversation = false
    @State var isPresentingFavorites = false
    @State var conversationListFilter: IMConversationListFilter = .all
    @State var pendingListAction: IMConversationListPendingAction?
    @State var observedConversationListSnapshot = IMConversationListSnapshot(
        generation: 0,
        filter: .all,
        rows: []
    )
    @State var observedConversationListRevision: UInt64 = 0
    @State var snapshotCommitPipeline = IMConversationSnapshotCommitPipeline()

    var body: some View {
        conversationList
    }

    var conversationList: some View {
        List {
            connectionStatusSection
            storeStatusSection
            conversationsSection
        }
        .listStyle(.insetGrouped)
        .onAppear {
            refreshConversationListSnapshot(invalidation: .appear)
        }
        .task {
            await observeConversationListSnapshotEvents()
        }
        .onChange(of: conversationStore.conversationMutationGeneration) { _, generation in
            refreshConversationListSnapshot(invalidation: .conversationGenerationChanged(generation))
        }
        .onChange(of: conversationStore.selectedConversationID) { _, selectedConversationID in
            refreshConversationListSnapshot(invalidation: .selectedConversationChanged(selectedConversationID))
        }
        .onChange(of: conversationStore.searchText) { _, searchText in
            refreshConversationListSnapshot(invalidation: .searchChanged(searchText))
        }
        .onChange(of: conversationListFilter) { _, filter in
            refreshConversationListSnapshot(invalidation: .filterChanged(filter))
        }
        .onChange(of: conversationListObservedStoreMetadata) { _, _ in
            refreshConversationListSnapshot(invalidation: .listMetadataChanged)
        }
        .navigationTitle("消息")
        .background(AppSurface.groupedBackground)
        .searchable(
            text: Binding(
                get: { conversationStore.searchText },
                set: { conversationStore.setConversationSearchText($0) }
            ),
            prompt: "搜索会话、公告、预览"
        )
        .task {
            if conversationListSnapshot.generation == 0,
               conversationListSnapshot.rows.isEmpty {
                await reloadConversationsForCurrentFilter()
            }
        }
        .refreshable {
            await reloadConversationsForCurrentFilter()
        }
        .onDisappear {
            Task { @MainActor in
                await snapshotCommitPipeline.cancelPending(in: snapshotStore)
            }
        }
        .onChange(of: conversationListFilter) { _, newValue in
            Task {
                await reloadConversations(for: newValue)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task {
                        await reloadConversationsForCurrentFilter()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(conversationListSnapshot.isLoadingConversations)
                .accessibilityIdentifier("messages.refreshButton")

                Button {
                    isPresentingCreateConversation = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityIdentifier("messages.createConversationButton")

                Button {
                    isPresentingFavorites = true
                } label: {
                    Image(systemName: "star.fill")
                }
                .accessibilityLabel("我的收藏")
                .accessibilityIdentifier("messages.favoritesButton")
            }
        }
        .sheet(isPresented: $isPresentingCreateConversation) {
            NavigationStack {
                IMCreateConversationSheet(
                    conversationStore: conversationStore,
                    runtimeStore: runtimeStore
                )
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
        .confirmationDialog(
            pendingListAction?.confirmationMessage ?? "",
            isPresented: pendingListActionIsPresented,
            titleVisibility: .visible
        ) {
            if let pendingListAction {
                Button(pendingListAction.confirmationButtonTitle, role: .destructive) {
                    Task {
                        await performConfirmedConversationAction(pendingListAction)
                    }
                }
            }
            Button("取消", role: .cancel) { }
        }
    }

    var pendingListActionIsPresented: Binding<Bool> {
        Binding(
            get: { pendingListAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingListAction = nil
                }
            }
        )
    }

    @ViewBuilder
    var connectionStatusSection: some View {
        if presentationStore.imConnectionStatus != .connected {
            Section {
                AppStatusBanner(
                    message: connectionMessage,
                    tone: connectionBannerTone,
                    systemImage: connectionIcon
                )
                .accessibilityIdentifier("messages.connectionStatus")
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    var storeStatusSection: some View {
        if let message = conversationListSnapshot.statusMessage, !message.isEmpty {
            Section {
                AppStatusBanner(message: message, tone: .info)
                    .accessibilityIdentifier("messages.status")
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }
        }
    }

    var conversationsSection: some View {
        Section {
            conversationFilterPicker
                .pickerStyle(.segmented)
                .accessibilityIdentifier("messages.filterPicker")
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

            if conversationListSnapshot.rows.isEmpty {
                conversationEmptyState
                    .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
                    .listRowBackground(Color.clear)
            } else {
                conversationRows
                olderConversationLoader
            }
        } header: {
            AppSectionHeader(
                title: "最近会话",
                detail: conversationListSnapshot.isLoadingConversations ? "同步中" : conversationCountText
            )
        }
    }

    var conversationRows: some View {
        ForEach(conversationListSnapshot.rows) { snapshot in
            IMConversationRowButton(
                snapshot: snapshot,
                isActive: snapshot.isActive,
                onOpen: {
                    onOpenConversation(snapshot.id)
                },
                onAction: { action in
                    handleConversationRowAction(action, for: snapshot)
                }
            )
        }
    }

    @ViewBuilder
    var olderConversationLoader: some View {
        if conversationListSnapshot.isLoadingMoreConversationSummaries {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        } else if conversationListSnapshot.hasMoreConversationSummaries {
            Button {
                loadMoreOlderConversations()
            } label: {
                Label("加载更多历史会话", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(conversationListSnapshot.isLoadingMoreConversationSummaries)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .onAppear {
                loadMoreOlderConversations()
            }
        }
    }

    func loadMoreOlderConversations() {
        let anchorConversationID = conversationStore.conversationSummaryPaginationAnchorID
        Task {
            await runtimeStore.loadMoreConversationSummariesIfNeeded(
                anchorConversationID: anchorConversationID,
                kind: conversationListFilter.conversationKind
            )
        }
    }

    func reloadConversationsForCurrentFilter() async {
        await reloadConversations(for: conversationListFilter)
    }

    func reloadConversations(for filter: IMConversationListFilter) async {
        await runtimeStore.reloadConversations(
            force: true,
            kind: filter.conversationKind
        )
    }

    var conversationFilterPicker: some View {
        Picker("会话类型", selection: $conversationListFilter) {
            Text(IMConversationListFilter.all.title)
                .tag(IMConversationListFilter.all)
                .accessibilityIdentifier(IMConversationListFilter.all.accessibilityIdentifier)
            Text(IMConversationListFilter.unread.title)
                .tag(IMConversationListFilter.unread)
                .accessibilityIdentifier(IMConversationListFilter.unread.accessibilityIdentifier)
            Text(IMConversationListFilter.groups.title)
                .tag(IMConversationListFilter.groups)
                .accessibilityIdentifier(IMConversationListFilter.groups.accessibilityIdentifier)
        }
    }

    var conversationListSnapshot: IMConversationListSnapshot {
        observedConversationListSnapshot
    }

    @MainActor
    func observeConversationListSnapshotEvents() async {
        let currentEvent = await snapshotStore.currentListSnapshotEvent()
        observedConversationListSnapshot = currentEvent.snapshot
        observedConversationListRevision = currentEvent.revision

        for await event in await snapshotStore.listSnapshotEvents() {
            observedConversationListSnapshot = event.snapshot
            observedConversationListRevision = event.revision
            logConversationListSnapshotEvent(event)
        }
    }

    func refreshConversationListSnapshot(invalidation: IMConversationSnapshotInvalidation) {
        Task { @MainActor in
            await snapshotCommitPipeline.scheduleListAndChatCommit(
                IMConversationSnapshotCommitEvent(
                    invalidation,
                    list: IMConversationListSnapshotCommitPlan(filter: conversationListFilter),
                    chatPages: selectedChatPageSnapshotCommitRequests
                ),
                from: conversationStore,
                to: snapshotStore,
                identityForConversation: { conversation in
                    presentationStore.conversationIdentityPresentation(for: conversation)
                },
                didCommit: { execution in
                    let listCommit = execution.batchCommit.list ?? IMConversationSnapshotCommitResult(
                        didCommit: false,
                        revision: observedConversationListRevision
                    )
                    logConversationListSnapshot(
                        reason: execution.plan.reasonSummary,
                        commit: listCommit,
                        snapshot: execution.listSnapshot ?? conversationListSnapshot
                    )
                    logSelectedChatSnapshotCommit(
                        reason: execution.plan.reasonSummary,
                        execution: execution
                    )
                }
            )
        }
    }

    var selectedChatPageSnapshotCommitRequests: [IMChatPageSnapshotCommitRequest] {
        guard let conversationID = conversationStore.selectedConversationID else {
            return []
        }
        return [
            IMChatPageSnapshotCommitRequest(
                conversationID: conversationID,
                currentUserID: runtimeStore.currentUserID,
                blockedUserIDs: runtimeStore.blockedUserIDs
            )
        ]
    }

    func logConversationListSnapshotEvent(_ event: IMConversationListSnapshotEvent) {
        let head = event.snapshot.rows.prefix(5).map { row in
            "\(row.id)|unread=\(row.unreadCount)|preview=\(row.primaryPreviewText)|updated=\(row.updatedAt.timeIntervalSince1970)|pending=\(row.pendingMessageCount)|messages=\(row.messageCount)|timeline=\(row.timelineItemCount)"
        }.joined(separator: " || ")
        IMAppLog.imUI.debug(
            "Conversation list snapshot event revision=\(event.revision, privacy: .public) generation=\(event.snapshot.generation, privacy: .public) filter=\(event.snapshot.filter.rawValue, privacy: .public) displayedCount=\(event.snapshot.rows.count, privacy: .public) head=\(head, privacy: .public)"
        )
    }

    func logConversationListSnapshot(
        reason: String,
        commit: IMConversationSnapshotCommitResult,
        snapshot: IMConversationListSnapshot
    ) {
        let head = snapshot.rows.prefix(5).map { row in
            "\(row.id)|unread=\(row.unreadCount)|preview=\(row.primaryPreviewText)|updated=\(row.updatedAt.timeIntervalSince1970)|pending=\(row.pendingMessageCount)|messages=\(row.messageCount)|timeline=\(row.timelineItemCount)"
        }.joined(separator: " || ")
        let activeConversationID = snapshot.rows.first(where: \.isActive)?.id ?? "nil"
        IMAppLog.imUI.debug(
            "Conversation list snapshot reason=\(reason, privacy: .public) committed=\(commit.didCommit, privacy: .public) revision=\(commit.revision, privacy: .public) observedRevision=\(observedConversationListRevision, privacy: .public) generation=\(snapshot.generation, privacy: .public) filter=\(snapshot.filter.rawValue, privacy: .public) displayedCount=\(snapshot.rows.count, privacy: .public) active=\(activeConversationID, privacy: .public) head=\(head, privacy: .public)"
        )
    }

    func logSelectedChatSnapshotCommit(
        reason: String,
        execution: IMConversationSnapshotCommitExecution
    ) {
        guard let selectedConversationID = conversationStore.selectedConversationID,
              let commit = execution.batchCommit.chatPages[selectedConversationID]
        else {
            return
        }
        let snapshot = execution.chatPageSnapshots[selectedConversationID] ?? .empty(conversationID: selectedConversationID)
        IMAppLog.imUI.debug(
            "Conversation selected chat snapshot reason=\(reason, privacy: .public) committed=\(commit.didCommit, privacy: .public) revision=\(commit.revision, privacy: .public) conversationID=\(selectedConversationID, privacy: .public) generation=\(snapshot.generation, privacy: .public) latestID=\(snapshot.latestItemID ?? "nil", privacy: .public)"
        )
    }

    var conversationCountText: String? {
        guard !conversationListSnapshot.rows.isEmpty else {
            return nil
        }
        return "\(conversationListSnapshot.rows.count) 个"
    }

    var conversationListObservedStoreMetadata: IMConversationListObservedStoreMetadata {
        IMConversationListObservedStoreMetadata(
            statusMessage: conversationStore.statusMessage,
            isLoadingConversations: conversationStore.isLoadingConversations,
            isLoadingMoreConversationSummaries: conversationStore.isLoadingMoreConversationSummaries,
            hasMoreConversationSummaries: conversationStore.hasMoreConversationSummaries
        )
    }

    @ViewBuilder
    var conversationEmptyState: some View {
        if !conversationListSnapshot.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AppEmptyState(
                title: "没有找到会话",
                message: "当前搜索没有匹配的联系人、群名或消息预览。",
                systemImage: "magnifyingglass",
                actionTitle: "清除搜索",
                actionSystemImage: "xmark.circle",
                action: {
                    conversationStore.setConversationSearchText("")
                }
            )
        } else if conversationListFilter == .unread {
            AppEmptyState(
                title: "没有未读消息",
                message: "新的未读消息会显示在这里。",
                systemImage: "checkmark.message"
            )
        } else {
            IMConversationEmptyState {
                isPresentingCreateConversation = true
            }
        }
    }

    func handleConversationRowAction(_ action: IMConversationRowAction, for snapshot: IMConversationRowSnapshot) {
        switch action {
        case .pin:
            Task {
                _ = await runtimeStore.updateConversationPreferences(
                    snapshot.id,
                    isPinned: !snapshot.isPinned
                )
            }
        case .mute:
            Task {
                _ = await runtimeStore.updateConversationPreferences(
                    snapshot.id,
                    isMuted: !snapshot.isMuted
                )
            }
        case .markRead:
            Task {
                await runtimeStore.markConversationRead(snapshot.id)
            }
        case .markUnread:
            Task {
                await runtimeStore.markConversationUnread(snapshot.id)
            }
        case .clearHistory, .delete:
            pendingListAction = IMConversationListPendingAction(
                conversationID: snapshot.id,
                title: snapshot.title,
                action: action
            )
        }
    }

    func performConfirmedConversationAction(_ pendingAction: IMConversationListPendingAction) async {
        switch pendingAction.action {
        case .clearHistory:
            _ = await runtimeStore.clearConversationForSelf(pendingAction.conversationID)
        case .delete:
            _ = await runtimeStore.deleteConversationForSelf(pendingAction.conversationID)
        case .pin, .mute, .markRead, .markUnread:
            break
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

    var connectionBannerTone: AppStatusBanner.Tone {
        switch presentationStore.imConnectionStatus {
        case .disconnected:
            return .warning
        case .connecting:
            return .info
        case .connected:
            return .success
        case .failed:
            return .error
        }
    }
}

struct IMConversationDetailView: View {
    @Environment(\.dismiss) var dismiss
    let conversationStore: IMConversationStore
    let presentationStore: IMConversationPresentationStore
    let runtimeStore: IMConversationRuntimeStore
    let snapshotStore: IMConversationSnapshotStore

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
    @State var isPresentingGroupSettings = false
    @State var isPresentingForwardPicker = false
    @State var isSelectionMode = false
    @State var selectedMessageIDs: Set<String> = []
    @State var pendingForwardMessageIDs: [String] = []
    @State var favoritedMessageIDs: Set<String> = []
    @State var selectionActionState: IMSelectionActionState = .idle
    @State var destructiveAction: IMConversationDestructiveAction?
    @State var replyTarget: IMChatReplyTargetSnapshot?
    @State var editingTarget: IMChatEditingTargetSnapshot?
    @State var highlightedMessageID: String?
    /// Row anchor captured before loading older history and consumed after snapshot commit.
    @State var pendingHistoryScrollAnchor: IMChatScrollAnchorSnapshot?
    /// Programmatic scroll position used for bottom jumps and content-offset restoration.
    @State var detailScrollPosition = ScrollPosition(idType: String.self, edge: .bottom)
    /// Latest scroll content offset reported by SwiftUI scroll geometry.
    @State var detailScrollContentOffsetY = 0.0
    /// Visible timeline row offsets keyed by snapshot row id.
    @State var timelineRowOffsetsFromTop: [String: Double] = [:]
    @State var isNearBottom = true
    @State var unseenNewMessageCount = 0
    @State var lastObservedMessageID: String?
    @State var mediaDownloadStates: [String: IMMediaDownloadState] = [:]
    @State var mediaDownloadTasks: [String: Task<Void, Never>] = [:]
    @State var previewedMediaItem: IMDownloadedMediaPreviewItem?
    @State var runningRelationshipActions: Set<IMConversationRelationshipActionKey> = []
    @State var observedChatPageSnapshot: IMChatPageSnapshot?
    @State var observedChatPageRevision: UInt64 = 0
    @State var snapshotCommitPipeline = IMConversationSnapshotCommitPipeline()

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
                    to: detailBaseView
                        .overlay(alignment: .bottomTrailing) {
                            ConversationNewMessagePill(
                                unseenCount: unseenNewMessageCount,
                                showsJumpOnly: !isNearBottom && unseenNewMessageCount == 0,
                                onTap: {
                                    Task {
                                        await scrollToLatestMessage(proxy: proxy, animated: true)
                                        unseenNewMessageCount = 0
                                        isNearBottom = true
                                    }
                                }
                            )
                            .padding(.trailing, 16)
                            .padding(.bottom, 92)
                        },
                    proxy: proxy
                )
            )
        )
    }

    var detailBaseView: some View {
        detailScrollView
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                refreshChatPageSnapshot(invalidation: .appear)
            }
            .task(id: conversationID) {
                await observeChatPageSnapshotEvents()
            }
            .task(id: conversationID) {
                refreshChatPageSnapshot(invalidation: .task(conversationID))
                await runtimeStore.openConversation(conversationID)
                await loadConversationFavoriteCache()
                refreshChatPageSnapshot(invalidation: .opened(conversationID))
            }
            .onDisappear {
                Task { @MainActor in
                    await snapshotCommitPipeline.cancelPending(in: snapshotStore)
                }
                pauseAllMediaDownloads()
                resetSelection()
                runningRelationshipActions.removeAll()
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
