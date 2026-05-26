import IMClientKit
import SwiftUI

struct IMConversationRowButton: View {
    let conversation: IMConversation
    let identity: IMConversationIdentityPresentation
    let queueSummary: IMConversationQueueSummary
    let isActive: Bool
    let onOpen: () -> Void
    let onAction: (IMConversationRowAction) -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            IMConversationRow(
                conversation: conversation,
                identity: identity,
                queueSummary: queueSummary,
                isActive: isActive
            )
        }
        .buttonStyle(.plain)
        .conversationRowActions(conversation: conversation, onAction: onAction)
        .accessibilityIdentifier("messages.conversationRow.\(conversation.id)")
    }
}

struct IMConversationRow: View {
    let conversation: IMConversation
    let identity: IMConversationIdentityPresentation
    let queueSummary: IMConversationQueueSummary
    let isActive: Bool

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
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
                    .background(Circle().fill(avatarColor.gradient))
            }

            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                    Text(identity.title)
                        .font(.body.weight(conversation.unreadCount > 0 || isActive ? .semibold : .regular))
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
                }

                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                    Text(primaryPreviewText)
                        .font(.subheadline)
                        .foregroundStyle(primaryPreviewColor)
                        .lineLimit(2)

                    Spacer(minLength: 0)
                }

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

            VStack(alignment: .trailing, spacing: AppSpacing.small) {
                Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ConversationUnreadBadge(count: conversation.unreadCount)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, AppSpacing.small)
        .contentShape(Rectangle())
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

    private var primaryPreviewText: String {
        let draft = conversation.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty {
            return "草稿: \(draft)"
        }

        if queueSummary.retryableIssueCount > 0 {
            return "发送失败，点进会话重试"
        }

        let preview = conversation.lastMessagePreview.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.isEmpty {
            return conversation.kind == .group ? "\(conversation.memberCount) 位成员" : "暂无消息"
        }
        return preview
    }

    private var primaryPreviewColor: Color {
        let draft = conversation.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty {
            return .orange
        }
        if queueSummary.retryableIssueCount > 0 {
            return .red
        }
        return conversation.unreadCount > 0 ? .primary : .secondary
    }
}

enum IMConversationRowAction: Equatable, Sendable {
    case pin
    case mute
    case markRead
    case markUnread
    case clearHistory
    case delete
}

struct IMConversationRowSwipeActions: ViewModifier {
    let conversation: IMConversation
    let onAction: (IMConversationRowAction) -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    onAction(.pin)
                } label: {
                    Label(conversation.isPinned ? "取消置顶" : "置顶", systemImage: conversation.isPinned ? "pin.slash" : "pin.fill")
                }
                .tint(.orange)
                .accessibilityIdentifier("messages.row.action.pin")

                Button {
                    onAction(.mute)
                } label: {
                    Label(conversation.isMuted ? "取消免打扰" : "免打扰", systemImage: conversation.isMuted ? "bell" : "bell.slash")
                }
                .tint(.gray)
                .accessibilityIdentifier("messages.row.action.mute")
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    onAction(.delete)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .accessibilityIdentifier("messages.row.action.delete")

                Button(role: .destructive) {
                    onAction(.clearHistory)
                } label: {
                    Label("清空", systemImage: "eraser")
                }
                .tint(.red.opacity(0.85))

                Button {
                    onAction(conversation.unreadCount > 0 ? .markRead : .markUnread)
                } label: {
                    Label(conversation.unreadCount > 0 ? "已读" : "未读", systemImage: conversation.unreadCount > 0 ? "envelope.open" : "envelope.badge")
                }
                .tint(.blue)
                .accessibilityIdentifier("messages.row.action.markRead")
            }
            .contextMenu {
                Button(conversation.isPinned ? "取消置顶" : "置顶会话", systemImage: conversation.isPinned ? "pin.slash" : "pin.fill") {
                    onAction(.pin)
                }
                Button(conversation.isMuted ? "取消免打扰" : "免打扰", systemImage: conversation.isMuted ? "bell" : "bell.slash") {
                    onAction(.mute)
                }
                Button(conversation.unreadCount > 0 ? "标为已读" : "标为未读", systemImage: conversation.unreadCount > 0 ? "envelope.open" : "envelope.badge") {
                    onAction(conversation.unreadCount > 0 ? .markRead : .markUnread)
                }
                Button("清空聊天记录", systemImage: "eraser", role: .destructive) {
                    onAction(.clearHistory)
                }
                Button("删除会话", systemImage: "trash", role: .destructive) {
                    onAction(.delete)
                }
            }
    }
}

extension View {
    func conversationRowActions(
        conversation: IMConversation,
        onAction: @escaping (IMConversationRowAction) -> Void
    ) -> some View {
        modifier(IMConversationRowSwipeActions(conversation: conversation, onAction: onAction))
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
        AppEmptyState(
            title: "没有会话",
            message: "发起私聊或创建群聊后，会话会显示在这里。",
            systemImage: "message.badge.circle",
            actionTitle: "新建会话",
            actionSystemImage: "square.and.pencil",
            action: onCreateConversation
        )
    }
}
