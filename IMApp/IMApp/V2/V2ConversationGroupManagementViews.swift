import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI
import UIKit

/// 会话详情内的群公告横幅。
///
/// 展示最新公告摘要，点击后进入编辑页；横幅本身不发起网络请求。
struct V2GroupAnnouncementBanner: View {
    let announcement: V2ClientGroupAnnouncement
    let edit: () -> Void

    var body: some View {
        Button(action: edit) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "megaphone.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("群公告")
                        .font(.caption.weight(.semibold))
                    Text(announcement.body)
                        .font(.subheadline)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityLabel("群公告")
        .accessibilityValue(announcement.body)
        .accessibilityHint("打开群公告详情")
        .accessibilityIdentifier("v2.group.announcement.banner")
    }
}

/// 群公告编辑页。
///
/// 保存前只做长度与空内容校验，最终权限与版本冲突仍由服务端裁决。
struct V2GroupAnnouncementSheet: View {
    @Bindable var store: V2ConversationDetailStore
    @Environment(\.dismiss) private var dismiss
    @State private var announcementText: String

    init(store: V2ConversationDetailStore) {
        self.store = store
        _announcementText = State(initialValue: store.groupAnnouncement?.body ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("公告内容") {
                    TextEditor(text: $announcementText)
                        .frame(minHeight: 160)
                        .accessibilityLabel("群公告内容")
                        .accessibilityIdentifier("v2.group.announcement.body")
                    Text("最多 \(V2GroupAnnouncementCommand.maximumUTF8Bytes) 字节；最终权限与版本冲突由服务端处理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let feedback = store.messageActionFeedback {
                    Section { Text(feedback).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("群公告")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("v2.group.announcement.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let updatedBody = announcementText
                        Task {
                            if await store.saveGroupAnnouncement(updatedBody) { dismiss() }
                        }
                    }
                    .disabled(announcementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSavingGroupAnnouncement)
                    .accessibilityValue(store.isSavingGroupAnnouncement ? "正在保存群公告" : "")
                    .accessibilityIdentifier("v2.group.announcement.save")
                }
            }
        }
    }
}

/// 群权限编辑页。
///
/// 按角色（管理员/普通成员）分别编辑权限集合，
/// 并以策略修订作为乐观并发栅栏提交。
struct V2GroupPermissionsSheet: View {
    @Bindable var store: V2ConversationDetailStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRole: V2RoomMembershipRole = .admin
    @State private var selectedPermissions: Set<V2GroupPermission> = []
    @State private var editingPolicy: V2ClientGroupRolePolicy?

    var body: some View {
        NavigationStack {
            Form {
                if store.isLoadingGroupRolePolicies || store.isLoadingGroupMembers {
                    Section { ProgressView("正在读取群权限…") }
                } else {
                    Section("角色") {
                        Picker("编辑角色", selection: $selectedRole) {
                            Text("管理员").tag(V2RoomMembershipRole.admin)
                            Text("普通成员").tag(V2RoomMembershipRole.member)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedRole) { _, _ in loadSelectedPolicy() }
                        if let editingPolicy {
                            Text("当前策略版本 \(editingPolicy.revision)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if selectedPolicy != editingPolicy {
                                Button("重新载入最新权限") { loadSelectedPolicy() }
                            }
                        }
                    }
                    recoverySection
                    Section("允许的操作") {
                        ForEach(V2GroupPermission.allCases, id: \.self) { permission in
                            Toggle(permission.title, isOn: binding(for: permission))
                                .disabled(!canEditPolicy)
                                .accessibilityIdentifier("v2.group.permission.\(selectedRole.rawValue).\(permission.rawValue)")
                        }
                    }
                    if store.groupActorRole != "群主" {
                        Section {
                            Text("只有群主可以提交角色权限策略；服务端也会再次验证权限和版本。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let feedback = store.messageActionFeedback {
                        Section { Text(feedback).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("群权限")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("v2.group.permissions.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let policy = editingPolicy else { return }
                        let permissions = selectedPermissions
                        Task {
                            if await store.saveGroupRolePolicy(policy, permissions: permissions) { dismiss() }
                        }
                    }
                    .disabled(!canEditPolicy || store.isSavingGroupRolePolicy || store.groupActorRole != "群主")
                    .accessibilityValue(store.isSavingGroupRolePolicy ? "正在保存群权限策略" : "")
                    .accessibilityIdentifier("v2.group.permissions.save")
                }
            }
            .onChange(of: store.groupRolePolicyState) { _, _ in
                if selectedPolicy == nil || store.groupRolePolicyState.recovery == .unavailable {
                    editingPolicy = nil
                    selectedPermissions = []
                } else if editingPolicy == nil { loadSelectedPolicy() }
            }
            .task {
                await store.loadGroupRolePolicies()
                await store.loadGroupMembers(reset: true)
                loadSelectedPolicy()
            }
        }
    }

    private var canEditPolicy: Bool {
        switch store.groupRolePolicyState.recovery {
        case .unavailable, .waitingForSynchronization: false
        default: editingPolicy != nil
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        if store.groupRolePolicyState.recovery != .ready {
            Section("权限同步") {
                switch store.groupRolePolicyState.recovery {
                case .unavailable:
                    Text("当前无法读取此群的权限。")
                case .waitingForSynchronization:
                    Text("正在同步会话，完成后将继续获取权限。")
                case .needed:
                    Text("尚未取得完整权限策略。")
                    retryRecoveryButton
                case .pending:
                    Text("权限同步请求已保存，连接可用后会继续。")
                case .paused:
                    Text("权限同步已暂停，请重试。")
                    retryRecoveryButton
                case .ready:
                    EmptyView()
                }
                if store.policyRecoveryAction == .failed {
                    Text("暂时无法确认同步状态，请重试。")
                }
            }
            .accessibilityIdentifier("v2.group.permissions.recovery")
        }
    }

    private var retryRecoveryButton: some View {
        Button("请求同步权限") { Task { await store.retryGroupRolePolicyRecovery() } }
            .disabled(store.policyRecoveryAction == .requesting)
            .accessibilityValue(store.policyRecoveryAction == .requesting ? "正在请求同步" : "")
            .accessibilityHint("请求更新此群的权限策略")
            .accessibilityIdentifier("v2.group.permissions.retry-recovery")
    }

    private var selectedPolicy: V2ClientGroupRolePolicy? {
        store.groupRolePolicies.first(where: { $0.role == selectedRole })
    }

    private func binding(for permission: V2GroupPermission) -> Binding<Bool> {
        .init(
            get: { selectedPermissions.contains(permission) },
            set: { isAllowed in
                if isAllowed { selectedPermissions.insert(permission) }
                else { selectedPermissions.remove(permission) }
            }
        )
    }

    private func loadSelectedPolicy() {
        editingPolicy = selectedPolicy
        selectedPermissions = editingPolicy?.permissions ?? []
    }
}

private extension V2GroupPermission {
    var title: String {
        switch self {
        case .sendMessages: "发送消息"
        case .inviteMembers: "邀请成员"
        case .removeMembers: "移除成员"
        case .changeMemberRoles: "修改成员角色"
        case .pinMessages: "置顶消息"
        case .manageAnnouncements: "管理群公告"
        case .moderateMessages: "审核消息"
        case .muteMembers: "禁言成员"
        }
    }
}

/// 单条消息的群已读详情页。
///
/// 展示已读成员列表并支持按游标继续加载。
struct V2GroupReadReceiptsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem
    @State private var profilePageID = UUID()
    @State private var readRequest = ReadRequest(reset: true)

    private struct ReadRequest: Equatable {
        let id = UUID()
        let reset: Bool
    }

    var body: some View {
        NavigationStack {
            Group {
                if let page = store.groupReadReceiptPage, page.messageID.rawValue == message.id {
                    List {
                        Section("已读成员") {
                            if store.hasEarlierGroupReadReceipts {
                                Button("返回列表开头") { readRequest = .init(reset: true) }
                            }
                            ForEach(page.readers, id: \.userID) { reader in
                                if let key = store.groupPresentationKey(for: reader.userID) {
                                    V2AuthorizedAvatarView(key: key, showsName: true)
                                        .accessibilityValue("已读")
                                }
                            }
                            if page.nextCursor != nil {
                                Button("加载更多") { readRequest = .init(reset: false) }
                                    .disabled(store.isLoadingGroupReadReceipts)
                                    .accessibilityIdentifier("v2.message.group-readers.more.\(message.id)")
                            }
                        }
                    }
                } else if store.isLoadingGroupReadReceipts {
                    ProgressView("正在读取已读详情…")
                } else if let feedback = store.groupReadReceiptFeedback {
                    ContentUnavailableView("无法读取已读详情", systemImage: "exclamationmark.triangle", description: Text(feedback))
                } else {
                    ContentUnavailableView("暂无已读记录", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("已读详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("刷新") { readRequest = .init(reset: true) }
                        .disabled(store.isLoadingGroupReadReceipts)
                }
            }
            .task(id: readRequest) { await store.loadGroupReadReceipts(for: message, reset: readRequest.reset) }
        }
        .id(message.id)
        .authorPresentationPage(context: .list(profilePageID))
    }
}

/// 群成员管理页。
///
/// 提供成员列表、成员增删与角色调整入口，所有变更都以任务串行化。
struct V2GroupMembersSheet: View {
    @Bindable var store: V2ConversationDetailStore
    @Environment(\.dismiss) private var dismiss
    @State private var newMemberUserID = ""
    @State private var membershipChangeTask: Task<Void, Never>?
    @State private var moderationTask: Task<Void, Never>?
    @State private var pendingModeratedRemoval: V2GroupMemberItem?
    @State private var profilePageID = UUID()

    var body: some View {
        NavigationStack {
            List {
                if let revision = store.groupMemberRevision {
                    Text("成员版本 \(revision)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if store.canAddGroupMembers {
                    Section("添加成员") {
                        TextField("成员公开 ID（@handle）", text: $newMemberUserID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(
                                store.isLoadingGroupMembers
                                    || store.isChangingGroupMembership
                                    || store.isApplyingGroupModeration
                            )
                            .accessibilityIdentifier("v2.group.members.add-input")
                        Button("添加") {
                            let target = newMemberUserID
                            newMemberUserID = ""
                            runMembershipChange(target: target, action: .add)
                        }
                        .disabled(
                            store.isLoadingGroupMembers
                                || store.isChangingGroupMembership
                                || store.isApplyingGroupModeration
                                || newMemberUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .accessibilityValue(
                            store.isChangingGroupMembership || store.isApplyingGroupModeration
                                ? "正在保存成员变更"
                                : ""
                        )
                        .accessibilityIdentifier("v2.group.members.add")
                    }
                }
                if store.groupActorRole == "群主" || store.groupActorRole == "管理员" {
                    Section {
                        Text("禁言和管理员移除会以独立的可审计命令保存；网络中断时会自动重试。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if store.hasEarlierGroupMembers {
                    Button("返回成员列表开头") { Task { await store.loadGroupMembers(reset: true) } }
                }
                ForEach(store.groupMembers) { member in
                    HStack {
                        if let user = try? UserID(member.id), let key = store.groupPresentationKey(for: user) {
                            V2AuthorizedAvatarView(key: key, showsName: true)
                        }
                        Spacer()
                        Text(member.role).foregroundStyle(.secondary)
                        if store.canChangeGroupMemberRole(member) {
                            Menu {
                                Button("设为管理员") { runRoleChange(member, role: .admin) }
                                    .disabled(member.role == "管理员")
                                    .accessibilityIdentifier("v2.group.member.role.admin.\(member.id)")
                                Button("设为普通成员") { runRoleChange(member, role: .member) }
                                    .disabled(member.role == "成员")
                                    .accessibilityIdentifier("v2.group.member.role.member.\(member.id)")
                            } label: {
                                Image(systemName: "person.badge.key")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(.rect)
                            }
                            .disabled(store.isLoadingGroupMembers || store.isChangingGroupMembership || store.isApplyingGroupModeration)
                            .accessibilityLabel("修改此成员的角色")
                            .accessibilityHint("可设为管理员或普通成员")
                            .accessibilityIdentifier("v2.group.member.role.\(member.id)")
                        }
                        if store.canRemoveGroupMember(member) {
                            Menu {
                                Button("禁言 1 小时") {
                                    runMute(member)
                                }
                                .accessibilityIdentifier("v2.group.member.mute.\(member.id)")
                                Button("管理员移除", role: .destructive) {
                                    pendingModeratedRemoval = member
                                }
                                .accessibilityIdentifier("v2.group.member.moderated-remove.\(member.id)")
                            } label: {
                                Image(systemName: "shield")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(.rect)
                            }
                            .disabled(store.isLoadingGroupMembers || store.isChangingGroupMembership || store.isApplyingGroupModeration)
                            .accessibilityLabel("管理此成员")
                            .accessibilityHint("可禁言一小时或执行带审计记录的管理员移除")
                            .accessibilityIdentifier("v2.group.member.moderation.\(member.id)")
                            Button("移除", role: .destructive) {
                                runMembershipChange(target: member.id, action: .remove)
                            }
                            .disabled(store.isLoadingGroupMembers || store.isChangingGroupMembership || store.isApplyingGroupModeration)
                            .accessibilityValue(store.isChangingGroupMembership || store.isApplyingGroupModeration ? "正在保存成员变更" : "")
                            .accessibilityIdentifier("v2.group.member.remove.\(member.id)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("v2.group.member.\(member.id)")
                }
                if store.canLoadMoreGroupMembers {
                    Button("加载更多") { Task { await store.loadGroupMembers() } }
                        .disabled(store.isLoadingGroupMembers)
                        .accessibilityIdentifier("v2.group.members.load-more")
                }
                if let feedback = store.groupMemberFeedback {
                    Text(feedback).foregroundStyle(.secondary)
                        .onAppear { announceV2AccessibilityAnnouncement(feedback) }
                        .onChange(of: feedback) { _, updatedFeedback in
                            announceV2AccessibilityAnnouncement(updatedFeedback)
                        }
                        .accessibilityIdentifier("v2.group.members.feedback")
                }
            }
            .accessibilityIdentifier("v2.group.members.sheet")
            .overlay {
                if store.isLoadingGroupMembers, store.groupMembers.isEmpty, store.groupMemberFeedback == nil {
                    ProgressView("正在读取成员…")
                }
            }
            .navigationTitle("群成员")
            .onDisappear {
                membershipChangeTask?.cancel()
                moderationTask?.cancel()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("v2.group.members.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("刷新") { Task { await store.loadGroupMembers(reset: true) } }
                        .disabled(store.isLoadingGroupMembers)
                        .accessibilityValue(store.isLoadingGroupMembers ? "正在读取成员" : "")
                }
            }
            .task { await store.loadGroupMembers(reset: true) }
            .sheet(item: $pendingModeratedRemoval) { member in
                V2GroupMemberRemovalConfirmation(key: (try? UserID(member.id)).flatMap(store.groupPresentationKey)) {
                    pendingModeratedRemoval = nil
                    runModeratedRemoval(member)
                }
            }
        }
        .authorPresentationPage(context: .list(profilePageID))
    }

    private func runMembershipChange(target: String, action: V2RoomMembershipAction) {
        guard membershipChangeTask == nil else { return }
        membershipChangeTask = Task {
            await store.changeGroupMembership(targetUserID: target, action: action)
            guard !Task.isCancelled else { return }
            membershipChangeTask = nil
        }
    }

    private func runRoleChange(_ member: V2GroupMemberItem, role: V2RoomMembershipRole) {
        guard membershipChangeTask == nil else { return }
        membershipChangeTask = Task {
            await store.changeGroupMemberRole(member, to: role)
            guard !Task.isCancelled else { return }
            membershipChangeTask = nil
        }
    }

    private func runMute(_ member: V2GroupMemberItem) {
        guard moderationTask == nil else { return }
        moderationTask = Task {
            await store.muteGroupMember(member)
            guard !Task.isCancelled else { return }
            moderationTask = nil
        }
    }

    private func runModeratedRemoval(_ member: V2GroupMemberItem) {
        guard moderationTask == nil else { return }
        moderationTask = Task {
            await store.removeGroupMemberByModerator(member)
            guard !Task.isCancelled else { return }
            moderationTask = nil
        }
    }
}

/// A real sheet keeps the selected member's name reactive to lease expiry and
/// invalidation. Native confirmation text would capture a stale private string.
private struct V2GroupMemberRemovalConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profilePageID = UUID()
    let key: V2ProfileViewLookupKey?
    let remove: @MainActor () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("所选成员") {
                    if let key { V2AuthorizedAvatarView(key: key, showsName: true) }
                    else { Text("成员资料暂不可用") }
                }
                Section {
                    Text("该成员将被移出群聊，操作会写入管理员审计记录。")
                    Button("管理员移除", role: .destructive, action: remove)
                        .accessibilityIdentifier("v2.group.member.moderated-remove.confirm")
                }
            }
            .navigationTitle("确认移除成员")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .authorPresentationPage(context: .list(profilePageID))
        .presentationDetents([.medium, .large])
    }
}

/// 通过 VoiceOver 播报一条无障碍提示。
///
/// 仅在 VoiceOver 正在运行时才会发送通知，避免在未开启读屏时产生无效副作用。
///
/// - Parameter message: 待播报的文案。
@MainActor
func announceV2AccessibilityAnnouncement(_ message: String) {
    guard UIAccessibility.isVoiceOverRunning else { return }
    UIAccessibility.post(notification: .announcement, argument: message)
}
