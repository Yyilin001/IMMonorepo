import ConversationListKit
import IMV2ClientKit
import IMV2Core
import SwiftUI
import UIKit

/// Projects the store's complete ordered snapshot into fixed slots. Only conversation
/// rows participate in database scroll anchors; pending requests and controls do not.
struct V2ConversationCollectionView: UIViewControllerRepresentable {
    enum Row: Equatable, Identifiable {
        enum ID: Hashable { case conversation(String), pending(UUID) }
        var id: ID {
            switch self {
            case .conversation(let item): .conversation(item.id)
            case .pending(let request, _): .pending(request.work.id)
            }
        }

        case conversation(V2ConversationListItem)
        case pending(V2DirectRoomPending, status: String)
    }

    typealias Controller = FixedPositionListController<Row>
    let store: V2ConversationListStore
    private let rows: [Row]
    let navigation: V2RootNavigationStore
    let restoration: V2ListViewport.Restoration?

    init(store: V2ConversationListStore, conversations: [V2ConversationListItem], pending: [V2DirectRoomPending],
         navigation: V2RootNavigationStore, restoration: V2ListViewport.Restoration?) {
        self.store = store
        self.navigation = navigation
        self.restoration = restoration
        var rows = pending.map {
            Row.pending($0, status: store.directConversationRequestStatus($0))
        }
        rows.append(contentsOf: conversations.map(Row.conversation))
        self.rows = rows
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> Controller {
        let source = context.coordinator.source
        source.replace(with: rows)
        let controller = Controller(source: source, configuration: configuration(context))
        controller.view.accessibilityIdentifier = "v2.conversation.list"
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        let coordinator = context.coordinator
        let presentation = RowEnvironment(context.environment, navigation: navigation)
        coordinator.source.replace(with: rows)
        controller.update(configuration: configuration(context), invalidateContent: coordinator.presentation != presentation)
        coordinator.presentation = presentation
        coordinator.restore(restoration, in: controller, viewport: store.viewport)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: Coordinator) {
        coordinator.restorationTask?.cancel()
        controller.stop()
    }

    private func configuration(_ context: Context) -> Controller.Configuration {
        let environment = context.environment
        let coordinator = context.coordinator
        return .init(
            configure: { [store, navigation] cell, row in
                cell.contentConfiguration = UIHostingConfiguration {
                    V2ConversationCollectionRow(row: row, store: store, navigation: navigation)
                        .modifier(V2MessageTimelineInheritedEnvironment(source: environment))
                }
                .margins(.vertical, 0)
                .margins(.horizontal, 16)
            },
            leadingActions: { [store] row in
                guard case .conversation(let item) = row else { return nil }
                return V2ConversationSwipeAction.leading(isPinned: item.isPinned) { await store.applySwipe($0, to: item.id) }
            },
            trailingActions: { [store] row in
                guard case .conversation(let item) = row else { return nil }
                return V2ConversationSwipeAction.trailing(isArchived: item.isArchived, isMuted: item.muteUntil.map { $0 > .now } == true) {
                    await store.applySwipe($0, to: item.id)
                }
            },
            visibleRowsChanged: { [store] visible, bounds in
                var positions: [String: V2ListViewport.RowPosition] = [:]
                for entry in visible {
                    switch entry.row {
                    case .conversation(let item):
                        positions[item.id] = .init(minY: entry.frame.minY, maxY: entry.frame.maxY)
                    default: break
                    }
                }
                store.viewport.replaceVisibleRows(positions, in: bounds)
            },
            didBeginDragging: { [store] in store.viewport.userDidBeginScrolling() },
            refresh: { [store] in await store.refresh() }
        )
    }

    /// UIKit cells have independent SwiftUI roots. Rebind equal row values when their
    /// inherited profile authority, scene or presentation settings change.
    struct RowEnvironment: Equatable {
        let navigation: ObjectIdentifier
        let pipeline: ObjectIdentifier?
        let page: ObjectIdentifier?
        let phase: ScenePhase
        let typeSize: DynamicTypeSize
        let scale: CGFloat
        let colorScheme: ColorScheme
        let direction: LayoutDirection
        let locale: Locale
        let calendar: Calendar
        let timeZone: TimeZone
        #if DEBUG
        let mockNames: [String: String]
        #endif

        init(_ environment: EnvironmentValues, navigation: V2RootNavigationStore) {
            self.navigation = ObjectIdentifier(navigation)
            pipeline = environment.v2AvatarPipeline.map(ObjectIdentifier.init)
            page = environment.v2AuthorPresentationPageScope.map(ObjectIdentifier.init)
            phase = environment.scenePhase
            typeSize = environment.dynamicTypeSize
            scale = environment.displayScale
            colorScheme = environment.colorScheme
            direction = environment.layoutDirection
            locale = environment.locale
            calendar = environment.calendar
            timeZone = environment.timeZone
            #if DEBUG
            mockNames = environment.v2MockProfileNames
            #endif
        }
    }

    @MainActor final class Coordinator {
        let source = OrderedListWindow<Row>()
        var presentation: RowEnvironment?
        var restorationTask: Task<Void, Never>?
        private var restorationID: UUID?

        func restore(_ request: V2ListViewport.Restoration?, in controller: Controller, viewport: V2ListViewport) {
            guard restorationID != request?.id else { return }
            restorationID = request?.id
            restorationTask?.cancel()
            guard let request else { return }
            let source = source
            restorationTask = Task { [weak controller] in
                await viewport.performRestoration(request) { id in
                    if let index = source.firstIndex(where: {
                        if case .conversation(let item) = $0 { return item.id == id }
                        return false
                    }) { controller?.scrollToItem(at: index) }
                }
            }
        }


    }
}

private struct V2ConversationCollectionRow: View {
    let row: V2ConversationCollectionView.Row
    let store: V2ConversationListStore
    let navigation: V2RootNavigationStore

    @ViewBuilder var body: some View {
        switch row {
        case .conversation(let item):
            Button {
                navigation.pushConversation(.init(roomID: item.id))
            } label: {
                V2ConversationSummaryRow(item: item)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("v2.conversation.\(item.kind.accessibilityIdentifierComponent).\(item.id)")
            .contextMenu { conversationMenu(item) }
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

    static func leading(isPinned: Bool, perform: @escaping (Self) async -> Void) -> UISwipeActionsConfiguration {
        actions([action(isPinned ? "取消置顶" : "置顶", image: isPinned ? "pin.slash" : "pin", color: .systemOrange) {
            await perform(.pin(!isPinned))
        }])
    }

    static func trailing(isArchived: Bool, isMuted: Bool, perform: @escaping (Self) async -> Void) -> UISwipeActionsConfiguration {
        actions([
            action(isArchived ? "取消隐藏" : "隐藏", image: "eye.slash", color: .systemIndigo) {
                await perform(.archive(!isArchived))
            },
            action(isMuted ? "恢复提醒" : "免打扰", image: "bell.slash", color: .systemGray) {
                await perform(.mute(!isMuted))
            }
        ])
    }

    private static func actions(_ actions: [UIContextualAction]) -> UISwipeActionsConfiguration {
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    private static func action(_ title: String, image: String, color: UIColor,
                               perform: @escaping @MainActor () async -> Void) -> UIContextualAction {
        let action = UIContextualAction(style: .normal, title: title) { _, _, complete in
            complete(true)
            Task { await perform() }
        }
        action.image = UIImage(systemName: image)
        action.backgroundColor = color
        return action
    }
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
