import SwiftUI
import IMClientKit

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
                if conversationStore.conversations.isEmpty {
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

                    ForEach(conversationStore.conversations) { conversation in
                        Button {
                            onOpenConversation(conversation.id)
                        } label: {
                            IMConversationRow(
                                conversation: conversation,
                                isActive: conversation.id == conversationStore.selectedConversationID
                            )
                        }
                        .buttonStyle(.plain)
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
            return "当前只有 HTTP 登录态，实时消息不会到达，发送也会直接失败。"
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
    @State private var isPresentingLeaveConfirmation = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    conversationSummaryCard

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
                            IMMessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(conversation?.title ?? "会话")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: conversationID) {
                await authManager.openIMConversation(conversationID)
            }
            .toolbar {
                if conversation?.kind == .group {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("添加成员") {
                                isPresentingAddMembers = true
                            }

                            Button("退出会话", role: .destructive) {
                                isPresentingLeaveConfirmation = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
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

    private var conversationSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(conversationInitials)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.accentColor))

                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation?.title ?? "会话")
                        .font(.headline)

                    Text(memberSummary)
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
            }
            .font(.caption)
            .foregroundStyle(.secondary)

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
            Divider()

            HStack(alignment: .bottom, spacing: 12) {
                TextField("输入消息", text: $composerText, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                Button {
                    Task {
                        let didSend = await authManager.sendIMText(composerText, to: conversationID)
                        if didSend {
                            composerText = ""
                        }
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(.thinMaterial)
    }

    private var memberSummary: String {
        if let conversation, !conversation.members.isEmpty {
            return conversation.members.map(\.email).joined(separator: "、")
        }

        if let conversation, conversation.memberCount > 0 {
            return "\(conversation.memberCount) 位成员"
        }

        if let conversation, !conversation.memberUserIDs.isEmpty {
            return "\(conversation.memberUserIDs.count) 位成员"
        }

        if conversationStore.isLoadingMembers {
            return "正在加载成员信息"
        }

        return "当前还没有成员信息"
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
        let trimmed = (conversation?.title ?? "会话").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "IM"
        }

        return String(trimmed.prefix(2)).uppercased()
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

private struct IMConversationRow: View {
    let conversation: IMConversation
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
                    Text(conversation.title)
                        .font(.body.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(conversation.lastMessagePreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if !conversation.members.isEmpty {
                    Text(conversation.members.map(\.email).joined(separator: "、"))
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
        let trimmed = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "IM"
        }

        return String(trimmed.prefix(2)).uppercased()
    }

    private var avatarColor: Color {
        if conversation.unreadCount > 0 {
            return .accentColor
        }

        return isActive ? .blue : Color(.systemGray3)
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

private struct IMMessageBubble: View {
    let message: IMConversationMessage

    var body: some View {
        HStack {
            if message.direction == .outgoing {
                Spacer(minLength: 24)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                    .font(.body)

                HStack(spacing: 8) {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    Text(deliveryText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(bubbleColor)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if message.direction == .incoming {
                Spacer(minLength: 24)
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
        case .sending:
            return "发送中"
        case .sent:
            return "已送达"
        case .received:
            return "已接收"
        case .failed(let message):
            return "失败: \(message)"
        }
    }
}
