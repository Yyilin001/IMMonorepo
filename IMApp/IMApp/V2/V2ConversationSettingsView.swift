import IMV2ClientKit
import IMV2Core
import SwiftUI

/// A destination in the chat's existing navigation stack. Settings owns the
/// sheets it opens; returning from those sheets keeps the settings page visible.
struct V2ConversationSettingsView: View {
    let store: V2ConversationDetailStore
    var groupInvitationStore: V2GroupInvitationStore? = nil
    let focusMessage: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2UserInteractionContext) private var context
    @Environment(\.v2ResourceManagement) private var resources
    @State private var profile: V2UserProfileTarget?
    @State private var presentedSheet: PresentedSheet?
    @State private var pendingFocusedMessage: String?
    @State private var isUpdating = false
    @State private var lastItem: V2ConversationListItem?

    private enum PresentedSheet: Identifiable {
        case search(V2ConversationSearchStore)
        case members, announcement, permissions, invitations
        case avatar(V2GroupAvatarManagementStore)
        case nickname(V2NameEditorStore)
        var id: String {
            switch self {
            case .search: "search"
            case .members: "members"
            case .announcement: "announcement"
            case .permissions: "permissions"
            case .invitations: "invitations"
            case .avatar: "avatar"
            case .nickname: "nickname"
            }
        }
    }

    private var item: V2ConversationListItem? {
        lastItem ?? context?.conversations.items.first { $0.id == store.roomID }
    }

    var body: some View {
        Form {
            identitySection
            if resources != nil || store.canSearchMessages {
                Section("聊天内容") {
                    if resources != nil, let room = try? RoomID(store.roomID) {
                        NavigationLink(value: V2ResourceRoute.library(room)) {
                            rowLabel("聊天文件", symbol: "folder", color: .blue)
                        }.accessibilityIdentifier("v2.chat-settings.resources")
                    }
                    if store.canSearchMessages {
                        action("搜索聊天记录", symbol: "magnifyingglass", color: .indigo,
                               identifier: "v2.message.search.current-room") {
                            if let search = store.messageSearchStore() { presentedSheet = .search(search) }
                        }
                    }
                }
            }
            Section("消息操作") {
                action("多选转发", symbol: "arrowshape.turn.up.right", color: .teal,
                       identifier: "v2.message.forward.begin") {
                    dismiss()
                    store.beginForwardSelection()
                }.disabled(store.messages.allSatisfy(\.isWithdrawn))
            }
            if let item {
                Section("会话整理") {
                    Toggle(isOn: Binding(get: { item.isPinned }, set: { update(isPinned: $0) })) {
                        rowLabel("置顶聊天", symbol: "pin", color: .orange)
                    }.accessibilityIdentifier("v2.chat-settings.pin")
                    Toggle(isOn: Binding(get: { item.isArchived }, set: { update(isArchived: $0) })) {
                        rowLabel("归档会话", symbol: "archivebox", color: .blue)
                    }.accessibilityIdentifier("v2.chat-settings.archive")
                }.disabled(isUpdating)
                Section("消息通知") {
                    Menu {
                        Button("1 小时") { mute(seconds: 3600) }
                        Button("8 小时") { mute(seconds: 28800) }
                        Button("1 天") { mute(seconds: 86400) }
                        Button("持续免打扰") { mute(seconds: 315_576_000) }
                        if item.muteUntil.map({ $0 > Date() }) == true {
                            Button("取消免打扰") { update(muteUntil: .some(nil)) }
                        }
                    } label: {
                        HStack {
                            rowLabel("消息免打扰", symbol: "bell.slash", color: .purple)
                            Spacer()
                            Text(item.muteUntil.map({ $0 > Date() }) == true ? "已开启" : "未开启")
                                .foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("v2.chat-settings.mute")
                }.disabled(isUpdating)
            }
            if store.isGroupConversation { groupSections }
            if let feedback = context?.conversations.conversationStateFeedback {
                Section { Text(feedback).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .v2GroupedPageSurface()
        .listRowSpacing(0)
        .navigationTitle(store.isGroupConversation ? "群聊设置" : "会话设置")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("v2.chat-settings")
        .v2UserProfileSheet(item: $profile)
        .sheet(item: $presentedSheet, onDismiss: {
            guard let message = pendingFocusedMessage else { return }
            pendingFocusedMessage = nil
            focusMessage(message)
            dismiss()
        }) { sheet in
            switch sheet {
            case .search(let search):
                NavigationStack {
                    V2MessageSearchView(store: search) { hit in
                        pendingFocusedMessage = hit.messageID.rawValue
                        presentedSheet = nil
                    }
                }
            case .members: V2GroupMembersSheet(store: store)
            case .announcement: V2GroupAnnouncementSheet(store: store)
            case .permissions: V2GroupPermissionsSheet(store: store)
            case .avatar(let manager): V2GroupAvatarManagementView(store: manager)
            case .nickname(let editor): V2NameEditorView(store: editor)
            case .invitations:
                if let groupInvitationStore {
                    V2GroupInvitationManagementSheet(store: groupInvitationStore, roomID: store.roomID)
                }
            }
        }
        .task(id: context?.conversations.items) {
            guard let context,
                  let source = context.conversations.items.first(where: { $0.id == store.roomID }) ?? lastItem else { return }
            lastItem = await context.conversations.displayedConversationState(source)
        }
    }

    @ViewBuilder private var identitySection: some View {
        if let peerKey = store.presentationKey {
            Section {
                Button { profile = .init(key: peerKey) } label: {
                    HStack(spacing: 12) {
                        V2AuthorizedAvatarView(key: peerKey, size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            V2AuthorizedProfileNameView(key: peerKey).font(.headline)
                            Text("查看用户资料").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }.foregroundStyle(.primary).padding(.vertical, 6)
                }.accessibilityIdentifier("v2.chat-settings.profile")
            }
        } else if store.isGroupConversation, let room = try? RoomID(store.roomID) {
            Section {
                HStack(spacing: 12) {
                    V2AuthorizedGroupAvatarView(roomID: room, size: 52, fallbackTitle: store.title)
                    Text(store.title).font(.headline)
                }.padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private var groupSections: some View {
        Section("群聊信息") {
            action("群成员", symbol: "person.2", color: .blue, identifier: "v2.group.members") { presentedSheet = .members }
            action("群公告", symbol: "megaphone", color: .orange, identifier: "v2.group.announcement") { presentedSheet = .announcement }
            if store.hasGroupAvatarManagement {
                action("群头像", symbol: "person.crop.circle", color: .purple, identifier: "v2.group.avatar.manage") {
                    if let manager = store.groupAvatarManagementStore() { presentedSheet = .avatar(manager) }
                }
            }
        }
        if store.canEditOwnGroupNickname {
            Section("我在本群") {
                action("我的群昵称", symbol: "pencil", color: .teal, identifier: "v2.group.nickname.edit") {
                    if let editor = store.ownGroupNicknameEditor() { presentedSheet = .nickname(editor) }
                }
            }
        }
        Section("群管理") {
            action("群权限", symbol: "lock.shield", color: .indigo, identifier: "v2.group.permissions") { presentedSheet = .permissions }
            if groupInvitationStore != nil {
                action("邀请成员", symbol: "person.badge.plus", color: .green, identifier: "v2.group.invitations") { presentedSheet = .invitations }
            }
        }
    }

    private func rowLabel(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.medium)).foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(title).foregroundStyle(.primary)
        }
    }
    private func action(_ title: String, symbol: String, color: Color, identifier: String,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack {
                rowLabel(title, symbol: symbol, color: color)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
        }.accessibilityIdentifier(identifier)
    }
    private func mute(seconds: TimeInterval) { update(muteUntil: .some(Date().addingTimeInterval(seconds))) }
    private func update(isPinned: Bool? = nil, isArchived: Bool? = nil, muteUntil: Date?? = nil) {
        guard !isUpdating, let context, let item else { return }
        isUpdating = true
        Task {
            defer { isUpdating = false }
            await context.conversations.updateConversationState(item, isPinned: isPinned, isArchived: isArchived, muteUntil: muteUntil)
            await context.conversations.refresh()
            lastItem = await context.conversations.displayedConversationState(context.conversations.items.first { $0.id == store.roomID } ?? item)
        }
    }
}
