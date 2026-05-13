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

private enum IMConversationDestructiveAction: Identifiable {
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

private enum IMSelectionActionState: Equatable {
    case idle
    case forwarding
    case favoriting
    case deleting
}

private enum IMConversationListFilter: String, CaseIterable, Identifiable {
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

    @State private var isPresentingCreateConversation = false
    @State private var isPresentingFavorites = false
    @State private var conversationListFilter: IMConversationListFilter = .all

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

    private func loadMoreHistoricalConversations() {
        let anchorConversationID = conversationStore.conversationSummaryPaginationAnchorID
        Task {
            await runtimeStore.loadMoreConversationSummariesIfNeeded(
                anchorConversationID: anchorConversationID,
                kind: conversationListFilter.conversationKind
            )
        }
    }

    private var connectionTitle: String {
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

    private var connectionMessage: String {
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

    private var connectionIcon: String {
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

    private var connectionColor: Color {
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
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var conversationStore: IMConversationStore
    @ObservedObject var presentationStore: IMConversationPresentationStore
    @ObservedObject var runtimeStore: IMConversationRuntimeStore

    let conversationID: String

    @State private var composerText = ""
    @State private var isPresentingAddMembers = false
    @State private var isPresentingManageMembers = false
    @State private var isPresentingLeaveConfirmation = false
    @State private var isPresentingRenameGroup = false
    @State private var isPresentingEditMetadata = false
    @State private var isPresentingInvites = false
    @State private var isPresentingMemberNickname = false
    @State private var isPresentingSearch = false
    @State private var isPresentingMediaImporter = false
    @State private var isPresentingBatchSender = false
    @State private var isPresentingForwardPicker = false
    @State private var isSelectionMode = false
    @State private var selectedMessageIDs: Set<String> = []
    @State private var pendingForwardMessageIDs: [String] = []
    @State private var favoritedMessageIDs: Set<String> = []
    @State private var selectionActionState: IMSelectionActionState = .idle
    @State private var destructiveAction: IMConversationDestructiveAction?
    @State private var replyTarget: IMConversationMessage?
    @State private var editingTarget: IMConversationMessage?
    @State private var highlightedMessageID: String?
    @State private var mediaDownloadStates: [String: IMMediaDownloadState] = [:]
    @State private var mediaDownloadTasks: [String: Task<Void, Never>] = [:]
    @State private var previewedMediaItem: IMDownloadedMediaPreviewItem?

    var body: some View {
        detailContent
    }

    private var detailContent: some View {
        ScrollViewReader { proxy in
            decoratedDetailView(proxy: proxy)
        }
    }

    private func decoratedDetailView(proxy: ScrollViewProxy) -> some View {
        applyingDraftStateHandlers(
            to: applyingPresentationModifiers(
                to: applyingScrollStateHandlers(
                    to: detailBaseView,
                    proxy: proxy
                )
            )
        )
    }

    private var detailBaseView: some View {
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

    private var detailScrollView: some View {
        ScrollView {
            detailMessageStack
        }
        .defaultScrollAnchor(.bottom)
        .background(Color(.systemGroupedBackground))
    }

    private var detailMessageStack: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            conversationSummaryCard

            if queueSummary.hasPendingWork {
                IMConversationQueueBanner(
                    summary: queueSummary,
                    isFlushing: runtimeStore.isFlushingQueuedTextMessages
                )
            }

            if let message = conversationStore.statusMessage, !message.isEmpty {
                IMInlineStatusBanner(message: message)
            }

            detailMessagesContent
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var detailMessagesContent: some View {
        if shouldShowLoadingState {
            ProgressView("正在拉取消息…")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
        } else if messages.isEmpty {
            IMDetailEmptyState()
        } else {
            if conversation?.hasMoreHistory == true {
                Button {
                    conversationStore.openConversation(id: conversationID)
                    Task {
                        await runtimeStore.loadOlderMessages()
                    }
                } label: {
                    Label("加载更早消息", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(conversationStore.isLoadingMessages)
            }

            ForEach(messages) { message in
                detailMessageRow(message)
                    .id(message.id)
            }
        }
    }

    private func detailMessageRow(_ message: IMConversationMessage) -> some View {
        let mediaAsset = message.mediaAsset
        let selectableID = selectableMessageID(for: message)
        return IMMessageBubble(
            message: message,
            replyReference: message.resolvedReplyReference(in: messages),
            isHighlighted: highlightedMessageID == message.id,
            isSelectionMode: isSelectionMode,
            isSelected: selectableID.map(selectedMessageIDs.contains) ?? false,
            canSelect: selectableID != nil,
            canRetry: conversationStore.isRetryableFailure(message),
            canCancel: message.canCancelQueuedSend,
            canReply: message.canReply,
            canRecall: message.canRecall,
            canEdit: message.canEdit,
            canReact: message.canReact,
            isFavorited: selectableID.map(favoritedMessageIDs.contains) ?? false,
            mediaDownloadState: resolvedMediaDownloadState(for: message),
            deliveryOverrideText: deliveryOverrideText(for: message),
            currentUserID: runtimeStore.currentUserID,
            onToggleSelection: {
                guard let selectableID else {
                    return
                }
                toggleSelectedMessage(selectableID)
            },
            onEnterSelection: {
                guard let selectableID else {
                    return
                }
                isSelectionMode = true
                selectedMessageIDs.insert(selectableID)
            },
            onJumpToReplyReference: {
                guard case .reply(let reference, _) = message.content else {
                    return
                }

                Task {
                    await runtimeStore.jumpToReferencedMessage(
                        reference.messageID,
                        in: conversationID
                    )
                }
            },
            onCancel: {
                _ = runtimeStore.cancelQueuedTextMessage(
                    localMessageID: message.id,
                    in: conversationID
                )
            },
            onReply: {
                editingTarget = nil
                replyTarget = message
            },
            onEdit: {
                replyTarget = nil
                editingTarget = message
                composerText = MessagePresentation(aggregate: message.aggregate).textValue ?? ""
            },
            onRecall: {
                Task {
                    let didRecall = await runtimeStore.recallMessage(
                        messageID: message.serverMessageID ?? message.id,
                        in: conversationID
                    )
                    if didRecall, replyTarget?.id == message.id {
                        replyTarget = nil
                    }
                }
            },
            onRetry: {
                Task {
                    await runtimeStore.retryTextMessage(
                        localMessageID: message.id,
                        in: conversationID
                    )
                }
            },
            onForward: {
                guard let selectableID else {
                    return
                }
                pendingForwardMessageIDs = [selectableID]
                isPresentingForwardPicker = true
            },
            onToggleFavorite: {
                guard let selectableID else {
                    return
                }
                Task {
                    await toggleFavorite(messageID: selectableID)
                }
            },
            onToggleReaction: { emoji in
                Task {
                    _ = await runtimeStore.toggleMessageReaction(
                        messageID: message.serverMessageID ?? message.id,
                        emoji: emoji,
                        in: conversationID
                    )
                }
            },
            onDownloadMedia: {
                guard let mediaAsset else {
                    return
                }
                startMediaDownload(mediaAsset)
            },
            onCancelMediaDownload: {
                guard let assetID = mediaAsset?.assetID else {
                    return
                }
                pauseMediaDownload(for: assetID)
            },
            onRetryMediaDownload: {
                guard let mediaAsset else {
                    return
                }
                startMediaDownload(mediaAsset)
            },
            onOpenDownloadedMedia: { fileURL in
                previewedMediaItem = IMDownloadedMediaPreviewItem(
                    url: fileURL,
                    title: mediaAsset?.filename ?? fileURL.lastPathComponent
                )
            },
            onDeleteDownloadedMedia: {
                guard let mediaAsset else {
                    return
                }
                deleteDownloadedMedia(mediaAsset)
            }
        )
    }

    @ToolbarContentBuilder
    private var detailToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isPresentingBatchSender = true
            } label: {
                Image(systemName: "timer.circle")
            }
            .disabled(!canSendMessages)
            .accessibilityLabel("批量发送测试消息")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isPresentingSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("搜索会话内消息")
        }

        if conversation?.kind == .group {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if canRenameConversation {
                        Button("修改群名") {
                            isPresentingRenameGroup = true
                        }
                    }

                    if canRenameConversation {
                        Button("编辑群资料") {
                            isPresentingEditMetadata = true
                        }
                    }

                    if canRenameConversation {
                        Button("邀请链接") {
                            isPresentingInvites = true
                        }
                    }

                    Button("我的群昵称") {
                        isPresentingMemberNickname = true
                    }

                    if canAddMembers {
                        Button("添加成员") {
                            isPresentingAddMembers = true
                        }
                    }

                    if canManageMembers {
                        Button("管理成员") {
                            isPresentingManageMembers = true
                        }
                    }

                    Button("退出会话", role: .destructive) {
                        isPresentingLeaveConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(conversation?.isPinned == true ? "取消置顶" : "置顶会话") {
                    Task {
                        _ = await runtimeStore.updateConversationPreferences(
                            conversationID,
                            isPinned: !(conversation?.isPinned ?? false)
                        )
                    }
                }

                Button(conversation?.isMuted == true ? "取消免打扰" : "免打扰") {
                    Task {
                        _ = await runtimeStore.updateConversationPreferences(
                            conversationID,
                            isMuted: !(conversation?.isMuted ?? false)
                        )
                    }
                }

                if let peer = directPeer {
                    if isDirectPeerBlocked {
                        Button("解除拉黑") {
                            Task {
                                _ = await runtimeStore.unblockUser(peer.id)
                            }
                        }
                    } else {
                        Button("拉黑对方", role: .destructive) {
                            Task {
                                _ = await runtimeStore.blockUser(peer.id)
                            }
                        }
                    }

                    Button("举报对方", role: .destructive) {
                        Task {
                            _ = await runtimeStore.reportUser(peer.id, conversationID: conversationID)
                        }
                    }
                }

                Button("清空聊天记录", role: .destructive) {
                    destructiveAction = .clear
                }

                Button("删除会话", role: .destructive) {
                    destructiveAction = .delete
                }
            } label: {
                Image(systemName: "bell.slash.circle")
            }
        }
    }

    private func applyingScrollStateHandlers<Content: View>(
        to content: Content,
        proxy: ScrollViewProxy
    ) -> some View {
        content
            .task(id: conversationID) {
                await scrollToLatestMessage(proxy: proxy, animated: false)
            }
            .onChange(of: latestMessageID) { _ in
                guard latestMessageID != nil else {
                    return
                }

                Task {
                    await scrollToLatestMessage(proxy: proxy, animated: true)
                }
            }
            .onChange(of: conversationStore.replyJumpMatchedMessageID) { _, matchedMessageID in
                guard conversationStore.replyJumpConversationID == conversationID,
                      let matchedMessageID
                else {
                    return
                }

                highlightedMessageID = matchedMessageID
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(matchedMessageID, anchor: .center)
                }

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if highlightedMessageID == matchedMessageID {
                        highlightedMessageID = nil
                    }
                }
            }
    }

    @MainActor
    private func scrollToLatestMessage(proxy: ScrollViewProxy, animated: Bool) async {
        guard let latestMessageID else {
            return
        }

        await Task.yield()

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(latestMessageID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(latestMessageID, anchor: .bottom)
        }
    }

    private func applyingPresentationModifiers<Content: View>(to content: Content) -> some View {
        content
            .sheet(isPresented: $isPresentingAddMembers) {
                NavigationStack {
                    IMAddConversationMembersSheet(
                        conversationStore: conversationStore,
                        conversationID: conversationID
                    )
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingSearch) {
                NavigationStack {
                    IMConversationMessageSearchSheet(
                        conversationID: conversationID,
                        onSelect: { messageID in
                            Task {
                                await runtimeStore.jumpToMessage(messageID, in: conversationID)
                            }
                        }
                    )
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isPresentingBatchSender) {
                NavigationStack {
                    IMBatchMessageSendSheet(
                        senderName: runtimeStore.currentUserDisplayName,
                        canSendMessages: canSendMessages,
                        onSendMessage: { text in
                            await runtimeStore.sendText(text, to: conversationID)
                        }
                    )
                }
                .presentationDetents([.medium])
            }
            .sheet(item: $previewedMediaItem) { item in
                IMDownloadedMediaQuickLookSheet(item: item)
            }
            .sheet(isPresented: $isPresentingRenameGroup) {
                NavigationStack {
                    IMRenameConversationSheet(
                        initialTitle: conversation?.title ?? "",
                        onSubmit: { title in
                            await runtimeStore.renameConversation(conversationID, title: title)
                        }
                    )
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingEditMetadata) {
                NavigationStack {
                    IMEditConversationMetadataSheet(
                        initialTitle: conversation?.title ?? "",
                        initialNotice: conversation?.notice ?? "",
                        initialAvatarPreset: conversation?.avatarPreset ?? .ocean,
                        initialMuteAll: conversation?.muteAll ?? false,
                        onSubmit: { title, notice, avatarPreset, muteAll in
                            await runtimeStore.updateConversationMetadata(
                                conversationID,
                                title: title,
                                notice: notice,
                                avatarPreset: avatarPreset,
                                muteAll: muteAll
                            )
                        }
                    )
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isPresentingInvites) {
                NavigationStack {
                    IMGroupInviteManagementSheet(
                        conversationID: conversationID,
                        loadInvites: {
                            await runtimeStore.fetchGroupInvites(conversationID: conversationID)
                        },
                        createInvite: {
                            await runtimeStore.createGroupInvite(conversationID: conversationID)
                        },
                        revokeInvite: { token in
                            await runtimeStore.revokeGroupInvite(conversationID: conversationID, token: token)
                        }
                    )
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isPresentingMemberNickname) {
                NavigationStack {
                    IMMemberNicknameSheet(
                        initialNickname: currentMember?.memberNickname ?? "",
                        onSubmit: { nickname in
                            await runtimeStore.updateMyMemberNickname(conversationID, memberNickname: nickname)
                        }
                    )
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingManageMembers) {
                NavigationStack {
                    IMManageConversationMembersSheet(
                        conversationStore: conversationStore,
                        conversationID: conversationID,
                        currentUserID: runtimeStore.currentUserID,
                        onPromoteAdmin: { memberUserID in
                            await runtimeStore.updateConversationMemberRole(
                                memberUserID: memberUserID,
                                role: .admin,
                                in: conversationID
                            )
                        },
                        onDemoteAdmin: { memberUserID in
                            await runtimeStore.updateConversationMemberRole(
                                memberUserID: memberUserID,
                                role: .member,
                                in: conversationID
                            )
                        },
                        onTransferOwner: { memberUserID in
                            await runtimeStore.updateConversationMemberRole(
                                memberUserID: memberUserID,
                                role: .owner,
                                in: conversationID
                            )
                        },
                        onRemoveMember: { memberUserID in
                            await runtimeStore.removeConversationMember(
                                memberUserID: memberUserID,
                                from: conversationID
                            )
                        },
                        onSearchMembers: { query in
                            await runtimeStore.loadConversationMembers(conversationID, query: query)
                        },
                        onLoadMoreMembers: {
                            await runtimeStore.loadMoreConversationMembers(conversationID)
                        }
                    )
                }
                .presentationDetents([.medium, .large])
            }
            .fileImporter(
                isPresented: $isPresentingMediaImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handleMediaImport(result)
            }
            .confirmationDialog(
                "退出会话后将不再出现在你的列表中。",
                isPresented: $isPresentingLeaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("退出会话", role: .destructive) {
                    Task {
                        let didLeave = await runtimeStore.leaveConversation(conversationID)
                        if didLeave {
                            dismiss()
                        }
                    }
                }
            }
    }

    private func applyingDraftStateHandlers<Content: View>(to content: Content) -> some View {
        content
            .task(id: conversationID) {
                composerText = conversationStore.draftText(for: conversationID)
            }
            .onChange(of: composerText) { _, newValue in
                conversationStore.updateDraft(newValue, for: conversationID)
            }
    }

    private var conversation: IMConversation? {
        conversationStore.conversations.first { $0.id == conversationID }
    }

    private var messages: [IMConversationMessage] {
        conversation?.messages ?? []
    }

    private func deliveryOverrideText(for message: IMConversationMessage) -> String? {
        guard message.direction == .outgoing,
              message.serverSequence != nil,
              message.deliveryState == .sent
        else {
            return nil
        }

        guard let sequence = message.serverSequence,
              let summary = conversationStore.receiptSummary(for: conversationID)
        else {
            return "已发送"
        }

        let sequenceValue = Int(sequence)
        if summary.readThroughSequence >= sequenceValue {
            return "已读"
        }
        if conversation?.kind == .group, summary.deliveredThroughSequence >= sequenceValue {
            return summary.readThroughSequence > 0 ? "部分已读" : "已送达"
        }
        if summary.deliveredThroughSequence >= sequenceValue {
            return "已送达"
        }
        return "已发送"
    }

    private var latestMessageID: String? {
        messages.last?.id
    }

    private var shouldShowLoadingState: Bool {
        messages.isEmpty && conversationStore.isLoadingMessages
    }

    private var queueSummary: IMConversationQueueSummary {
        conversationStore.queueSummary(for: conversationID)
    }

    private var conversationSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                conversationAvatar(size: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(conversationIdentity.title)
                        .font(.headline)

                    Text(conversationIdentity.detailSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if conversationStore.isLoadingMembers || conversationStore.isLoadingMessages {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Label(conversationKindText, systemImage: conversationKindIcon)
                Text("成员 \(conversation?.memberCount ?? conversation?.memberUserIDs.count ?? 0) 人")
                if let currentGroupRole {
                    Text(currentGroupRole.displayName)
                }
                if conversation?.isPinned == true {
                    Text("已置顶")
                }
                if conversation?.isMuted == true {
                    Text("免打扰")
                }
                if conversation?.muteAll == true {
                    Text("全员禁言")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let notice = conversation?.notice, !notice.isEmpty {
                Label(notice, systemImage: "text.quote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let directMessagingStatusMessage {
                Label(directMessagingStatusMessage, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Label(connectionStatusText, systemImage: connectionStatusIcon)
                .font(.caption)
                .foregroundStyle(connectionStatusColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func conversationAvatar(size: CGFloat) -> some View {
        if conversation?.kind == .direct {
            UserAvatarView(
                displayName: conversationIdentity.title,
                email: conversation?.directPeer?.email,
                avatarPreset: conversation?.directPeer?.avatarPreset,
                size: size
            )
        } else {
            Text(conversationInitials)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.accentColor))
        }
    }

    private var composerBar: some View {
        VStack(spacing: 12) {
            if let directMessagingStatusMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Text(directMessagingStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            if isDirectPeerBlocked, let peer = directPeer {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.red)

                    Text("已屏蔽对方，当前私聊输入已停用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button("解除") {
                        Task {
                            _ = await runtimeStore.unblockUser(peer.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.top, directMessagingStatusMessage == nil ? 12 : 0)
            }

            if let directRelationshipPresentation {
                DirectPeerRelationshipActionPanel(
                    presentation: directRelationshipPresentation,
                    actionMessage: directConversationRelationshipActionMessage,
                    onSendRequest: {
                        Task {
                            await runtimeStore.sendDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    },
                    onAccept: {
                        Task {
                            await runtimeStore.acceptDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    },
                    onDecline: {
                        Task {
                            await runtimeStore.declineDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    },
                    onCancelRequest: {
                        Task {
                            await runtimeStore.cancelDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    }
                )
                .padding(.horizontal, 16)
            }

            Divider()

            HStack(alignment: .bottom, spacing: 12) {
                Button {
                    isPresentingMediaImporter = true
                } label: {
                    Image(systemName: "paperclip.circle.fill")
                        .font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSendMessages ? Color.accentColor : .secondary)
                .disabled(!canSendMessages)

                VStack(alignment: .leading, spacing: 8) {
                    if let editingTarget {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("编辑消息")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(MessagePresentation(aggregate: editingTarget.aggregate).textValue ?? "消息内容不可编辑")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 0)

                            Button {
                                self.editingTarget = nil
                                self.composerText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                    } else if let replyTarget {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("回复消息")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(replyComposerPreviewText(for: replyTarget))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 0)

                            Button {
                                self.replyTarget = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                    }

                    if let composerDisabledReason {
                        Label(composerDisabledReason, systemImage: "lock.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, (replyTarget == nil && editingTarget == nil) ? 12 : 0)
                    }

                    TextField(composerDisabledReason ?? "输入消息", text: $composerText, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.sentences)
                        .disabled(!canSendMessages)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .padding(.top, (replyTarget == nil && editingTarget == nil && composerDisabledReason == nil) ? 12 : 0)
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                Button {
                    Task {
                        let didSend: Bool
                        if let editingTarget {
                            didSend = await runtimeStore.editMessage(
                                messageID: editingTarget.serverMessageID ?? editingTarget.id,
                                text: composerText,
                                in: conversationID
                            )
                        } else if let replyTarget,
                           let reference = replyReference(from: replyTarget) {
                            didSend = await runtimeStore.sendReply(
                                reference: reference,
                                text: composerText,
                                to: conversationID
                            )
                        } else {
                            didSend = await runtimeStore.sendText(composerText, to: conversationID)
                        }
                        if didSend {
                            composerText = ""
                            replyTarget = nil
                            editingTarget = nil
                        }
                    }
                } label: {
                    Image(systemName: editingTarget == nil ? "paperplane.fill" : "square.and.arrow.down.fill")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSendMessages || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(.thinMaterial)
    }

    private func handleMediaImport(_ result: Result<[URL], Error>) {
        guard canSendMessages else {
            return
        }

        switch result {
        case .success(let fileURLs):
            guard let fileURL = fileURLs.first else {
                runtimeStore.setStatusMessage("未选择任何附件。")
                return
            }
            Task {
                await sendImportedMedia(from: fileURL)
            }
        case .failure:
            runtimeStore.setStatusMessage("选择附件失败，请重试。")
        }
    }

    private func sendImportedMedia(from fileURL: URL) async {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let metadata = inferredMediaMetadata(for: fileURL)
        let didSend = await runtimeStore.sendMedia(
            fileURL: fileURL,
            kind: metadata.kind,
            mimeType: metadata.mimeType,
            filename: metadata.filename,
            byteSize: metadata.byteSize,
            to: conversationID
        )

        if didSend {
            replyTarget = nil
            editingTarget = nil
        }
    }

    private func startMediaDownload(_ asset: IMMediaAsset) {
        let assetID = asset.assetID
        let destinationURL: URL

        do {
            destinationURL = try Self.mediaDownloadDestinationURL(for: asset)
        } catch {
            mediaDownloadStates[assetID] = .failed("无法准备下载目录。")
            return
        }

        cancelMediaDownload(for: assetID, nextState: nil)
        if let messageID = messageID(for: assetID) {
            conversationStore.updateLocalDownloadState(
                messageID: messageID,
                state: IMMessageLocalDownloadState(
                    destinationFilePath: destinationURL.path,
                    status: .downloading(
                        progress: nil,
                        backgroundTransfer: nil
                    )
                )
            )
            runtimeStore.persistConversationCacheSoon()
        } else {
            mediaDownloadStates[assetID] = .downloading(progress: nil)
        }

        mediaDownloadTasks[assetID] = Task {
            do {
                try await runtimeStore.startBackgroundMediaDownload(asset, to: destinationURL)
                await MainActor.run {
                    mediaDownloadTasks[assetID] = nil
                    mediaDownloadStates.removeValue(forKey: assetID)
                }
            } catch is CancellationError {
                await MainActor.run {
                    mediaDownloadTasks[assetID] = nil
                }
            } catch {
                await MainActor.run {
                    mediaDownloadTasks[assetID] = nil
                    let failureMessage = mediaDownloadFailureMessage(for: asset, error: error)
                    if let messageID = messageID(for: assetID) {
                        conversationStore.updateLocalDownloadState(
                            messageID: messageID,
                            state: IMMessageLocalDownloadState(
                                destinationFilePath: destinationURL.path,
                                status: .failed(message: failureMessage)
                            )
                        )
                        runtimeStore.persistConversationCacheSoon()
                    } else {
                        mediaDownloadStates[assetID] = .failed(failureMessage)
                    }
                }
            }
        }
    }

    private func pauseMediaDownload(for assetID: String) {
        let message = messages.first { $0.mediaAsset?.assetID == assetID }
        let progress: FileTransferProgress?
        let backgroundTransfer: IMMessageBackgroundTransferReference?

        if let localDownloadState = message?.localDownloadState {
            switch localDownloadState.status {
            case .downloading(let snapshot, let reference),
                 .waitingForConnectivity(let snapshot, let reference):
                progress = snapshot?.progress
                backgroundTransfer = reference
            case .paused(let snapshot):
                progress = snapshot?.progress
                backgroundTransfer = nil
            case .downloaded, .failed:
                progress = nil
                backgroundTransfer = nil
            }
        } else if case .downloading(let currentProgress) = mediaDownloadStates[assetID] {
            progress = currentProgress
            backgroundTransfer = nil
        } else {
            progress = nil
            backgroundTransfer = nil
        }

        if let messageID = messageID(for: assetID),
           let asset = mediaAsset(for: assetID),
           let destinationURL = try? Self.mediaDownloadDestinationURL(for: asset) {
            conversationStore.updateLocalDownloadState(
                messageID: messageID,
                state: IMMessageLocalDownloadState(
                    destinationFilePath: destinationURL.path,
                    status: .paused(progress: progress.map(IMMessageLocalDownloadProgressSnapshot.init))
                )
            )
            runtimeStore.persistConversationCacheSoon()
        }

        cancelMediaDownload(for: assetID, nextState: .paused(progress: progress))
        if let backgroundTransfer {
            Task {
                await runtimeStore.cancelBackgroundMediaDownload(backgroundTransfer)
            }
        }
    }

    private func deleteDownloadedMedia(_ asset: IMMediaAsset) {
        let assetID = asset.assetID
        cancelMediaDownload(for: assetID, nextState: nil)

        do {
            let destinationURL = try Self.mediaDownloadDestinationURL(for: asset)
            let metadataURL = Self.downloadMetadataURL(for: destinationURL)
            try? FileManager.default.removeItem(at: destinationURL)
            try? FileManager.default.removeItem(at: metadataURL)
            if let messageID = messageID(for: assetID) {
                conversationStore.updateLocalDownloadState(messageID: messageID, state: nil)
                runtimeStore.persistConversationCacheSoon()
            }
            mediaDownloadStates[assetID] = .idle
        } catch {
            mediaDownloadStates[assetID] = .failed("无法删除已下载文件。")
        }
    }

    private func cancelMediaDownload(for assetID: String, nextState: IMMediaDownloadState?) {
        mediaDownloadTasks[assetID]?.cancel()
        mediaDownloadTasks[assetID] = nil
        if let nextState {
            mediaDownloadStates[assetID] = nextState
        }
    }

    private func pauseAllMediaDownloads() {
        for assetID in Set(mediaDownloadTasks.keys).union(
            messages.compactMap { message in
                switch message.localDownloadState?.status {
                case .downloading, .waitingForConnectivity:
                    return message.mediaAsset?.assetID
                case .paused, .downloaded, .failed, .none:
                    return nil
                }
            }
        ) {
            pauseMediaDownload(for: assetID)
        }
    }

    private static func mediaDownloadDestinationURL(for asset: IMMediaAsset) throws -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let downloadsDirectory = baseDirectory
            .appending(path: "IMMediaDownloads", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let preferredFilename = sanitizedDownloadFilename(
            asset.filename.trimmingCharacters(in: .whitespacesAndNewlines),
            fallbackAssetID: asset.assetID
        )
        return downloadsDirectory.appending(path: preferredFilename)
    }

    private static func downloadMetadataURL(for destinationURL: URL) -> URL {
        destinationURL.appendingPathExtension("resume.json")
    }

    private static func sanitizedDownloadFilename(_ filename: String?, fallbackAssetID: String) -> String {
        let rawFilename = filename?.isEmpty == false ? filename! : fallbackAssetID
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = rawFilename.components(separatedBy: invalidCharacters)
        let sanitized = components.joined(separator: "-")
        return sanitized.isEmpty ? fallbackAssetID : sanitized
    }

    private func resolvedMediaDownloadState(for message: IMConversationMessage) -> IMMediaDownloadState? {
        guard let asset = message.mediaAsset else {
            return nil
        }

        if let localDownloadState = message.localDownloadState {
            switch localDownloadState.status {
            case .downloading(let progress, _), .waitingForConnectivity(let progress, _):
                return .downloading(progress: progress?.progress)
            case .paused(let progress):
                return .paused(progress: progress?.progress)
            case .downloaded:
                if FileManager.default.fileExists(atPath: localDownloadState.destinationFilePath) {
                    return .downloaded(localDownloadState.destinationFileURL)
                }
            case .failed(let message):
                return .failed(message)
            }
        }

        if let state = mediaDownloadStates[asset.assetID] {
            return state
        }

        guard let destinationURL = try? Self.mediaDownloadDestinationURL(for: asset),
              FileManager.default.fileExists(atPath: destinationURL.path)
        else {
            return .idle
        }

        return .downloaded(destinationURL)
    }

    private func messageID(for assetID: String) -> String? {
        messages.first { $0.mediaAsset?.assetID == assetID }?.id
    }

    private func mediaAsset(for assetID: String) -> IMMediaAsset? {
        messages.first { $0.mediaAsset?.assetID == assetID }?.mediaAsset
    }

    private func mediaDownloadFailureMessage(for asset: IMMediaAsset, error: Error) -> String {
        let prefix = "\(asset.kind.displayName)下载失败"

        if let apiError = error as? APIError {
            switch apiError {
            case .forbidden, .unauthorized:
                return "\(prefix)：你当前无权访问这个附件。"
            case .connectivity:
                return "\(prefix)：当前无法连接服务器。"
            case .timeout:
                return "\(prefix)：请求超时，请重试。"
            case .server(let statusCode, _):
                if statusCode == 404 {
                    return "\(prefix)：附件已不可用。"
                }
                return "\(prefix)：\(apiError.localizedDescription)"
            default:
                return "\(prefix)：\(apiError.localizedDescription)"
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return "\(prefix)：设备存储空间不足。"
        }

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "\(prefix)：网络连接已中断。"
            case NSURLErrorTimedOut:
                return "\(prefix)：请求超时，请重试。"
            default:
                break
            }
        }

        return "\(prefix)：\(error.localizedDescription)"
    }

    private func inferredMediaMetadata(for fileURL: URL) -> (
        kind: IMMediaAssetKind,
        mimeType: String,
        filename: String,
        byteSize: Int64?
    ) {
        let filename = fileURL.lastPathComponent
        let mimeType = preferredMimeType(for: fileURL)
        let kind: IMMediaAssetKind
        if let type = UTType(filenameExtension: fileURL.pathExtension.lowercased()) {
            if type.conforms(to: .image) {
                kind = .image
            } else if type.conforms(to: .audio) {
                kind = .audio
            } else {
                kind = .file
            }
        } else {
            kind = .file
        }

        let byteSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return (kind, mimeType, filename, byteSize)
    }

    private func preferredMimeType(for fileURL: URL) -> String {
        guard let type = UTType(filenameExtension: fileURL.pathExtension.lowercased()),
              let mimeType = type.preferredMIMEType
        else {
            return "application/octet-stream"
        }
        return mimeType
    }

    private var conversationIdentity: IMConversationIdentityPresentation {
        guard let conversation else {
            return IMConversationIdentityPresentation(
                title: "会话",
                detailSummary: conversationStore.isLoadingMembers ? "正在加载成员信息" : "当前还没有成员信息",
                rowSecondaryLabel: nil
            )
        }

        return presentationStore.conversationIdentityPresentation(for: conversation)
    }

    private var conversationKindText: String {
        switch conversation?.kind ?? .group {
        case .direct:
            return "私聊"
        case .group:
            return "群聊"
        }
    }

    private var conversationKindIcon: String {
        switch conversation?.kind ?? .group {
        case .direct:
            return "person.2"
        case .group:
            return "person.3"
        }
    }

    private var conversationInitials: String {
        let trimmed = conversationIdentity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "IM"
        }

        return String(trimmed.prefix(2)).uppercased()
    }

    private var canSendMessages: Bool {
        guard let conversation else {
            return true
        }
        if conversation.kind == .group {
            return !(conversation.muteAll && currentGroupRole == .member)
        }
        if isDirectPeerBlocked {
            return false
        }
        return conversation.canSendMessages
    }

    private var composerDisabledReason: String? {
        if isDirectPeerBlocked {
            return "已屏蔽对方"
        }
        guard conversation?.kind == .group,
              conversation?.muteAll == true,
              currentGroupRole == .member
        else {
            return nil
        }
        return "全员禁言中"
    }

    private var currentGroupRole: IMConversationMemberRole? {
        currentMember?.role
    }

    private var currentMember: IMConversationMember? {
        guard let currentUserID = runtimeStore.currentUserID else {
            return nil
        }

        return conversation?.members.first(where: { $0.id == currentUserID })
    }

    private var directPeer: IMDirectPeer? {
        guard conversation?.kind == .direct else {
            return nil
        }
        return conversation?.directPeer
    }

    private var isDirectPeerBlocked: Bool {
        guard let directPeer else {
            return false
        }
        return runtimeStore.blockedUserIDs.contains(directPeer.id)
    }

    private var canAddMembers: Bool {
        currentGroupRole?.canAddMembers ?? false
    }

    private var canRenameConversation: Bool {
        currentGroupRole?.canRenameConversation ?? false
    }

    private var canManageMembers: Bool {
        currentGroupRole?.canManageRoles == true || currentGroupRole?.canAddMembers == true
    }

    private var directMessagingStatusMessage: String? {
        conversation?.directMessagingStatusMessage
    }

    private var directRelationshipPresentation: DirectPeerRelationshipPresentation? {
        presentationStore.directPeerRelationshipPresentation(for: conversationID)
    }

    private var directConversationRelationshipActionMessage: String? {
        presentationStore.directConversationRelationshipActionMessage(for: conversationID)
    }

    private var connectionStatusText: String {
        switch presentationStore.imConnectionStatus {
        case .connected:
            return "实时连接在线"
        case .connecting:
            return "正在建立实时连接"
        case .disconnected:
            return "当前仅可查看 HTTP 拉取的数据"
        case .failed(let message):
            return message
        }
    }

    private var connectionStatusIcon: String {
        switch presentationStore.imConnectionStatus {
        case .connected:
            return "dot.radiowaves.left.and.right"
        case .connecting:
            return "arrow.trianglehead.2.clockwise"
        case .disconnected:
            return "bolt.slash"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var connectionStatusColor: Color {
        switch presentationStore.imConnectionStatus {
        case .connected:
            return .green
        case .connecting:
            return .blue
        case .disconnected:
            return .secondary
        case .failed:
            return .orange
        }
    }

    private func replyReference(from message: IMConversationMessage) -> IMReplyReference? {
        guard message.canReply else {
            return nil
        }

        return IMReplyReference(
            messageID: message.serverMessageID ?? message.id,
            senderUserID: message.senderUserID,
            previewText: replyComposerPreviewText(for: message)
        )
    }

    private func replyComposerPreviewText(for message: IMConversationMessage) -> String {
        switch message.content {
        case .recalled:
            return "原消息已撤回"
        case .text, .reply, .system, .image, .audio, .file:
            let preview = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? "原消息暂不可用" : preview
        }
    }
}

private struct IMBatchMessageSendSheet: View {
    @Environment(\.dismiss) private var dismiss

    let senderName: String
    let canSendMessages: Bool
    let onSendMessage: (String) async -> Bool

    @State private var nextMessageNumber = 1
    @State private var sentCount = 0
    @State private var failedCount = 0
    @State private var isSending = false
    @State private var statusText = "待开始"
    @State private var sendTask: Task<Void, Never>?

    private let finalMessageNumber = 10_000
    private let sendIntervalNanoseconds: UInt64 = 300_000_000

    var body: some View {
        Form {
            Section {
                LabeledContent("当前用户", value: senderName)
                LabeledContent("下一条序号", value: "\(nextMessageNumber)")
                LabeledContent("已发送", value: "\(sentCount)")
                LabeledContent("失败", value: "\(failedCount)")
            }

            Section {
                ProgressView(value: progressValue, total: Double(finalMessageNumber))
                    .progressViewStyle(.linear)

                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Section {
                HStack(spacing: 12) {
                    Button {
                        startSending()
                    } label: {
                        Label(isSending ? "发送中" : "开始", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartSending)

                    Button(role: .destructive) {
                        stopSending()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isSending)
                }

                Button {
                    resetProgress()
                } label: {
                    Label("重置", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isSending || (nextMessageNumber == 1 && sentCount == 0 && failedCount == 0))
            } footer: {
                Text("每 0.3 秒发送一条，内容为 \(senderName) + 序号，直到 10000。")
            }
        }
        .navigationTitle("批量发送")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") {
                    dismiss()
                }
            }
        }
        .onDisappear {
            stopSending()
        }
    }

    private var canStartSending: Bool {
        canSendMessages && !isSending && nextMessageNumber <= finalMessageNumber
    }

    private var progressValue: Double {
        Double(max(0, min(finalMessageNumber, nextMessageNumber - 1)))
    }

    private func startSending() {
        guard canStartSending else {
            return
        }

        sendTask?.cancel()
        sendTask = Task { @MainActor in
            await runSendLoop()
        }
    }

    @MainActor
    private func runSendLoop() async {
        isSending = true
        statusText = "正在发送..."
        defer {
            isSending = false
            sendTask = nil
        }

        while nextMessageNumber <= finalMessageNumber, !Task.isCancelled {
            let currentNumber = nextMessageNumber
            let messageText = "\(senderName) \(currentNumber)"
            let didSend = await onSendMessage(messageText)

            if didSend {
                sentCount += 1
                statusText = "已发送 \(currentNumber)"
            } else {
                failedCount += 1
                statusText = "发送失败 \(currentNumber)"
            }

            nextMessageNumber = currentNumber + 1

            guard nextMessageNumber <= finalMessageNumber, !Task.isCancelled else {
                break
            }

            do {
                try await Task.sleep(nanoseconds: sendIntervalNanoseconds)
            } catch {
                break
            }
        }

        if nextMessageNumber > finalMessageNumber {
            statusText = "已完成 10000 条"
        } else if Task.isCancelled {
            statusText = "已停止，下一条 \(nextMessageNumber)"
        }
    }

    private func stopSending() {
        sendTask?.cancel()
        if isSending {
            statusText = "已停止，下一条 \(nextMessageNumber)"
        } else {
            sendTask = nil
        }
    }

    private func resetProgress() {
        nextMessageNumber = 1
        sentCount = 0
        failedCount = 0
        statusText = "待开始"
    }
}
