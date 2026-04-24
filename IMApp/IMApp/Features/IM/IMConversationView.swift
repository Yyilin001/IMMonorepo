import SwiftUI
import IMClientKit
import Combine

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
    @State private var replyTarget: IMConversationMessage?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
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
                            IMMessageBubble(
                                message: message,
                                replyReference: message.resolvedReplyReference(in: messages),
                                canRetry: conversationStore.isRetryableFailure(message),
                                canCancel: message.canCancelQueuedSend,
                                canReply: message.canReply,
                                canRecall: message.canRecall,
                                onCancel: {
                                    _ = authManager.cancelQueuedIMTextMessage(
                                        localMessageID: message.id,
                                        in: conversationID
                                    )
                                },
                                onReply: {
                                    replyTarget = message
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
                                }
                            )
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(conversationIdentity.title)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: conversationID) {
                await authManager.openIMConversation(conversationID)
            }
            .toolbar {
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
            .onChange(of: latestMessageID) { _ in
                guard latestMessageID != nil else {
                    return
                }

                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(latestMessageID, anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom) {
                composerBar
            }
            .sheet(isPresented: $isPresentingAddMembers) {
                NavigationStack {
                    IMAddConversationMembersSheet(
                        conversationStore: conversationStore,
                        conversationID: conversationID
                    )
                }
                .presentationDetents([.medium])
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
            .task(id: conversationID) {
                composerText = conversationStore.draftText(for: conversationID)
            }
            .onChange(of: composerText) { _, newValue in
                conversationStore.updateDraft(newValue, for: conversationID)
            }
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
                Text(conversationInitials)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.accentColor))

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
                VStack(alignment: .leading, spacing: 8) {
                    if let replyTarget {
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
                        .padding(.top, replyTarget == nil ? 12 : 0)
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                Button {
                    Task {
                        let didSend: Bool
                        if let replyTarget,
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
                        }
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
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
        case .text, .reply, .system:
            let preview = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? "原消息暂不可用" : preview
        }
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
            Text(avatarText)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(avatarColor))

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
    let message: IMConversationMessage
    let replyReference: IMReplyReferenceResolution?
    let canRetry: Bool
    let canCancel: Bool
    let canReply: Bool
    let canRecall: Bool
    let onCancel: () -> Void
    let onReply: () -> Void
    let onRecall: () -> Void
    let onRetry: () -> Void

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

                HStack(spacing: 8) {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    Text(deliveryText)
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
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contextMenu {
                if canReply {
                    Button("回复", systemImage: "arrowshape.turn.up.left") {
                        onReply()
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
        switch message.content {
        case .text(let text):
            Text(text)
                .font(.body)
        case .reply(_, let text):
            VStack(alignment: .leading, spacing: 8) {
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
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(text)
                    .font(.body)
            }
        case .recalled:
            Text(message.direction == .outgoing ? "你撤回了一条消息" : "对方撤回了一条消息")
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
        case .system:
            EmptyView()
        }
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
        case .text, .reply:
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
        case .text, .reply:
            return true
        case .recalled, .system:
            return false
        }
    }
}
