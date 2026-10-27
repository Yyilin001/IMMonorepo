import SwiftUI
import IMV2ClientKit
import IMV2Core

/// Content stays opaque; Liquid Glass belongs to floating controls and navigation.
/// Explicit semantic fonts and a scrollable layout keep empty conversations
/// readable at every supported content size, including accessibility sizes.
struct V2ConversationEmptyState: View {
    let title: String
    let symbol: String
    let description: String

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: symbol)
                        .font(.largeTitle).foregroundStyle(V2VisualStyle.accent)
                        .frame(width: 88, height: 88)
                        .background(V2VisualStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 28))
                        .accessibilityHidden(true)
                    Text(title).font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("v2.conversation.empty.title")
                    Text(description).font(.body).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("v2.conversation.empty.description")
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 48))
                .padding(24)
            }
        }
    }
}

struct V2UnreadBadge: View {
    let count: UInt64
    @ScaledMetric(relativeTo: .caption2) private var diameter: CGFloat = 22

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .minimumScaleFactor(0.75)
            .lineLimit(1)
            .frame(width: diameter, height: diameter)
            .background(V2VisualStyle.outgoing, in: Capsule())
            .accessibilityLabel("\(count) 条未读")
    }
}

struct V2ConversationSummaryRow: View {
    let item: V2ConversationListItem
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 52

    var body: some View {
        HStack(spacing: 14) {
            if let key = item.presentationKey {
                V2AuthorizedAvatarView(key: key, size: avatarSize)
            } else if item.kind == .group, let room = try? RoomID(item.id) {
                V2AuthorizedGroupAvatarView(roomID: room, size: avatarSize, fallbackTitle: item.title)
            } else {
                V2AvatarPlaceholder(size: avatarSize)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    V2ConversationLabelView(label: .init(item: item))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if let kind = item.kind.directAccountKind, let badge = kind.badgeTitle {
                        Text(badge).font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("v2.conversation.account-kind.\(kind.rawValue)")
                    }
                    if item.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    Spacer(minLength: 4)
                    Text(item.lastActivity, format: .dateTime.hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text((item.isOutgoing ? "我：" : "") + item.preview)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.muteUntil.map({ $0 > .now }) == true {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("免打扰")
                    }
                    if let count = item.unreadCount, count > 0 {
                        V2UnreadBadge(count: count)
                            .accessibilityIdentifier("v2.conversation.unread.\(item.id)")
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }
}

struct V2SettingsLabel: View {
    let title: String
    let symbol: String
    var tint: Color = V2VisualStyle.accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack {
            Label {
                Text(title).foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.body.weight(.medium))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.10),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// The same personal-page layout is used by authenticated sessions and mock browsing.
struct V2AccountHomeView: View {
    var displayName: String = "我的资料"
    var handle: String = ""
    let canOpenPublicIdentity: Bool
    let canOpenDevices: Bool
    let canOpenSecurity: Bool
    let openPublicIdentity: () -> Void
    let openDevices: () -> Void
    let openPrivacy: () -> Void
    let openSecurity: () -> Void
    let openFavorites: () -> Void
    var openResources: (() -> Void)? = nil
    let signOut: () -> Void

    private var profileHeader: some View {
        HStack(spacing: 16) {
            V2AvatarPlaceholder(title: displayName, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(displayName.isEmpty ? "我的资料" : displayName)
                    .font(.title3.weight(.semibold)).foregroundStyle(.primary)
                if !handle.isEmpty { Text(handle).font(.subheadline).foregroundStyle(.secondary) }
                Text(canOpenPublicIdentity ? "编辑个人资料" : "个人空间")
                    .font(.caption).foregroundStyle(V2VisualStyle.accent)
            }
            Spacer(minLength: 4)
            if canOpenPublicIdentity {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }.padding(.vertical, 12)
    }

    var body: some View {
        Group {
            List {
                Section {
                    if canOpenPublicIdentity {
                        Button(action: openPublicIdentity) { profileHeader }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("v2.identity.open")
                    } else {
                        profileHeader
                    }
                }
                Section("内容与管理") {
                    Button(action: openFavorites) {
                        V2SettingsLabel(title: "收藏", symbol: "star", tint: V2VisualStyle.AccountIcon.favorites)
                    }
                        .accessibilityIdentifier("v2.message.favorites")
                    if let openResources {
                        Button(action: openResources) {
                            V2SettingsLabel(title: "文件与存储", symbol: "folder", tint: V2VisualStyle.AccountIcon.resources)
                        }
                            .accessibilityIdentifier("v2.resources.open")
                    }
                }
                Section("设置") {
                    Button(action: openPrivacy) {
                        V2SettingsLabel(title: "消息与隐私", symbol: "hand.raised", tint: V2VisualStyle.AccountIcon.privacy)
                    }
                        .accessibilityIdentifier("v2.privacy.open")
                    if canOpenDevices {
                        Button(action: openDevices) {
                            V2SettingsLabel(title: "登录设备", symbol: "iphone", tint: V2VisualStyle.AccountIcon.devices)
                        }
                            .accessibilityIdentifier("v2.device-sessions.open")
                    }
                    if canOpenSecurity {
                        Button(action: openSecurity) {
                            V2SettingsLabel(title: "账号安全", symbol: "lock", tint: V2VisualStyle.AccountIcon.security)
                        }
                            .accessibilityIdentifier("v2.security.open")
                    }
                }
                Section {
                    Button(role: .destructive, action: signOut) {
                        Text("退出登录").frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .accessibilityIdentifier("v2.sign-out")
                }
            }
            .listStyle(.insetGrouped)
            .listRowSpacing(0)
            .listSectionSpacing(22)
            .v2GroupedPageSurface()
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("v2.account.home")
        }
    }
}
