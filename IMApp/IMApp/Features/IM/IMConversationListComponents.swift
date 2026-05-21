import IMClientKit
import SwiftUI

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

