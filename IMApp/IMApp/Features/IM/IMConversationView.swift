import SwiftUI
import IMClientKit
import Combine
import QuickLook
import UniformTypeIdentifiers

enum IMNavigationRoute: Hashable {
    case conversation(String)
}

struct IMConversationView: View {
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject var conversationStore: IMConversationStore

    let onOpenConversation: (String) -> Void

    @State private var isPresentingCreateConversation = false

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
                                identity: authManager.conversationIdentityPresentation(for: conversation),
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
                        Color.clear
                            .frame(height: 1)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .onAppear {
                                let anchorConversationID = conversationStore.conversationSummaryPaginationAnchorID
                                Task {
                                    await authManager.loadMoreIMConversationSummariesIfNeeded(
                                        anchorConversationID: anchorConversationID
                                    )
                                }
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
                await authManager.refreshIMConversationSummaryReadModelIfNeeded()
            }
        }
        .refreshable {
            await authManager.reloadIMConversations(force: true)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task {
                        await authManager.reloadIMConversations(force: true)
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
            }
        }
        .sheet(isPresented: $isPresentingCreateConversation) {
            NavigationStack {
                IMCreateConversationSheet(conversationStore: conversationStore)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var connectionTitle: String {
        switch authManager.imConnectionStatus {
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
        switch authManager.imConnectionStatus {
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
        switch authManager.imConnectionStatus {
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
        switch authManager.imConnectionStatus {
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
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var conversationStore: IMConversationStore

    let conversationID: String

    @State private var composerText = ""
    @State private var isPresentingAddMembers = false
    @State private var isPresentingManageMembers = false
    @State private var isPresentingLeaveConfirmation = false
    @State private var isPresentingRenameGroup = false
    @State private var isPresentingEditMetadata = false
    @State private var isPresentingSearch = false
    @State private var isPresentingMediaImporter = false
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
                await authManager.openIMConversation(conversationID)
            }
            .onDisappear {
                pauseAllMediaDownloads()
            }
            .toolbar {
                detailToolbarContent
            }
            .safeAreaInset(edge: .bottom) {
                composerBar
            }
    }

    private var detailScrollView: some View {
        ScrollView {
            detailMessageStack
        }
        .background(Color(.systemGroupedBackground))
    }

    private var detailMessageStack: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            conversationSummaryCard

            if queueSummary.hasPendingWork {
                IMConversationQueueBanner(
                    summary: queueSummary,
                    isFlushing: authManager.isFlushingQueuedIMTextMessages
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
                        await authManager.loadOlderIMMessages()
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
        return IMMessageBubble(
            message: message,
            replyReference: message.resolvedReplyReference(in: messages),
            isHighlighted: highlightedMessageID == message.id,
            canRetry: conversationStore.isRetryableFailure(message),
            canCancel: message.canCancelQueuedSend,
            canReply: message.canReply,
            canRecall: message.canRecall,
            canEdit: message.canEdit,
            canReact: message.canReact,
            mediaDownloadState: resolvedMediaDownloadState(for: message),
            currentUserID: authManager.currentUser?.id,
            onJumpToReplyReference: {
                guard case .reply(let reference, _) = message.content else {
                    return
                }

                Task {
                    await authManager.jumpToReferencedIMMessage(
                        reference.messageID,
                        in: conversationID
                    )
                }
            },
            onCancel: {
                _ = authManager.cancelQueuedIMTextMessage(
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
                    let didRecall = await authManager.recallIMMessage(
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
                    await authManager.retryIMTextMessage(
                        localMessageID: message.id,
                        in: conversationID
                    )
                }
            },
            onToggleReaction: { emoji in
                Task {
                    _ = await authManager.toggleIMMessageReaction(
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
                        _ = await authManager.updateIMConversationPreferences(
                            conversationID,
                            isPinned: !(conversation?.isPinned ?? false)
                        )
                    }
                }

                Button(conversation?.isMuted == true ? "取消免打扰" : "免打扰") {
                    Task {
                        _ = await authManager.updateIMConversationPreferences(
                            conversationID,
                            isMuted: !(conversation?.isMuted ?? false)
                        )
                    }
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
            .onChange(of: latestMessageID) { _ in
                guard latestMessageID != nil else {
                    return
                }

                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(latestMessageID, anchor: .bottom)
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
                                await authManager.jumpToIMMessage(messageID, in: conversationID)
                            }
                        }
                    )
                    .environmentObject(authManager)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $previewedMediaItem) { item in
                IMDownloadedMediaQuickLookSheet(item: item)
            }
            .sheet(isPresented: $isPresentingRenameGroup) {
                NavigationStack {
                    IMRenameConversationSheet(
                        initialTitle: conversation?.title ?? "",
                        onSubmit: { title in
                            await authManager.renameIMConversation(conversationID, title: title)
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
                        onSubmit: { title, notice, avatarPreset in
                            await authManager.updateIMConversationMetadata(
                                conversationID,
                                title: title,
                                notice: notice,
                                avatarPreset: avatarPreset
                            )
                        }
                    )
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isPresentingManageMembers) {
                NavigationStack {
                    IMManageConversationMembersSheet(
                        conversationStore: conversationStore,
                        conversationID: conversationID,
                        currentUserID: authManager.currentUser?.id,
                        onPromoteAdmin: { memberUserID in
                            await authManager.updateIMConversationMemberRole(
                                memberUserID: memberUserID,
                                role: .admin,
                                in: conversationID
                            )
                        },
                        onDemoteAdmin: { memberUserID in
                            await authManager.updateIMConversationMemberRole(
                                memberUserID: memberUserID,
                                role: .member,
                                in: conversationID
                            )
                        },
                        onTransferOwner: { memberUserID in
                            await authManager.updateIMConversationMemberRole(
                                memberUserID: memberUserID,
                                role: .owner,
                                in: conversationID
                            )
                        },
                        onRemoveMember: { memberUserID in
                            await authManager.removeIMConversationMember(
                                memberUserID: memberUserID,
                                from: conversationID
                            )
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
                        let didLeave = await authManager.leaveIMConversation(conversationID)
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

            if let directRelationshipPresentation {
                DirectPeerRelationshipActionPanel(
                    presentation: directRelationshipPresentation,
                    actionMessage: directConversationRelationshipActionMessage,
                    onSendRequest: {
                        Task {
                            await authManager.sendDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    },
                    onAccept: {
                        Task {
                            await authManager.acceptDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    },
                    onDecline: {
                        Task {
                            await authManager.declineDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    },
                    onCancelRequest: {
                        Task {
                            await authManager.cancelDirectConversationFriendRequest(conversationID: conversationID)
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

                    TextField("输入消息", text: $composerText, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.sentences)
                        .disabled(!canSendMessages)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .padding(.top, (replyTarget == nil && editingTarget == nil) ? 12 : 0)
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                Button {
                    Task {
                        let didSend: Bool
                        if let editingTarget {
                            didSend = await authManager.editIMMessage(
                                messageID: editingTarget.serverMessageID ?? editingTarget.id,
                                text: composerText,
                                in: conversationID
                            )
                        } else if let replyTarget,
                           let reference = replyReference(from: replyTarget) {
                            didSend = await authManager.sendIMReply(
                                reference: reference,
                                text: composerText,
                                to: conversationID
                            )
                        } else {
                            didSend = await authManager.sendIMText(composerText, to: conversationID)
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
                authManager.imConversationStore.setStatusMessage("未选择任何附件。")
                return
            }
            Task {
                await sendImportedMedia(from: fileURL)
            }
        case .failure:
            authManager.imConversationStore.setStatusMessage("选择附件失败，请重试。")
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
        let didSend = await authManager.sendIMMedia(
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
            authManager.persistIMConversationCacheSoon()
        } else {
            mediaDownloadStates[assetID] = .downloading(progress: nil)
        }

        mediaDownloadTasks[assetID] = Task {
            do {
                try await authManager.startBackgroundIMMediaDownload(asset, to: destinationURL)
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
                        authManager.persistIMConversationCacheSoon()
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
            authManager.persistIMConversationCacheSoon()
        }

        cancelMediaDownload(for: assetID, nextState: .paused(progress: progress))
        if let backgroundTransfer {
            Task {
                await authManager.cancelBackgroundIMMediaDownload(backgroundTransfer)
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
                authManager.persistIMConversationCacheSoon()
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

        return authManager.conversationIdentityPresentation(for: conversation)
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
        conversation?.canSendMessages ?? true
    }

    private var currentGroupRole: IMConversationMemberRole? {
        guard let currentUserID = authManager.currentUser?.id else {
            return nil
        }

        return conversation?.members.first(where: { $0.id == currentUserID })?.role
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
        authManager.directPeerRelationshipPresentation(for: conversationID)
    }

    private var directConversationRelationshipActionMessage: String? {
        authManager.directConversationRelationshipActionMessage(for: conversationID)
    }

    private var connectionStatusText: String {
        switch authManager.imConnectionStatus {
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
        switch authManager.imConnectionStatus {
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
        switch authManager.imConnectionStatus {
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

