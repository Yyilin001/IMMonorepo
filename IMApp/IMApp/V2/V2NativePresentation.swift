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
                        .font(.largeTitle).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(title).font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("v2.conversation.empty.title")
                    Text(description).font(.body).foregroundStyle(.secondary)
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
    @ScaledMetric(relativeTo: .caption2) private var diameter: CGFloat = 26

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .minimumScaleFactor(0.75)
            .lineLimit(1)
            .frame(width: diameter, height: diameter)
            .background(.tint, in: Circle())
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
                V2AuthorizedGroupAvatarView(roomID: room, size: avatarSize)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().foregroundStyle(.secondary)
                    .frame(width: avatarSize, height: avatarSize)
                    .accessibilityHidden(true)
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
                        .lineLimit(2)
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
        .padding(.vertical, 7)
    }
}

struct V2SettingsLabel: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        HStack {
            Label {
                Text(title).foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(tint, in: RoundedRectangle(cornerRadius: 7))
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
    let canOpenPendingAvatars: Bool
    let openPublicIdentity: () -> Void
    let openDevices: () -> Void
    let openPrivacy: () -> Void
    let openSecurity: () -> Void
    let openPendingAvatars: () -> Void
    let openFavorites: () -> Void
    let signOut: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: openPublicIdentity) {
                        HStack(spacing: 16) {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable().foregroundStyle(.secondary)
                                .frame(width: 64, height: 64).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(displayName.isEmpty ? "我的资料" : displayName)
                                    .font(.title3).foregroundStyle(.primary)
                                if !handle.isEmpty { Text(handle).font(.subheadline).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.padding(.vertical, 8)
                    }
                    .disabled(!canOpenPublicIdentity)
                    .accessibilityIdentifier("v2.identity.open")
                }
                Section {
                    Button(action: openFavorites) { V2SettingsLabel(title: "收藏", symbol: "star.fill", tint: .orange) }
                        .accessibilityIdentifier("v2.message.favorites")
                    if canOpenDevices {
                        Button(action: openDevices) { V2SettingsLabel(title: "登录设备", symbol: "iphone", tint: .green) }
                            .accessibilityIdentifier("v2.device-sessions.open")
                    }
                    if canOpenPendingAvatars {
                        Button(action: openPendingAvatars) { V2SettingsLabel(title: "待处理群头像", symbol: "person.3.fill") }
                            .accessibilityIdentifier("v2.group.avatar.pending.open")
                    }
                }
                Section {
                    Button(action: openPrivacy) { V2SettingsLabel(title: "消息与隐私", symbol: "hand.raised.fill") }
                        .accessibilityIdentifier("v2.privacy.open")
                    if canOpenSecurity {
                        Button(action: openSecurity) { V2SettingsLabel(title: "账号安全", symbol: "lock.fill", tint: .gray) }
                            .accessibilityIdentifier("v2.security.open")
                    }
                }
                Section {
                    Button("退出登录", role: .destructive, action: signOut)
                        .accessibilityIdentifier("v2.sign-out")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我的")
            .accessibilityIdentifier("v2.account.home")
        }
    }
}
