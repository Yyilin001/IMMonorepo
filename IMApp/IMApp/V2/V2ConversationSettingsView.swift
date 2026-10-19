import IMV2ClientKit
import IMV2Core
import SwiftUI

struct V2ConversationSettingsView: View {
    let roomID: String
    let peerKey: V2ProfileViewLookupKey?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2UserInteractionContext) private var context
    @State private var profile: V2UserProfileTarget?
    @State private var isUpdating = false
    @State private var lastItem: V2ConversationListItem?
    private var item: V2ConversationListItem? { lastItem ?? context?.conversations.items.first { $0.id == roomID } }
    var body: some View {
        NavigationStack {
            Form {
                if let peerKey {
                    Section {
                        Button { profile = .init(key: peerKey) } label: {
                            HStack {
                                V2AuthorizedAvatarView(key: peerKey, size: 48)
                                V2AuthorizedProfileNameView(key: peerKey)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("v2.chat-settings.profile")
                    }
                }
                if let item {
                    Section("会话整理") {
                        Toggle("置顶聊天", isOn: Binding(get: { item.isPinned }, set: { update(isPinned: $0) }))
                            .accessibilityIdentifier("v2.chat-settings.pin")
                        Toggle("归档会话", isOn: Binding(get: { item.isArchived }, set: { update(isArchived: $0) }))
                            .accessibilityIdentifier("v2.chat-settings.archive")
                    }.disabled(isUpdating)
                    Section("消息通知") {
                        Menu {
                            Button("1 小时") { mute(seconds: 3600) }
                            Button("8 小时") { mute(seconds: 28800) }
                            Button("1 天") { mute(seconds: 86400) }
                            Button("持续免打扰") { mute(seconds: 315_576_000) }
                            if item.muteUntil.map({ $0 > Date() }) == true { Button("取消免打扰") { update(muteUntil: .some(nil)) } }
                        } label: {
                            HStack { Text("消息免打扰"); Spacer(); Text(item.muteUntil.map({ $0 > Date() }) == true ? "已开启" : "未开启").foregroundStyle(.secondary) }
                        }.accessibilityIdentifier("v2.chat-settings.mute")
                    }.disabled(isUpdating)
                }
                if let feedback = context?.conversations.conversationStateFeedback {
                    Text(feedback).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .v2GroupedPageSurface()
            .navigationTitle("聊天详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $profile) { V2UserProfileSheet(key: $0.key) }
            .task(id: context?.conversations.items) {
                guard let context, let source = context.conversations.items.first(where: { $0.id == roomID }) ?? lastItem else { return }
                lastItem = await context.conversations.displayedConversationState(source)
            }
        }
    }
    private func mute(seconds: TimeInterval) { update(muteUntil: .some(Date().addingTimeInterval(seconds))) }
    private func update(isPinned: Bool? = nil, isArchived: Bool? = nil, muteUntil: Date?? = nil) {
        guard !isUpdating, let context, let item else { return }
        isUpdating = true
        Task {
            defer { isUpdating = false }
            await context.conversations.updateConversationState(item, isPinned: isPinned, isArchived: isArchived, muteUntil: muteUntil)
            await context.conversations.refresh()
            lastItem = await context.conversations.displayedConversationState(context.conversations.items.first { $0.id == roomID } ?? item)
        }
    }
}
