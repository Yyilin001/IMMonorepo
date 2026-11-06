import IMV2ClientKit
import IMV2Core
import SwiftUI

/// 使用不可变快照渲染；排序和业务事实继续由数据库 actor 提供。
struct V2ConversationSnapshotList: View {
    let store: V2ConversationListStore
    let conversations: [V2ConversationListItem]
    let pending: [V2DirectRoomPending]
    let query: String
    let navigation: V2RootNavigationStore
    @State private var presentation = V2ConversationSnapshotPresentation()

    private var input: V2ConversationListSnapshot.Input {
        .init(conversations: conversations,
              pending: pending.map { .pending($0, status: store.directConversationRequestStatus($0)) }, query: query)
    }

    var body: some View {
        List(presentation.snapshot.rows) { row in
            V2ConversationSnapshotRow(row: row, store: store, navigation: navigation)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
        .listStyle(.plain)
        .accessibilityIdentifier("v2.conversation.list")
        .refreshable { await store.refresh() }
        .modifier(V2ListViewportContainer(viewport: store.viewport, coordinateSpace: "v2.conversations.viewport"))
        .onChange(of: input, initial: true) { _, next in presentation.submit(next) }
        .task { await presentation.run() }
    }
}

private struct V2ConversationSnapshotRow: View {
    let row: V2ConversationListSnapshot.Row
    let store: V2ConversationListStore
    let navigation: V2RootNavigationStore

    @ViewBuilder var body: some View {
        switch row {
        case .conversation(let item):
            Button {
                navigation.pushConversation(.init(roomID: item.id))
            } label: {
                V2ConversationSummaryRow(item: item).equatable()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("v2.conversation.\(item.kind.accessibilityIdentifierComponent).\(item.id)")
            .contextMenu { conversationMenu(item) }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(item.isPinned ? "取消置顶" : "置顶", systemImage: item.isPinned ? "pin.slash" : "pin") {
                    Task { await store.applySwipe(.pin(!item.isPinned), to: item.id) }
                }.tint(.orange)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(item.isArchived ? "取消隐藏" : "隐藏", systemImage: "eye.slash") {
                    Task { await store.applySwipe(.archive(!item.isArchived), to: item.id) }
                }.tint(.indigo)
                Button(item.muteUntil.map { $0 > .now } == true ? "恢复提醒" : "免打扰", systemImage: "bell.slash") {
                    Task { await store.applySwipe(.mute(item.muteUntil.map { $0 > .now } != true), to: item.id) }
                }.tint(.gray)
            }
            .modifier(V2ListViewportRow(viewport: store.viewport, itemID: item.id, coordinateSpace: "v2.conversations.viewport"))
            .id(item.id)
        case let .pending(request, status):
            Button {
                navigation.pushConversation(.localDirect(.init(operationID: request.work.id)))
            } label: {
                HStack(spacing: 14) {
                    V2AuthorizedAvatarView(key: .init(userID: request.command.targetUserID, context: .relationship), size: 52)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(request.publicIdentity?.displayName ?? "聊天").font(.body.weight(.semibold))
                        Text(status).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "clock").foregroundStyle(.orange)
                }.padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("v2.conversation.local.\(request.work.id.uuidString)")
            .id(request.work.id)

        }
    }

    @ViewBuilder private func conversationMenu(_ item: V2ConversationListItem) -> some View {
        Menu("会话置顶", systemImage: "pin") {
            Button(item.isPinned ? "取消置顶会话" : "置顶会话") {
                Task { await store.updateConversationState(item, isPinned: !item.isPinned) }
            }
        }
        Menu("隐藏聊天", systemImage: "eye.slash") {
            Button(item.isArchived ? "取消隐藏" : "隐藏聊天") {
                Task { await store.updateConversationState(item, isArchived: !item.isArchived) }
            }
        }
        Menu("消息提醒", systemImage: "bell") {
            Button("免打扰 1 小时") { mute(item, for: 3600) }
            Button("免打扰 8 小时") { mute(item, for: 28800) }
            Button("持续免打扰") { mute(item, for: 315_576_000) }
            if item.muteUntil.map({ $0 > .now }) == true {
                Button("取消免打扰") { Task { await store.updateConversationState(item, muteUntil: .some(nil)) } }
            }
        }
    }

    private func mute(_ item: V2ConversationListItem, for seconds: TimeInterval) {
        Task { await store.updateConversationState(item, muteUntil: .some(Date().addingTimeInterval(seconds))) }
    }
}

@MainActor
enum V2ConversationSwipeAction {
    case pin(Bool), archive(Bool), mute(Bool)
}

private extension V2ConversationListStore {
    func applySwipe(_ action: V2ConversationSwipeAction, to roomID: String) async {
        guard let item = items.first(where: { $0.id == roomID && $0.isArchived == isShowingArchived }) else { return }
        switch action {
        case .pin(let value): await updateConversationState(item, isPinned: value)
        case .archive(let value): await updateConversationState(item, isArchived: value)
        case .mute(let value):
            await updateConversationState(item, muteUntil: .some(value ? Date().addingTimeInterval(315_576_000) : nil))
        }
    }
}
