import IMClientKit
import OSLog
import SwiftUI

struct IMConversationRowButton: View {
    let snapshot: IMConversationRowSnapshot
    let isActive: Bool
    let onOpen: () -> Void
    let onAction: (IMConversationRowAction) -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            IMConversationRow(
                snapshot: snapshot,
                isActive: isActive
            )
        }
        .buttonStyle(.plain)
        .conversationRowActions(snapshot: snapshot, onAction: onAction)
        .accessibilityIdentifier("messages.conversationRow.\(snapshot.id)")
    }
}

struct IMConversationRow: View {
    let snapshot: IMConversationRowSnapshot
    let isActive: Bool

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            if snapshot.kind == .direct {
                UserAvatarView(
                    displayName: snapshot.title,
                    email: snapshot.directPeerEmail,
                    avatarPreset: snapshot.directPeerAvatarPreset,
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
                    Text(snapshot.title)
                        .font(.body.weight(snapshot.unreadCount > 0 || isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if snapshot.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if snapshot.isMuted {
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

                if snapshot.isDirectMessagingFrozen {
                    Text("已冻结")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .accessibilityLabel(snapshot.directMessagingStatusMessage ?? "已冻结")
                }

                if let rowSecondaryLabel = snapshot.rowSecondaryLabel {
                    Text(rowSecondaryLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .trailing, spacing: AppSpacing.small) {
                Text(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ConversationUnreadBadge(count: snapshot.unreadCount)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, AppSpacing.small)
        .contentShape(Rectangle())
        .onAppear {
            logRowSnapshot(reason: "appear")
        }
        .onChange(of: rowDebugSignature) { _, _ in
            logRowSnapshot(reason: "changed")
        }
    }

    private var avatarText: String {
        let trimmed = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "IM"
        }

        return String(trimmed.prefix(2)).uppercased()
    }

    private var avatarColor: Color {
        switch snapshot.avatarPreset {
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

        if snapshot.unreadCount > 0 {
            return .accentColor
        }

        return isActive ? .blue : Color(.systemGray3)
    }

    private var primaryPreviewText: String {
        snapshot.primaryPreviewText
    }

    private var primaryPreviewColor: Color {
        switch snapshot.primaryPreviewTone {
        case .draft:
            return .orange
        case .failure:
            return .red
        case .unread:
            return .primary
        case .normal:
            return .secondary
        }
    }

    private var rowDebugSignature: String {
        snapshot.debugSignature
    }

    private func logRowSnapshot(reason: String) {
        IMAppLog.imUI.debug(
            "Conversation row snapshot reason=\(reason, privacy: .public) conversationID=\(snapshot.id, privacy: .public) title=\(snapshot.title, privacy: .public) unread=\(snapshot.unreadCount, privacy: .public) preview=\(snapshot.primaryPreviewText, privacy: .public) updated=\(snapshot.updatedAt.timeIntervalSince1970, privacy: .public) pending=\(snapshot.pendingMessageCount, privacy: .public) messages=\(snapshot.messageCount, privacy: .public) timeline=\(snapshot.timelineItemCount, privacy: .public) isActive=\(isActive, privacy: .public)"
        )
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
    let snapshot: IMConversationRowSnapshot
    let onAction: (IMConversationRowAction) -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    onAction(.pin)
                } label: {
                    Label(snapshot.isPinned ? "取消置顶" : "置顶", systemImage: snapshot.isPinned ? "pin.slash" : "pin.fill")
                }
                .tint(.orange)
                .accessibilityIdentifier("messages.row.action.pin")

                Button {
                    onAction(.mute)
                } label: {
                    Label(snapshot.isMuted ? "取消免打扰" : "免打扰", systemImage: snapshot.isMuted ? "bell" : "bell.slash")
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
                    onAction(snapshot.unreadCount > 0 ? .markRead : .markUnread)
                } label: {
                    Label(snapshot.unreadCount > 0 ? "已读" : "未读", systemImage: snapshot.unreadCount > 0 ? "envelope.open" : "envelope.badge")
                }
                .tint(.blue)
                .accessibilityIdentifier("messages.row.action.markRead")
            }
            .contextMenu {
                Button(snapshot.isPinned ? "取消置顶" : "置顶会话", systemImage: snapshot.isPinned ? "pin.slash" : "pin.fill") {
                    onAction(.pin)
                }
                Button(snapshot.isMuted ? "取消免打扰" : "免打扰", systemImage: snapshot.isMuted ? "bell" : "bell.slash") {
                    onAction(.mute)
                }
                Button(snapshot.unreadCount > 0 ? "标为已读" : "标为未读", systemImage: snapshot.unreadCount > 0 ? "envelope.open" : "envelope.badge") {
                    onAction(snapshot.unreadCount > 0 ? .markRead : .markUnread)
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
        snapshot: IMConversationRowSnapshot,
        onAction: @escaping (IMConversationRowAction) -> Void
    ) -> some View {
        modifier(IMConversationRowSwipeActions(snapshot: snapshot, onAction: onAction))
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
