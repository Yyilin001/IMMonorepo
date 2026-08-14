import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI
import UIKit

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

struct V2GroupPermissionsSheet: View {
    @Bindable var store: V2ConversationDetailStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRole: V2RoomMembershipRole = .admin
    @State private var selectedPermissions: Set<V2GroupPermission> = []

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
                        Text("当前策略版本 \(selectedPolicy?.revision ?? 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("允许的操作") {
                        ForEach(V2GroupPermission.allCases, id: \.self) { permission in
                            Toggle(permission.title, isOn: binding(for: permission))
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
                        guard let policy = selectedPolicy else { return }
                        let permissions = selectedPermissions
                        Task {
                            if await store.saveGroupRolePolicy(policy, permissions: permissions) { dismiss() }
                        }
                    }
                    .disabled(selectedPolicy == nil || store.isSavingGroupRolePolicy || store.groupActorRole != "群主")
                    .accessibilityValue(store.isSavingGroupRolePolicy ? "正在保存群权限策略" : "")
                    .accessibilityIdentifier("v2.group.permissions.save")
                }
            }
            .task {
                await store.loadGroupRolePolicies()
                await store.loadGroupMembers(reset: true)
                loadSelectedPolicy()
            }
        }
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
        selectedPermissions = selectedPolicy?.permissions ?? []
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

struct V2GroupReadReceiptsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem

    var body: some View {
        NavigationStack {
            Group {
                if let page = store.groupReadReceiptPage {
                    List {
                        if let readerCount = page.readerCount {
                            Section {
                                Text("\(readerCount) 人已读")
                                .accessibilityLabel("已有 \(readerCount) 人已读")
                                .accessibilityIdentifier("v2.message.group-readers.count.\(message.id)")
                            }
                        }
                        Section("已读成员") {
                            ForEach(page.readers, id: \.userID) { reader in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reader.publicIdentity?.displayName ?? "成员")
                                    if let handle = reader.publicIdentity?.handle.rawValue {
                                        Text("@\(handle)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(reader.publicIdentity?.displayName ?? "成员已读")
                            }
                            if page.nextCursor != nil {
                                Button("加载更多") { Task { await store.loadGroupReadReceipts(for: message) } }
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
            }
            .task(id: message.id) { await store.loadGroupReadReceipts(for: message, reset: true) }
        }
    }
}

struct V2GroupMembersSheet: View {
    @Bindable var store: V2ConversationDetailStore
    @Environment(\.dismiss) private var dismiss
    @State private var newMemberUserID = ""
    @State private var membershipChangeTask: Task<Void, Never>?
    @State private var moderationTask: Task<Void, Never>?
    @State private var pendingModeratedRemoval: V2GroupMemberItem?

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
                ForEach(store.groupMembers) { member in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName ?? member.handle.map { "@\($0)" } ?? "资料暂不可用")
                            if let handle = member.handle {
                                Text("@\(handle)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
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
                            .accessibilityLabel("修改 \(member.displayName ?? member.handle ?? "成员") 的角色")
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
                            .accessibilityLabel("群管理 \(member.displayName ?? member.handle ?? "成员")")
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
            .confirmationDialog(
                "确认管理员移除？",
                isPresented: Binding(
                    get: { pendingModeratedRemoval != nil },
                    set: { if !$0 { pendingModeratedRemoval = nil } }
                ),
                presenting: pendingModeratedRemoval
            ) { member in
                Button("管理员移除", role: .destructive) {
                    pendingModeratedRemoval = nil
                    runModeratedRemoval(member)
                }
            } message: { member in
                Text("将移除 \(member.displayName ?? member.handle ?? "该成员")，并写入管理员审计记录。")
            }
        }
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

@MainActor
func announceV2AccessibilityAnnouncement(_ message: String) {
    guard UIAccessibility.isVoiceOverRunning else { return }
    UIAccessibility.post(notification: .announcement, argument: message)
}
