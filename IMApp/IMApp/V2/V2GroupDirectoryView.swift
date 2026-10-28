import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

protocol V2GroupDirectoryReading: Sendable {
    func groupDirectoryPage(matching query: String, after cursor: V2ClientGroupDirectoryCursor?, limit: Int) async throws -> V2ClientGroupDirectoryPage
}

@MainActor @Observable
final class V2GroupDirectoryStore {
    enum State { case loading, loaded, failed }
    private let reader: (any V2GroupDirectoryReading)?
    private let notifier: V2ProjectionChangeNotifier?
    private var generation = 0
    private var loadedQuery = ""
    private(set) var state: State = .loading
    private(set) var items: [V2ClientGroupDirectoryItem] = []
    private(set) var nextCursor: V2ClientGroupDirectoryCursor?
    private(set) var isLoadingMore = false
    private(set) var feedback: String?
    var query = ""

    init(reader: (any V2GroupDirectoryReading)?, notifier: V2ProjectionChangeNotifier? = nil) {
        self.reader = reader; self.notifier = notifier
    }

    func refresh() async {
        generation += 1
        let operation = generation
        isLoadingMore = false
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let desiredCount = search == loadedQuery ? max(50, items.count) : 50
        if search != loadedQuery { items = []; nextCursor = nil; state = .loading }
        do {
            guard let reader else { throw DirectoryError.unavailable }
            var refreshed: [V2ClientGroupDirectoryItem] = []
            var cursor: V2ClientGroupDirectoryCursor?
            repeat {
                try Task.checkCancellation()
                let page = try await reader.groupDirectoryPage(matching: search, after: cursor, limit: 50)
                refreshed.append(contentsOf: page.items)
                cursor = page.nextCursor
            } while cursor != nil && refreshed.count < desiredCount
            try Task.checkCancellation()
            guard operation == generation else { return }
            items = refreshed; nextCursor = cursor; loadedQuery = search; state = .loaded; feedback = nil
        } catch is CancellationError { }
        catch {
            guard operation == generation else { return }
            feedback = search.utf8.count > 400 ? "搜索内容过长，请缩短后重试。" : "暂时无法读取本机群组，请重试。"
            state = items.isEmpty ? .failed : .loaded
        }
    }

    func loadMore() async {
        guard !isLoadingMore, let cursor = nextCursor, let reader else { return }
        let operation = generation
        isLoadingMore = true
        defer { if operation == generation { isLoadingMore = false } }
        do {
            let page = try await reader.groupDirectoryPage(matching: loadedQuery, after: cursor, limit: 50)
            try Task.checkCancellation()
            guard operation == generation else { return }
            let existing = Set(items.map(\.id))
            items += page.items.filter { !existing.contains($0.id) }
            nextCursor = page.nextCursor; feedback = nil
        } catch is CancellationError { }
        catch { if operation == generation { feedback = "无法加载更多群组，请重试。" } }
    }

    func observe() async {
        guard let notifier else { await refresh(); return }
        await V2ProjectionRefreshObserver.run(await notifier.updates(scopes: .conversations)) { [self] in await refresh() }
    }

    private enum DirectoryError: Error { case unavailable }
}

struct V2GroupDirectoryView: View {
    @State var store: V2GroupDirectoryStore
    let conversations: V2ConversationListStore
    let navigation: V2RootNavigationStore
    let invitations: V2GroupInvitationStore?
    @State private var creating = false
    @State private var title = ""
    @State private var members = ""
    @State private var createdRoom: String?

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                Button("新建群聊", systemImage: "square.and.pencil") { creating = true }
                    .accessibilityIdentifier("v2.groups.create")
                if let invitations {
                    Button("加入群聊", systemImage: "qrcode.viewfinder") { invitations.isPresentingJoin = true }
                        .accessibilityIdentifier("v2.groups.join")
                }
            }
            Section("我加入的群组") {
                switch store.state {
                case .loading: ProgressView("正在读取群组…")
                case .failed:
                    ContentUnavailableView("无法读取群组", systemImage: "exclamationmark.triangle", description: Text(store.feedback ?? "请稍后重试。"))
                    Button("重试") { Task { await store.refresh() } }
                case .loaded:
                    if store.items.isEmpty {
                        ContentUnavailableView(store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无群组" : "未找到群组",
                            systemImage: "person.2", description: Text("可以创建群聊，或通过邀请链接和二维码申请加入。"))
                    }
                    ForEach(store.items) { item in
                        Button {
                            conversations.prepareGroupConversation(item)
                            navigation.pushConversation(.room(.init(roomID: item.roomID.rawValue)))
                        } label: {
                            HStack(spacing: 12) {
                                V2AuthorizedGroupAvatarView(roomID: item.roomID, size: 48, fallbackTitle: item.title)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.body.weight(.medium))
                                    if item.isArchived { Label("已归档", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("v2.groups.room.\(item.roomID.rawValue)")
                    }
                    if store.nextCursor != nil {
                        if store.isLoadingMore { ProgressView() }
                        else {
                            Button("加载更多群组") { Task { await store.loadMore() } }
                                .accessibilityIdentifier("v2.groups.more")
                        }
                    }
                    if let feedback = store.feedback { Text(feedback).foregroundStyle(.secondary) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .v2GroupedPageSurface()
        .navigationTitle("我的群组")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $store.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索群名称")
        .accessibilityIdentifier("v2.groups.list")
        .task { await store.observe() }
        .task(id: store.query) {
            if !store.query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            await store.refresh()
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: $creating, onDismiss: {
            guard let room = createdRoom else { return }
            createdRoom = nil; title = ""; members = ""
            navigation.pushConversation(.room(.init(roomID: room)))
        }) {
            V2GroupCreationSheet(store: conversations, groupTitle: $title, groupMemberUserIDs: $members) { createdRoom = $0 }
        }
    }
}
