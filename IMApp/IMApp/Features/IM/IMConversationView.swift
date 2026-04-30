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

private struct IMConversationMessageSearchSheet: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    let conversationID: String
    let onSelect: (String) -> Void

    @State private var query = ""
    @State private var results: [IMConversationMessageSearchHitResponseBody] = []
    @State private var nextCursor: String?
    @State private var isSearching = false
    @State private var statusMessage: String?

    var body: some View {
        List {
            if let statusMessage, !statusMessage.isEmpty {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if results.isEmpty, !isSearching {
                Section {
                    ContentUnavailableView(
                        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "输入关键字开始搜索" : "没有找到匹配消息",
                        systemImage: "magnifyingglass",
                        description: Text("支持搜索文本消息、引用预览、系统消息文案和文件名。")
                    )
                }
            } else {
                Section("搜索结果") {
                    ForEach(results, id: \.messageID) { hit in
                        Button {
                            dismiss()
                            onSelect(hit.messageID.uuidString)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(hit.snippet)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text(hit.content.previewText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }

                    if isSearching {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if nextCursor != nil {
                        Button("加载更多结果") {
                            Task {
                                await runSearch(reset: false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .navigationTitle("搜索消息")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索消息内容、系统消息、文件名")
        .onSubmit(of: .search) {
            Task {
                await runSearch(reset: true)
            }
        }
        .onChange(of: query) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results = []
                nextCursor = nil
                statusMessage = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("搜索") {
                    Task {
                        await runSearch(reset: true)
                    }
                }
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
        }
    }

    private func runSearch(reset: Bool) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            results = []
            nextCursor = nil
            statusMessage = nil
            return
        }

        isSearching = true
        defer { isSearching = false }

        let cursor = reset ? nil : nextCursor
        guard let page = await authManager.searchIMConversationMessages(
            in: conversationID,
            query: trimmedQuery,
            cursor: cursor,
            limit: 20
        ) else {
            if reset {
                results = []
            }
            statusMessage = "搜索失败，请稍后重试。"
            return
        }

        if reset {
            results = page.items
        } else {
            results.append(contentsOf: page.items)
        }
        nextCursor = page.nextCursor
        statusMessage = results.isEmpty ? "没有找到匹配消息。" : nil
    }
}

private struct DirectPeerRelationshipActionPanel: View {
    let presentation: DirectPeerRelationshipPresentation
    let actionMessage: String?
    let onSendRequest: () -> Void
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onCancelRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if presentation.state == .resolving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: iconName)
                        .foregroundStyle(.orange)
                }

                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }

            switch presentation.state {
            case .none:
                Button("添加好友", action: onSendRequest)
                    .buttonStyle(.borderedProminent)
            case .outgoingPending:
                Button("取消申请", role: .destructive, action: onCancelRequest)
                    .buttonStyle(.bordered)
            case .incomingPending:
                HStack(spacing: 10) {
                    Button("接受", action: onAccept)
                        .buttonStyle(.borderedProminent)

                    Button("拒绝", role: .destructive, action: onDecline)
                        .buttonStyle(.bordered)
                }
            case .friend, .resolving, .unavailable:
                EmptyView()
            }

            if let actionMessage, !actionMessage.isEmpty {
                IMInlineStatusBanner(message: actionMessage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconName: String {
        switch presentation.state {
        case .friend:
            return "person.crop.circle.badge.checkmark"
        case .none:
            return "person.badge.plus"
        case .outgoingPending:
            return "paperplane.fill"
        case .incomingPending:
            return "person.crop.circle.badge.plus"
        case .resolving:
            return "arrow.trianglehead.2.clockwise"
        case .unavailable:
            return "person.crop.circle.badge.exclamationmark"
        }
    }
}

private enum IMCreateConversationMode: String, CaseIterable, Identifiable {
    case direct
    case group

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct:
            return "私聊"
        case .group:
            return "群聊"
        }
    }
}

private struct IMCreateConversationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject var conversationStore: IMConversationStore

    @State private var mode: IMCreateConversationMode = .direct
    @State private var conversationTitle = ""
    @State private var memberEmails = ""
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section {
                Picker("会话类型", selection: $mode) {
                    ForEach(IMCreateConversationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(mode == .direct ? "私聊只需要填写 1 个对方邮箱，创建时不会传会话标题。" : "群聊可以填写 1 个或多个成员；填写标题会创建为群聊。")
            }

            Section("会话信息") {
                if mode == .group {
                    TextField("群聊标题（可选）", text: $conversationTitle)
                }

                TextField(memberEmailPlaceholder, text: $memberEmails, axis: .vertical)
                    .lineLimit(3...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let message = conversationStore.statusMessage, !message.isEmpty {
                Section {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("新建会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                if isSubmitting {
                    ProgressView()
                } else {
                    Button("创建") {
                        Task {
                            isSubmitting = true
                            let didCreate = await authManager.createIMConversation(
                                kind: conversationKind,
                                title: createConversationTitle,
                                memberEmails: parsedMemberEmails
                            )
                            isSubmitting = false

                            if didCreate {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private var memberEmailPlaceholder: String {
        switch mode {
        case .direct:
            return "对方邮箱"
        case .group:
            return "成员邮箱，逗号或换行分隔"
        }
    }

    private var conversationKind: IMConversationKind {
        switch mode {
        case .direct:
            return .direct
        case .group:
            return .group
        }
    }

    private var createConversationTitle: String {
        switch mode {
        case .direct:
            return ""
        case .group:
            return conversationTitle
        }
    }

    private var canSubmit: Bool {
        switch mode {
        case .direct:
            return parsedMemberEmails.count == 1
        case .group:
            return !parsedMemberEmails.isEmpty
        }
    }

    private var parsedMemberEmails: [String] {
        memberEmails
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}

private struct IMAddConversationMembersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject var conversationStore: IMConversationStore

    let conversationID: String

    @State private var memberEmails = ""
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section("新增成员") {
                TextField("成员邮箱，逗号或换行分隔", text: $memberEmails, axis: .vertical)
                    .lineLimit(3...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let message = conversationStore.statusMessage, !message.isEmpty {
                Section {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("添加成员")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                if isSubmitting {
                    ProgressView()
                } else {
                    Button("添加") {
                        Task {
                            isSubmitting = true
                            let didAdd = await authManager.addIMConversationMembers(
                                to: conversationID,
                                memberEmails: parsedMemberEmails
                            )
                            isSubmitting = false

                            if didAdd {
                                dismiss()
                            }
                        }
                    }
                    .disabled(parsedMemberEmails.isEmpty)
                }
            }
        }
    }

    private var parsedMemberEmails: [String] {
        memberEmails
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}

private struct IMRenameConversationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var submitter = IMAsyncSubmitter()

    let initialTitle: String
    let onSubmit: (String) async -> Bool

    @State private var title: String = ""

    var body: some View {
        Form {
            Section("群聊名称") {
                TextField("输入新的群聊名称", text: $title)
            }

            if let message = submitter.message, !message.isEmpty {
                Section {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("修改群名")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if title.isEmpty {
                title = initialTitle
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                if submitter.isSubmitting {
                    ProgressView()
                } else {
                    Button("保存") {
                        Task {
                            await submitter.run(messageOnFailure: "修改群名失败。") {
                                await onSubmit(title.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            if submitter.didSucceed {
                                dismiss()
                            }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct IMEditConversationMetadataSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var submitter = IMAsyncSubmitter()

    let initialTitle: String
    let initialNotice: String
    let initialAvatarPreset: IMConversationAvatarPreset
    let onSubmit: (String?, String?, IMConversationAvatarPreset) async -> Bool

    @State private var title = ""
    @State private var notice = ""
    @State private var avatarPreset: IMConversationAvatarPreset = .ocean

    var body: some View {
        Form {
            Section("群资料") {
                TextField("群名称", text: $title)
                TextField("群公告", text: $notice, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
            }

            Section("群头像") {
                Picker("预设头像", selection: $avatarPreset) {
                    ForEach(IMConversationAvatarPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }

            if let message = submitter.message, !message.isEmpty {
                Section {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("编辑群资料")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if title.isEmpty && notice.isEmpty {
                title = initialTitle
                notice = initialNotice
                avatarPreset = initialAvatarPreset
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                if submitter.isSubmitting {
                    ProgressView()
                } else {
                    Button("保存") {
                        Task {
                            await submitter.run(messageOnFailure: "保存群资料失败。") {
                                await onSubmit(
                                    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title.trimmingCharacters(in: .whitespacesAndNewlines),
                                    notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notice.trimmingCharacters(in: .whitespacesAndNewlines),
                                    avatarPreset
                                )
                            }
                            if submitter.didSucceed {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct IMManageConversationMembersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var submitter = IMAsyncSubmitter()

    @ObservedObject var conversationStore: IMConversationStore
    let conversationID: String
    let currentUserID: UUID?
    let onPromoteAdmin: (UUID) async -> Bool
    let onDemoteAdmin: (UUID) async -> Bool
    let onTransferOwner: (UUID) async -> Bool
    let onRemoveMember: (UUID) async -> Bool

    var body: some View {
        List {
            if let conversation {
                Section {
                    ForEach(sortedMembers) { member in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(member.email)
                                        .font(.body)
                                    if member.id == currentUserID {
                                        Text("我")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(.tertiarySystemFill))
                                            .clipShape(Capsule())
                                    }
                                }

                                Text(member.role.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if actionMenuItems(for: member).isEmpty {
                                EmptyView()
                            } else {
                                Menu {
                                    ForEach(actionMenuItems(for: member)) { item in
                                        Button(item.title, role: item.role) {
                                            Task {
                                                await submitter.run(messageOnFailure: item.failureMessage) {
                                                    await item.action()
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.title3)
                                }
                            }
                        }
                    }
                } header: {
                    Text("成员管理")
                } footer: {
                    Text("群主可以设置管理员、转让群主并移除成员；管理员只能移除普通成员。")
                }
            } else {
                Section {
                    Text("当前没有可管理的成员信息。")
                        .foregroundStyle(.secondary)
                }
            }

            if let message = submitter.message, !message.isEmpty {
                Section {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("管理成员")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
    }

    private var sortedMembers: [IMConversationMember] {
        conversation?.members ?? []
    }

    private var conversation: IMConversation? {
        conversationStore.conversations.first(where: { $0.id == conversationID })
    }

    private var currentRole: IMConversationMemberRole? {
        guard let currentUserID else {
            return nil
        }

        return conversation?.members.first(where: { $0.id == currentUserID })?.role
    }

    private func actionMenuItems(for member: IMConversationMember) -> [MemberActionItem] {
        guard let currentRole, member.id != currentUserID else {
            return []
        }

        var items: [MemberActionItem] = []

        if currentRole.canManageRoles {
            switch member.role {
            case .owner:
                break
            case .admin:
                items.append(
                    MemberActionItem(
                        title: "取消管理员",
                        failureMessage: "取消管理员失败。",
                        action: { await onDemoteAdmin(member.id) }
                    )
                )
                items.append(
                    MemberActionItem(
                        title: "转让群主",
                        failureMessage: "转让群主失败。",
                        action: { await onTransferOwner(member.id) }
                    )
                )
            case .member:
                items.append(
                    MemberActionItem(
                        title: "设为管理员",
                        failureMessage: "设置管理员失败。",
                        action: { await onPromoteAdmin(member.id) }
                    )
                )
                items.append(
                    MemberActionItem(
                        title: "转让群主",
                        failureMessage: "转让群主失败。",
                        action: { await onTransferOwner(member.id) }
                    )
                )
            }
        }

        if currentRole.canRemove(memberWithRole: member.role) {
            items.append(
                MemberActionItem(
                    title: "移除成员",
                    role: .destructive,
                    failureMessage: "移除成员失败。",
                    action: { await onRemoveMember(member.id) }
                )
            )
        }

        return items
    }
}

private struct MemberActionItem: Identifiable {
    let id = UUID()
    let title: String
    let role: ButtonRole?
    let failureMessage: String
    let action: () async -> Bool

    init(
        title: String,
        role: ButtonRole? = nil,
        failureMessage: String,
        action: @escaping () async -> Bool
    ) {
        self.title = title
        self.role = role
        self.failureMessage = failureMessage
        self.action = action
    }
}

@MainActor
private final class IMAsyncSubmitter: ObservableObject {
    @Published fileprivate var isSubmitting = false
    @Published fileprivate var message: String?
    fileprivate var didSucceed = false

    func run(
        messageOnFailure: String,
        action: @escaping () async -> Bool
    ) async {
        guard !isSubmitting else {
            return
        }

        isSubmitting = true
        didSucceed = false
        message = nil
        let succeeded = await action()
        isSubmitting = false
        didSucceed = succeeded
        if !succeeded {
            message = messageOnFailure
        }
    }
}

private struct IMConversationRow: View {
    let conversation: IMConversation
    let identity: IMConversationIdentityPresentation
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            if conversation.kind == .direct {
                UserAvatarView(
                    displayName: identity.title,
                    email: conversation.directPeer?.email,
                    avatarPreset: conversation.directPeer?.avatarPreset,
                    size: 48
                )
            } else {
                Text(avatarText)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(avatarColor))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(identity.title)
                        .font(.body.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if conversation.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if conversation.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(conversation.lastMessagePreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if conversation.isDirectMessagingFrozen {
                    Text("已冻结")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .accessibilityLabel(conversation.directMessagingStatusMessage ?? "已冻结")
                }

                if let rowSecondaryLabel = identity.rowSecondaryLabel {
                    Text(rowSecondaryLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .trailing, spacing: 8) {
                if conversation.unreadCount > 0 {
                    Text("\(conversation.unreadCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.red))
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var avatarText: String {
        let trimmed = identity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "IM"
        }

        return String(trimmed.prefix(2)).uppercased()
    }

    private var avatarColor: Color {
        switch conversation.avatarPreset {
        case .sunrise:
            return .orange
        case .ocean:
            return .blue
        case .forest:
            return .green
        case .graphite:
            return .gray
        case nil:
            break
        }

        if conversation.unreadCount > 0 {
            return .accentColor
        }

        return isActive ? .blue : Color(.systemGray3)
    }
}

private extension IMConversationMemberRole {
    var displayName: String {
        switch self {
        case .owner:
            return "群主"
        case .admin:
            return "管理员"
        case .member:
            return "成员"
        }
    }
}

private extension IMConversationAvatarPreset {
    var displayName: String {
        switch self {
        case .sunrise:
            return "日出"
        case .ocean:
            return "海洋"
        case .forest:
            return "森林"
        case .graphite:
            return "石墨"
        }
    }
}

private struct IMConversationEmptyState: View {
    let onCreateConversation: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "message.badge.circle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)

            Text("还没有可用会话")
                .font(.headline)

            Text("这里会直接展示服务端会话列表。先创建一个会话，或者下拉刷新等待后端返回数据。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("创建会话") {
                onCreateConversation()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

private enum IMMediaDownloadState: Equatable {
    case idle
    case downloading(progress: FileTransferProgress?)
    case paused(progress: FileTransferProgress?)
    case downloaded(URL)
    case failed(String)
}

private extension IMMediaAssetKind {
    var displayName: String {
        switch self {
        case .image:
            return "图片"
        case .audio:
            return "音频"
        case .file:
            return "文件"
        }
    }
}

private struct IMDownloadedMediaPreviewItem: Identifiable, Equatable {
    let url: URL
    let title: String

    var id: String { url.absoluteString }
}

private struct IMDownloadedMediaQuickLookSheet: UIViewControllerRepresentable {
    let item: IMDownloadedMediaPreviewItem

    func makeCoordinator() -> Coordinator {
        Coordinator(item: item)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.title = item.title
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.item = item
        controller.title = item.title
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var item: IMDownloadedMediaPreviewItem

        init(item: IMDownloadedMediaPreviewItem) {
            self.item = item
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            item.url as NSURL
        }
    }
}

private struct IMDetailEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            Text("会话里还没有消息")
                .font(.headline)

            Text("第一条消息发出后，这里会开始按时间线展示历史记录。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }
}

private struct IMConnectionSummaryCard: View {
    let title: String
    let message: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct IMInlineStatusBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct IMConversationQueueBanner: View {
    let summary: IMConversationQueueSummary
    let isFlushing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var title: String {
        if isFlushing && (summary.queuedCount > 0 || summary.sendingCount > 0) {
            return "正在发送待发送消息..."
        }

        if summary.queuedCount > 0 {
            return "有 \(summary.queuedCount) 条待发送"
        }

        if summary.sendingCount > 0 {
            return "\(summary.sendingCount) 条正在发送"
        }

        return "\(summary.retryableIssueCount) 条未确认/发送失败"
    }

    private var detailText: String {
        var parts: [String] = []

        if summary.queuedCount > 0 {
            parts.append("连接恢复后自动发送")
        }

        if summary.sendingCount > 0 {
            parts.append("\(summary.sendingCount) 条正在发送")
        }

        if summary.retryableIssueCount > 0 {
            parts.append("\(summary.retryableIssueCount) 条未确认/发送失败，可点消息重试")
        }

        return parts.joined(separator: "，")
    }

    private var iconName: String {
        if isFlushing && (summary.queuedCount > 0 || summary.sendingCount > 0) {
            return "paperplane.circle.fill"
        }

        if summary.retryableIssueCount > 0 && summary.queuedCount == 0 && summary.sendingCount == 0 {
            return "exclamationmark.triangle.fill"
        }

        return "tray.and.arrow.up.fill"
    }

    private var tint: Color {
        if summary.retryableIssueCount > 0 && summary.queuedCount == 0 && summary.sendingCount == 0 {
            return .orange
        }

        return .blue
    }
}

private struct IMMessageBubble: View {
    private static let reactionEmojiOptions = ["👍", "❤️", "😂", "😮", "👎"]

    let message: IMConversationMessage
    let replyReference: IMReplyReferenceResolution?
    let isHighlighted: Bool
    let canRetry: Bool
    let canCancel: Bool
    let canReply: Bool
    let canRecall: Bool
    let canEdit: Bool
    let canReact: Bool
    let mediaDownloadState: IMMediaDownloadState?
    let currentUserID: UUID?
    let onJumpToReplyReference: () -> Void
    let onCancel: () -> Void
    let onReply: () -> Void
    let onEdit: () -> Void
    let onRecall: () -> Void
    let onRetry: () -> Void
    let onToggleReaction: (String) -> Void
    let onDownloadMedia: () -> Void
    let onCancelMediaDownload: () -> Void
    let onRetryMediaDownload: () -> Void
    let onOpenDownloadedMedia: (URL) -> Void
    let onDeleteDownloadedMedia: () -> Void

    var body: some View {
        if case .system(let event) = message.content {
            Text(event.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        } else {
        HStack {
            if message.direction == .outgoing {
                Spacer(minLength: 24)
            }

            VStack(alignment: .leading, spacing: 6) {
                messageBody

                if !message.derivedState.reactions.isEmpty {
                    reactionRow
                }

                HStack(spacing: 8) {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    Text(deliveryText)
                    if !message.derivedState.edits.isEmpty {
                        Text("已编辑")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if canCancel {
                    Button {
                        onCancel()
                    } label: {
                        Label("取消发送", systemImage: "xmark.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if canRecall {
                    Button {
                        onRecall()
                    } label: {
                        Label("撤回", systemImage: "arrow.uturn.backward.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if canRetry {
                    Button {
                        onRetry()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(bubbleColor)
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.accentColor.opacity(0.45), lineWidth: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contextMenu {
                if canReply {
                    Button("回复", systemImage: "arrowshape.turn.up.left") {
                        onReply()
                    }
                }

                if canEdit {
                    Button("编辑", systemImage: "square.and.pencil") {
                        onEdit()
                    }
                }

                if canReact {
                    ForEach(Self.reactionEmojiOptions, id: \.self) { emoji in
                        Button(emoji) {
                            onToggleReaction(emoji)
                        }
                    }
                }

                if canRecall {
                    Button("撤回", systemImage: "arrow.uturn.backward.circle") {
                        onRecall()
                    }
                }
            }

            if message.direction == .incoming {
                Spacer(minLength: 24)
            }
        }
        }
    }

    private var bubbleColor: Color {
        switch message.direction {
        case .incoming:
            return Color(.secondarySystemGroupedBackground)
        case .outgoing:
            return Color.accentColor.opacity(0.16)
        }
    }

    private var deliveryText: String {
        switch message.deliveryState {
        case .preparing(let message):
            return "准备中: \(message)"
        case .uploading(let message):
            return "上传中: \(message)"
        case .uploaded:
            return "上传完成"
        case .queued(let message):
            return "待发送: \(message)"
        case .sending:
            return "发送中"
        case .sent:
            return "已送达"
        case .received:
            return "已接收"
        case .unknown(let message):
            return "未确认: \(message)"
        case .failed(let message):
            return "失败: \(message)"
        }
    }

    @ViewBuilder
    private var messageBody: some View {
        let aggregate = message.aggregate
        let presentation = MessagePresentation(aggregate: aggregate)

        switch aggregate.primaryContent {
        case .text:
            Text(presentation.textValue ?? message.text)
                .font(.body)
        case .reply:
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onJumpToReplyReference) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("回复")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if replyReference?.state == .recalled {
                            Text(replyReference?.text ?? "原消息暂不可用")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .italic()
                                .lineLimit(2)
                        } else {
                            Text(replyReference?.text ?? "原消息暂不可用")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Text(presentation.textValue ?? message.text)
                    .font(.body)
            }
        case .image(let asset):
            mediaBubble(
                title: asset.filename,
                subtitle: mediaSubtitle(for: asset)
            ) {
                Label("图片", systemImage: "photo")
                    .font(.headline)
            }
        case .audio(let asset):
            mediaBubble(
                title: asset.filename,
                subtitle: mediaSubtitle(for: asset)
            ) {
                Label("语音", systemImage: "waveform")
                    .font(.headline)
            }
        case .file(let asset):
            mediaBubble(
                title: asset.filename,
                subtitle: mediaSubtitle(for: asset)
            ) {
                Label("文件", systemImage: "doc")
                    .font(.headline)
            }
        case nil:
            Text(message.direction == .outgoing ? "你撤回了一条消息" : "对方撤回了一条消息")
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
        case .system:
            EmptyView()
        }
    }

    private var reactionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(message.derivedState.reactions, id: \.emoji) { reaction in
                    let didReact = currentUserID.map(reaction.actorUserIDs.contains) ?? false
                    HStack(spacing: 4) {
                        Text(reaction.emoji)
                        Text("\(reaction.actorUserIDs.count)")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(didReact ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemGroupedBackground))
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func mediaBubble<Header: View>(
        title: String,
        subtitle: String,
        @ViewBuilder header: () -> Header
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header()
            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(2)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            mediaDownloadControls
        }
    }

    @ViewBuilder
    private var mediaDownloadControls: some View {
        switch mediaDownloadState ?? .idle {
        case .idle:
            Button {
                onDownloadMedia()
            } label: {
                Label("下载附件", systemImage: "arrow.down.circle")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let fractionCompleted = progress?.fractionCompleted {
                        ProgressView(value: fractionCompleted)
                            .controlSize(.small)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(downloadStatusText(for: progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    onCancelMediaDownload()
                } label: {
                    Label("暂停下载", systemImage: "pause.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .paused(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text(pausedStatusText(for: progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        onDownloadMedia()
                    } label: {
                        Label("继续下载", systemImage: "arrow.clockwise.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        onDeleteDownloadedMedia()
                    } label: {
                        Label("重新开始", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        case .downloaded(let fileURL):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label("已下载", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)

                    Text(fileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Button {
                        onOpenDownloadedMedia(fileURL)
                    } label: {
                        Label("打开预览", systemImage: "eye")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    ShareLink(item: fileURL) {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        onDeleteDownloadedMedia()
                    } label: {
                        Label("删除", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onRetryMediaDownload()
                } label: {
                    Label("重试下载", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func downloadStatusText(for progress: FileTransferProgress?) -> String {
        guard let progress else {
            return "正在下载…"
        }

        if let fractionCompleted = progress.fractionCompleted {
            let percentage = Int((fractionCompleted * 100).rounded())
            return "下载中 \(percentage)%"
        }

        return "已接收 \(ByteCountFormatter.string(fromByteCount: progress.transferredBytes, countStyle: .file))"
    }

    private func pausedStatusText(for progress: FileTransferProgress?) -> String {
        guard let progress else {
            return "下载已暂停"
        }

        if let fractionCompleted = progress.fractionCompleted {
            let percentage = Int((fractionCompleted * 100).rounded())
            return "下载已暂停 \(percentage)%"
        }

        return "已暂停，已接收 \(ByteCountFormatter.string(fromByteCount: progress.transferredBytes, countStyle: .file))"
    }

    private func mediaSubtitle(for asset: IMMediaAsset) -> String {
        var parts: [String] = []
        if asset.byteSize > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            parts.append(formatter.string(fromByteCount: asset.byteSize))
        }
        if let width = asset.width, let height = asset.height {
            parts.append("\(width)×\(height)")
        }
        if let durationMillis = asset.durationMillis, durationMillis > 0 {
            parts.append(formatDuration(durationMillis))
        }
        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ durationMillis: Int) -> String {
        let totalSeconds = max(0, durationMillis / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private extension IMConversationMessage {
    enum RecallRule {
        static let window: TimeInterval = 2 * 60
    }

    var canCancelQueuedSend: Bool {
        guard direction == .outgoing, content.isUserComposable else {
            return false
        }

        if case .queued = deliveryState {
            return true
        }

        return false
    }

    var canReply: Bool {
        guard serverSequence != nil else {
            return false
        }

        switch content {
        case .text, .reply, .image, .audio, .file:
            return true
        case .recalled, .system:
            return false
        }
    }

    var canRecall: Bool {
        guard direction == .outgoing,
              serverMessageID != nil || serverSequence != nil,
              Date().timeIntervalSince(createdAt) <= RecallRule.window
        else {
            return false
        }

        switch content {
        case .text, .reply, .image, .audio, .file:
            return true
        case .recalled, .system:
            return false
        }
    }

    var canEdit: Bool {
        guard direction == .outgoing,
              serverMessageID != nil || serverSequence != nil,
              !derivedState.isRecalled
        else {
            return false
        }

        switch content {
        case .text, .reply:
            return true
        case .image, .audio, .file, .recalled, .system:
            return false
        }
    }

    var canReact: Bool {
        guard serverMessageID != nil || serverSequence != nil, !derivedState.isRecalled else {
            return false
        }

        switch content {
        case .text, .reply, .image, .audio, .file:
            return true
        case .recalled, .system:
            return false
        }
    }
}
