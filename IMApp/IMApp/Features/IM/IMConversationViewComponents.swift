import IMClientKit
import Combine
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
import CoreImage
#endif

struct IMConversationMessageSearchSheet: View {
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

struct DirectPeerRelationshipActionPanel: View {
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

enum IMCreateConversationMode: String, CaseIterable, Identifiable {
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

struct IMCreateConversationSheet: View {
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

struct IMAddConversationMembersSheet: View {
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

struct IMRenameConversationSheet: View {
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

struct IMEditConversationMetadataSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var submitter = IMAsyncSubmitter()

    let initialTitle: String
    let initialNotice: String
    let initialAvatarPreset: IMConversationAvatarPreset
    let initialMuteAll: Bool
    let onSubmit: (String?, String?, IMConversationAvatarPreset, Bool) async -> Bool

    @State private var title = ""
    @State private var notice = ""
    @State private var avatarPreset: IMConversationAvatarPreset = .ocean
    @State private var muteAll = false

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

            Section("发言权限") {
                Toggle("全员禁言", isOn: $muteAll)
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
                muteAll = initialMuteAll
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
                                    avatarPreset,
                                    muteAll
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

struct IMGroupInviteManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var submitter = IMAsyncSubmitter()

    let conversationID: String
    let loadInvites: () async -> [IMGroupInviteResponseBody]
    let createInvite: () async -> IMGroupInviteResponseBody?
    let revokeInvite: (String) async -> Bool

    @State private var invites: [IMGroupInviteResponseBody] = []
    @State private var isLoading = false

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        await submitter.run(messageOnFailure: "创建邀请链接失败。") {
                            if let invite = await createInvite() {
                                invites.insert(invite, at: 0)
                                return true
                            }
                            return false
                        }
                    }
                } label: {
                    Label("创建邀请链接", systemImage: "link.badge.plus")
                }
            }

            Section("邀请链接") {
                if isLoading {
                    ProgressView()
                } else if invites.isEmpty {
                    Text("暂无邀请链接。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(invites, id: \.token) { invite in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                IMInviteQRCodeView(text: invite.inviteURL)
                                    .frame(width: 72, height: 72)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(invite.revokedAt == nil ? "可用邀请" : "已撤销")
                                        .font(.headline)
                                    Text(invite.inviteURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text("使用 \(invite.useCount) 次 · \(invite.expiresAt.formatted(date: .abbreviated, time: .shortened)) 过期")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            HStack {
                                Button {
#if canImport(UIKit)
                                    UIPasteboard.general.string = invite.inviteURL
#endif
                                    submitter.message = "已复制邀请链接。"
                                } label: {
                                    Label("复制", systemImage: "doc.on.doc")
                                }

                                if invite.revokedAt == nil {
                                    Button(role: .destructive) {
                                        Task {
                                            await submitter.run(messageOnFailure: "撤销邀请失败。") {
                                                await revokeInvite(invite.token)
                                            }
                                            await reload()
                                        }
                                    } label: {
                                        Label("撤销", systemImage: "xmark.circle")
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 6)
                    }
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
        .navigationTitle("邀请链接")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        invites = await loadInvites()
    }
}

struct IMMemberNicknameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var submitter = IMAsyncSubmitter()

    let initialNickname: String
    let onSubmit: (String?) async -> Bool

    @State private var nickname = ""

    var body: some View {
        Form {
            Section("群昵称") {
                TextField("留空使用资料名", text: $nickname)
                    .textInputAutocapitalization(.never)
            }

            if let message = submitter.message, !message.isEmpty {
                Section {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("我的群昵称")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if nickname.isEmpty {
                nickname = initialNickname
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
                            let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                            await submitter.run(messageOnFailure: "保存群昵称失败。") {
                                await onSubmit(trimmed.isEmpty ? nil : trimmed)
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

struct IMInviteQRCodeView: View {
    let text: String

    var body: some View {
#if canImport(UIKit)
        if let image = qrImage {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
#else
        Image(systemName: "qrcode")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
#endif
    }

#if canImport(UIKit)
    private var qrImage: UIImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else {
            return nil
        }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
#endif
}

struct IMManageConversationMembersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var submitter = IMAsyncSubmitter()

    @ObservedObject var conversationStore: IMConversationStore
    let conversationID: String
    let currentUserID: UUID?
    let onPromoteAdmin: (UUID) async -> Bool
    let onDemoteAdmin: (UUID) async -> Bool
    let onTransferOwner: (UUID) async -> Bool
    let onRemoveMember: (UUID) async -> Bool
    let onSearchMembers: (String) async -> Void
    let onLoadMoreMembers: () async -> Void
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            if let conversation {
                Section {
                    TextField("搜索成员", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("成员 \(loadedMemberCount) / \(memberTotal) 人")
                }

                Section {
                    ForEach(displayMembers) { member in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(member.displayTitle)
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

                                Text("\(member.role.displayName) · \(member.email)")
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
                                                    let succeeded = await item.action()
                                                    if succeeded {
                                                        await refreshCurrentQuery()
                                                    }
                                                    return succeeded
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("群主可以设置管理员、转让群主并移除成员；管理员只能移除普通成员。")
                        if pageState.isLoading {
                            ProgressView()
                        } else if pageState.canLoadMore {
                            Button(pageState.isLoadingMore ? "加载中..." : "加载更多") {
                                Task {
                                    await onLoadMoreMembers()
                                }
                            }
                            .disabled(pageState.isLoadingMore)
                        }
                    }
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
        .task {
            await refreshCurrentQuery()
        }
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else {
                    return
                }
                await onSearchMembers(newValue)
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
    }

    private var pageState: IMConversationMemberPageState {
        conversationStore.memberPageState(for: conversationID)
    }

    private var displayMembers: [IMConversationMember] {
        if pageState.query == query.trimmingCharacters(in: .whitespacesAndNewlines) {
            return pageState.items
        }
        return conversation?.members ?? []
    }

    private var loadedMemberCount: Int {
        displayMembers.count
    }

    private var memberTotal: Int {
        pageState.total > 0 ? pageState.total : conversation?.memberCount ?? 0
    }

    private var conversation: IMConversation? {
        conversationStore.conversations.first(where: { $0.id == conversationID })
    }

    private var currentRole: IMConversationMemberRole? {
        guard let currentUserID else {
            return nil
        }

        return displayMembers.first(where: { $0.id == currentUserID })?.role
            ?? conversation?.members.first(where: { $0.id == currentUserID })?.role
    }

    private func refreshCurrentQuery() async {
        await onSearchMembers(query)
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

struct MemberActionItem: Identifiable {
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
final class IMAsyncSubmitter: ObservableObject {
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

struct IMConversationRow: View {
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

extension IMConversationMemberRole {
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

extension IMConversationAvatarPreset {
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

struct IMConversationEmptyState: View {
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

enum IMMediaDownloadState: Equatable {
    case idle
    case downloading(progress: FileTransferProgress?)
    case paused(progress: FileTransferProgress?)
    case downloaded(URL)
    case failed(String)
}

extension IMMediaAssetKind {
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

struct IMDownloadedMediaPreviewItem: Identifiable, Equatable {
    let url: URL
    let title: String

    var id: String { url.absoluteString }
}

struct IMDownloadedMediaQuickLookSheet: UIViewControllerRepresentable {
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

struct IMDetailEmptyState: View {
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

struct IMConnectionSummaryCard: View {
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

struct IMInlineStatusBanner: View {
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

struct IMConversationQueueBanner: View {
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

struct IMMessageBubble: View {
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
    let deliveryOverrideText: String?
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
                    if let deliveryDisplay {
                        Label(deliveryDisplay.text, systemImage: deliveryDisplay.icon)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(deliveryDisplay.tint)
                            .lineLimit(1)
                    }
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

    private var deliveryDisplay: (icon: String, text: String, tint: Color)? {
        guard message.direction == .outgoing else {
            return nil
        }

        if let deliveryOverrideText {
            return ("checkmark.circle", deliveryOverrideText, .secondary)
        }

        switch message.deliveryState {
        case .preparing(let message):
            return ("clock", shortStatus("准备中", detail: message), .secondary)
        case .uploading(let message):
            return ("icloud.and.arrow.up", shortStatus("上传中", detail: message), .blue)
        case .uploaded:
            return ("icloud.and.arrow.up.fill", "上传完成", .blue)
        case .queued(let message):
            return ("clock.badge.exclamationmark", shortStatus("待发送", detail: message), .orange)
        case .sending:
            return ("paperplane", "发送中", .secondary)
        case .sent:
            return ("checkmark", "已发送", .secondary)
        case .received:
            return ("checkmark.circle", "已送达", .secondary)
        case .unknown(let message):
            return ("questionmark.circle", shortStatus("未确认", detail: message), .orange)
        case .failed(let message):
            return ("exclamationmark.circle.fill", shortStatus("失败", detail: message), .red)
        }
    }

    private func shortStatus(_ prefix: String, detail: String) -> String {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDetail.isEmpty else {
            return prefix
        }
        return "\(prefix): \(trimmedDetail)"
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

extension IMConversationMessage {
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
