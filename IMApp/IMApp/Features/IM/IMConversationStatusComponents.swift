import IMClientKit
import SwiftUI

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

struct IMConnectionStatusPill: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
