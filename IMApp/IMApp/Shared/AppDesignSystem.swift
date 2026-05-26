import SwiftUI

enum AppSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 24
}

enum AppCornerRadius {
    static let small: CGFloat = 10
    static let medium: CGFloat = 14
    static let large: CGFloat = 18
}

enum AppSurface {
    static var groupedBackground: Color {
        Color(.systemGroupedBackground)
    }

    static var primaryGrouped: Color {
        Color(.secondarySystemGroupedBackground)
    }

    static var secondaryGrouped: Color {
        Color(.tertiarySystemGroupedBackground)
    }
}

struct AppStatusBanner: View {
    enum Tone {
        case info
        case warning
        case success
        case error

        var color: Color {
            switch self {
            case .info:
                return .blue
            case .warning:
                return .orange
            case .success:
                return .green
            case .error:
                return .red
            }
        }

        var icon: String {
            switch self {
            case .info:
                return "info.circle.fill"
            case .warning:
                return "exclamationmark.triangle.fill"
            case .success:
                return "checkmark.circle.fill"
            case .error:
                return "exclamationmark.circle.fill"
            }
        }
    }

    let message: String
    var tone: Tone = .info
    var systemImage: String?

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.medium) {
            Image(systemName: systemImage ?? tone.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tone.color)
                .frame(width: 22)
                .accessibilityHidden(true)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: AppCornerRadius.medium))
    }
}

struct AppEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var actionSystemImage: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: AppSpacing.medium) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(spacing: AppSpacing.xSmall) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button {
                    action()
                } label: {
                    if let actionSystemImage {
                        Label(actionTitle, systemImage: actionSystemImage)
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.xLarge)
    }
}

struct AppListActionRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    var tint: Color = .accentColor
    var showsChevron = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AppCornerRadius.medium))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: AppSpacing.small)

            trailing()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, AppSpacing.xSmall)
    }
}

extension AppListActionRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = .accentColor,
        showsChevron: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.showsChevron = showsChevron
        self.trailing = { EmptyView() }
    }
}

struct AppSectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.none)

            Spacer(minLength: AppSpacing.small)

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textCase(.none)
            }
        }
    }
}

struct ConversationUnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(displayText)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, count > 9 ? 7 : 6)
                .frame(minWidth: 22, minHeight: 22)
                .background(Capsule().fill(Color.red))
                .accessibilityLabel("\(count) 条未读消息")
        }
    }

    private var displayText: String {
        count > 99 ? "99+" : "\(count)"
    }
}

struct ConversationComposerSurface<Leading: View, Content: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: AppSpacing.medium) {
            leading()
            content()
            trailing()
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.top, AppSpacing.medium)
        .padding(.bottom, AppSpacing.medium)
        .background(.regularMaterial)
    }
}
