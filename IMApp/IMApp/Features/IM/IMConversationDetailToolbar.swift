import SwiftUI
import IMClientKit

extension IMConversationDetailView {
    @ToolbarContentBuilder
    var detailToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(conversationIdentity.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                Text(connectionStatusText)
                    .font(.caption2)
                    .foregroundStyle(connectionStatusColor)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("conversation.title")
        }

        #if DEBUG
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isPresentingBatchSender = true
            } label: {
                Image(systemName: "timer.circle")
            }
            .disabled(!canSendMessages)
            .accessibilityLabel("批量发送测试消息")
            .accessibilityIdentifier("conversation.batchSendButton")
        }
        #endif

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isPresentingSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("搜索会话内消息")
            .accessibilityIdentifier("conversation.searchButton")
        }

        if conversation?.kind == .group {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingGroupSettings = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("群聊管理")
                .accessibilityIdentifier("conversation.groupSettings.entry")
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
                        Button {
                            runRelationshipAction(.unblock(peer.id)) {
                                await runtimeStore.unblockUser(peer.id)
                            }
                        } label: {
                            if relationshipActionIsRunning(.unblock(peer.id)) {
                                Label("正在解除", systemImage: "clock")
                            } else {
                                Text("解除拉黑")
                            }
                        }
                        .disabled(relationshipActionIsRunning(.unblock(peer.id)))
                    } else {
                        Button(role: .destructive) {
                            runRelationshipAction(.block(peer.id)) {
                                await runtimeStore.blockUser(peer.id)
                            }
                        } label: {
                            if relationshipActionIsRunning(.block(peer.id)) {
                                Label("正在拉黑", systemImage: "clock")
                            } else {
                                Text("拉黑对方")
                            }
                        }
                        .disabled(relationshipActionIsRunning(.block(peer.id)))
                    }

                    Button(role: .destructive) {
                        runRelationshipAction(.report(peer.id)) {
                            await runtimeStore.reportUser(peer.id, conversationID: conversationID)
                        }
                    } label: {
                        if relationshipActionIsRunning(.report(peer.id)) {
                            Label("正在举报", systemImage: "clock")
                        } else {
                            Text("举报对方")
                        }
                    }
                    .disabled(relationshipActionIsRunning(.report(peer.id)))
                }

                Button("清空聊天记录", role: .destructive) {
                    destructiveAction = .clear
                }

                Button("删除会话", role: .destructive) {
                    destructiveAction = .delete
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("会话设置")
            .accessibilityIdentifier("conversation.settingsMenuButton")
        }
    }
}

struct GroupSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let conversation: IMConversation?
    let identity: IMConversationIdentityPresentation
    let currentRole: IMConversationMemberRole?
    let canRenameConversation: Bool
    let canAddMembers: Bool
    let canManageMembers: Bool
    let onRename: () -> Void
    let onEditMetadata: () -> Void
    let onInvites: () -> Void
    let onMemberNickname: () -> Void
    let onAddMembers: () -> Void
    let onManageMembers: () -> Void
    let onLeave: () -> Void
    let onTogglePinned: () -> Void
    let onToggleMuted: () -> Void

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Text(initials)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Color.accentColor.gradient))

                    VStack(spacing: 4) {
                        Text(identity.title)
                            .font(.headline.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        Text(summaryText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityIdentifier("conversation.groupSettings.title")
            }

            Section("会话") {
                Button {
                    onTogglePinned()
                } label: {
                    Label(conversation?.isPinned == true ? "取消置顶" : "置顶会话", systemImage: conversation?.isPinned == true ? "pin.slash" : "pin.fill")
                }

                Button {
                    onToggleMuted()
                } label: {
                    Label(conversation?.isMuted == true ? "取消免打扰" : "消息免打扰", systemImage: conversation?.isMuted == true ? "bell" : "bell.slash")
                }

                if canRenameConversation {
                    Button {
                        dismiss()
                        onRename()
                    } label: {
                        Label("修改群名", systemImage: "pencil")
                    }
                }

                if canRenameConversation {
                    Button {
                        dismiss()
                        onEditMetadata()
                    } label: {
                        Label("群公告与资料", systemImage: "text.quote")
                    }
                }
            }

            Section("成员") {
                Button {
                    dismiss()
                    onMemberNickname()
                } label: {
                    Label("我的群昵称", systemImage: "person.text.rectangle")
                }

                if canAddMembers {
                    Button {
                        dismiss()
                        onAddMembers()
                    } label: {
                        Label("添加成员", systemImage: "person.badge.plus")
                    }
                }

                if canManageMembers {
                    Button {
                        dismiss()
                        onManageMembers()
                    } label: {
                        Label("成员与角色", systemImage: "person.3.sequence")
                    }
                    .accessibilityIdentifier("conversation.groupSettings.members")
                }
            }

            if canRenameConversation {
                Section("邀请") {
                    Button {
                        dismiss()
                        onInvites()
                    } label: {
                        Label("邀请链接", systemImage: "link")
                    }
                    .accessibilityIdentifier("conversation.groupSettings.invites")
                }
            }

            Section {
                Button(role: .destructive) {
                    dismiss()
                    onLeave()
                } label: {
                    Label("退出群聊", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityIdentifier("conversation.groupSettings.leave")
            }
        }
        .navigationTitle("群聊设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") {
                    dismiss()
                }
            }
        }
    }

    private var initials: String {
        let value = identity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return "群"
        }
        return String(value.prefix(2)).uppercased()
    }

    private var summaryText: String {
        let memberCount = conversation?.memberCount ?? conversation?.members.count ?? 0
        if let currentRole {
            return "\(memberCount) 位成员 · \(currentRole.displayName)"
        }
        return "\(memberCount) 位成员"
    }
}
