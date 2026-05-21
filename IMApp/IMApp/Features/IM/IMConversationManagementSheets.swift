import IMClientKit
import Combine
import SwiftUI
#if canImport(UIKit)
import UIKit
import CoreImage
#endif

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
