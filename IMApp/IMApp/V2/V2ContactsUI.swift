import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

/// Presentation data assembled at the local projection boundary. Views never
/// receive a GRDB row or a transport DTO, and never render the opaque ID.
struct V2ContactListItem: Identifiable, Sendable {
    enum Relationship: Equatable, Sendable {
        case friend
        case incomingRequest
        case outgoingRequest
    }

    let userID: UserID
    let publicIdentity: V2PublicIdentity?
    let relationship: Relationship
    let updatedAt: Date

    var id: String { userID.rawValue }
    var displayName: String { publicIdentity?.displayName ?? "资料暂不可用" }
    var handle: String? { publicIdentity?.handle.description }
}

struct V2ContactProjection: Sendable {
    let userID: UserID
    let state: V2RelationshipState
    let requestedByUserID: UserID?
    let updatedAt: Date
    let publicIdentity: V2PublicIdentity?
}

enum V2ContactProjectionPageScope: Equatable, Sendable {
    case friends
    case incomingRequests
    case outgoingRequests
}

struct V2ContactProjectionPage: Sendable {
    let projections: [V2ContactProjection]
    let nextCursor: V2ClientRelationshipCursor?
    let totalCount: Int?
}

protocol V2ContactsReading: Sendable {
    func contactProjectionPage(
        scope: V2ContactProjectionPageScope,
        matching query: String?,
        before cursor: V2ClientRelationshipCursor?,
        limit: Int,
        includeTotalCount: Bool
    ) async throws -> V2ContactProjectionPage
    func hydrateRelationshipProfiles(for userIDs: [UserID]) async throws
}

/// App-side composition of the reusable ClientKit stores. The profile reader
/// receives the relationship authorization context; it cannot turn a list of
/// IDs into a global profile directory.
actor V2GRDBContactsDataSource: V2ContactsReading {
    private let localStore: GRDBV2LocalSyncStore
    private let profiles: V2ProfileRepository
    private let currentUserID: UserID

    init(localStore: GRDBV2LocalSyncStore, profiles: V2ProfileRepository, currentUserID: UserID) {
        self.localStore = localStore
        self.profiles = profiles
        self.currentUserID = currentUserID
    }

    func contactProjectionPage(
        scope: V2ContactProjectionPageScope,
        matching query: String?,
        before cursor: V2ClientRelationshipCursor?,
        limit: Int,
        includeTotalCount: Bool
    ) async throws -> V2ContactProjectionPage {
        let clientScope: V2ClientRelationshipPageScope = switch scope {
        case .friends: .accepted
        case .incomingRequests: .incomingRequests(currentUserID: currentUserID)
        case .outgoingRequests: .outgoingRequests(currentUserID: currentUserID)
        }
        let page = try await localStore.relationshipPage(
            scope: clientScope,
            matching: query,
            before: cursor,
            limit: limit,
            includeTotalCount: includeTotalCount
        )
        let profileViews = try await localStore.profileViews(userIDs: page.relationships.map(\.targetUserID))
        let projections: [V2ContactProjection] = page.relationships.map {
            V2ContactProjection(
                userID: $0.targetUserID,
                state: $0.state,
                requestedByUserID: $0.requestedByUserID,
                updatedAt: $0.updatedAt,
                publicIdentity: profileViews[$0.targetUserID]?.publicIdentity
            )
        }
        return .init(projections: projections, nextCursor: page.nextCursor, totalCount: page.totalCount)
    }

    func hydrateRelationshipProfiles(for userIDs: [UserID]) async throws {
        let unique = Array(Set(userIDs)).sorted()
        for chunkStart in stride(from: 0, to: unique.count, by: V2ProfileViewLookupLimits.maximumKeys) {
            try Task.checkCancellation()
            let upperBound = min(chunkStart + V2ProfileViewLookupLimits.maximumKeys, unique.count)
            _ = try await profiles.hydrate(unique[chunkStart..<upperBound].map {
                .init(userID: $0, context: .relationship)
            })
        }
    }
}

@MainActor
@Observable
final class V2ContactsStore {
    private static let pageSize = 50

    enum State: Equatable {
        case loading
        case loaded
        case failed
    }

    enum AddFriendState: Equatable {
        case entering
        case resolving
        case resolved(userID: String, displayName: String, handle: String)
        case failed
    }

    private let dataSource: any V2ContactsReading
    private let identityResolver: any V2ConversationPublicIdentityResolving
    private let relationshipChanger: any V2RelationshipChanging
    private let userBlockChanger: any V2UserBlockChanging
    private let directConversationOpener: any V2DirectConversationOpening
    private let currentUserID: UserID
    private let projectionChangeNotifier: V2ProjectionChangeNotifier?
    private var allItems: [V2ContactListItem] = []
    private var friendSearchResults: [V2ContactListItem] = []
    private var resolvedAddIdentity: V2PublicIdentity?
    private var refreshingGeneration = 0
    private var searchGeneration = 0
    private var updatingUserIDs = Set<UserID>()

    private(set) var state: State = .loading
    private(set) var friends: [V2ContactListItem] = []
    private(set) var incomingRequests: [V2ContactListItem] = []
    private(set) var outgoingRequests: [V2ContactListItem] = []
    private(set) var incomingRequestCount = 0
    private(set) var friendsNextCursor: V2ClientRelationshipCursor?
    private(set) var incomingRequestsNextCursor: V2ClientRelationshipCursor?
    private(set) var outgoingRequestsNextCursor: V2ClientRelationshipCursor?
    private(set) var friendSearchNextCursor: V2ClientRelationshipCursor?
    private(set) var isLoadingMoreContacts = false
    private(set) var feedback: String?
    private(set) var addFriendState: AddFriendState = .entering
    var searchQuery = ""
    var addFriendHandle = ""

    init(
        dataSource: any V2ContactsReading,
        identityResolver: any V2ConversationPublicIdentityResolving,
        relationshipChanger: any V2RelationshipChanging,
        userBlockChanger: any V2UserBlockChanging,
        directConversationOpener: any V2DirectConversationOpening,
        currentUserID: UserID,
        projectionChangeNotifier: V2ProjectionChangeNotifier? = nil
    ) {
        self.dataSource = dataSource
        self.identityResolver = identityResolver
        self.relationshipChanger = relationshipChanger
        self.userBlockChanger = userBlockChanger
        self.directConversationOpener = directConversationOpener
        self.currentUserID = currentUserID
        self.projectionChangeNotifier = projectionChangeNotifier
    }

    var filteredFriends: [V2ContactListItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? friends : friendSearchResults
    }

    var canLoadMoreFriends: Bool {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? friendsNextCursor != nil
            : friendSearchNextCursor != nil
    }

    func item(userID: String) -> V2ContactListItem? {
        allItems.first { $0.id == userID }
    }

    func isUpdating(_ item: V2ContactListItem) -> Bool {
        updatingUserIDs.contains(item.userID)
    }

    func refresh(revalidateProfiles: Bool = false) async {
        refreshingGeneration &+= 1
        let generation = refreshingGeneration
        if allItems.isEmpty { state = .loading }
        do {
            let friendPage = try await loadProjectionPage(scope: .friends, before: nil, revalidateProfiles: revalidateProfiles)
            let incomingPage = try await loadProjectionPage(scope: .incomingRequests, before: nil, revalidateProfiles: revalidateProfiles, includeTotalCount: true)
            let outgoingPage = try await loadProjectionPage(scope: .outgoingRequests, before: nil, revalidateProfiles: revalidateProfiles)
            guard generation == refreshingGeneration else { return }
            apply(friendPage.projections, scope: .friends, appending: false)
            apply(incomingPage.projections, scope: .incomingRequests, appending: false)
            apply(outgoingPage.projections, scope: .outgoingRequests, appending: false)
            friendsNextCursor = friendPage.nextCursor
            incomingRequestsNextCursor = incomingPage.nextCursor
            outgoingRequestsNextCursor = outgoingPage.nextCursor
            incomingRequestCount = incomingPage.totalCount ?? incomingPage.projections.count
            state = .loaded
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await refreshFriendSearch()
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshingGeneration else { return }
            state = .failed
        }
    }

    func refreshFriendSearch() async {
        searchGeneration &+= 1
        let generation = searchGeneration
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            friendSearchResults = []
            friendSearchNextCursor = nil
            rebuildAllItems()
            return
        }
        do {
            let page = try await loadProjectionPage(scope: .friends, matching: query, before: nil, revalidateProfiles: false)
            try Task.checkCancellation()
            guard generation == searchGeneration,
                  query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }
            friendSearchResults = makeItems(page.projections)
            friendSearchNextCursor = page.nextCursor
            rebuildAllItems()
        } catch is CancellationError {
            return
        } catch {
            guard generation == searchGeneration else { return }
            feedback = "无法搜索联系人。"
        }
    }

    func loadMoreFriends() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            await loadMore(scope: .friends, matching: nil, cursor: friendsNextCursor)
        } else {
            await loadMore(scope: .friends, matching: query, cursor: friendSearchNextCursor)
        }
    }

    func loadMoreIncomingRequests() async {
        await loadMore(scope: .incomingRequests, matching: nil, cursor: incomingRequestsNextCursor)
    }

    func loadMoreOutgoingRequests() async {
        await loadMore(scope: .outgoingRequests, matching: nil, cursor: outgoingRequestsNextCursor)
    }

    func observeProjectionChanges() async {
        guard let projectionChangeNotifier else {
            await refresh()
            return
        }
        for await _ in await projectionChangeNotifier.updates() {
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func resolveAddFriend() async {
        let handle = addFriendHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty else {
            addFriendState = .failed
            feedback = "请输入对方的公开 ID。"
            return
        }
        addFriendState = .resolving
        feedback = nil
        do {
            let identity = try await identityResolver.resolve(handle: handle)
            try Task.checkCancellation()
            guard identity.userID != currentUserID else {
                addFriendState = .failed
                feedback = "不能添加自己为好友。"
                return
            }
            resolvedAddIdentity = identity
            addFriendState = .resolved(
                userID: identity.userID.rawValue,
                displayName: identity.displayName,
                handle: identity.handle.description
            )
        } catch is CancellationError {
            addFriendState = .entering
        } catch {
            // Preserve the directory's privacy boundary: the UI never says
            // whether a handle is absent, blocked, or otherwise unavailable.
            resolvedAddIdentity = nil
            addFriendState = .failed
            feedback = "无法找到此用户或当前无法添加。"
        }
    }

    func sendFriendRequest() async {
        guard case .resolved = addFriendState, let identity = resolvedAddIdentity else {
            feedback = "请先确认要添加的用户。"
            return
        }
        await changeRelationship(target: identity.userID, action: .request)
    }

    func accept(_ item: V2ContactListItem) async {
        await changeRelationship(target: item.userID, action: .accept)
    }

    func reject(_ item: V2ContactListItem) async {
        await changeRelationship(target: item.userID, action: .reject)
    }

    func remove(_ item: V2ContactListItem) async {
        await changeRelationship(target: item.userID, action: .remove)
    }

    func block(_ item: V2ContactListItem) async {
        guard !updatingUserIDs.contains(item.userID) else { return }
        updatingUserIDs.insert(item.userID)
        defer { updatingUserIDs.remove(item.userID) }
        feedback = nil
        do {
            switch try await userBlockChanger.changeBlock(targetUserID: item.userID.rawValue, action: .block) {
            case .accepted:
                feedback = "屏蔽请求已提交，正在同步。"
            case .queuedForRetry:
                feedback = "屏蔽请求已安全保存，连接恢复后会同步。"
            case .rejected:
                feedback = "无法完成该联系人操作。"
            }
        } catch is CancellationError {
            return
        } catch {
            feedback = "无法保存联系人操作，请稍后重试。"
        }
    }

    func openConversation(with item: V2ContactListItem) async -> String? {
        guard let identity = item.publicIdentity else {
            feedback = "联系人资料暂不可用，请刷新后重试。"
            return nil
        }
        do {
            let roomID = try await directConversationOpener.openConversation(with: identity)
            try Task.checkCancellation()
            return roomID
        } catch is CancellationError {
            return nil
        } catch {
            feedback = "无法打开会话，请稍后重试。"
            return nil
        }
    }

    func resetAddFriend() {
        addFriendHandle = ""
        resolvedAddIdentity = nil
        addFriendState = .entering
        feedback = nil
    }

    private func changeRelationship(target: UserID, action: V2RelationshipAction) async {
        guard !updatingUserIDs.contains(target) else { return }
        updatingUserIDs.insert(target)
        defer { updatingUserIDs.remove(target) }
        feedback = nil
        do {
            switch try await relationshipChanger.changeRelationship(targetUserID: target.rawValue, action: action) {
            case .accepted:
                feedback = "请求已提交，正在同步。"
            case .queuedForRetry:
                feedback = "请求已安全保存，连接恢复后会同步。"
            case .rejected:
                feedback = "无法完成该联系人操作。"
            }
        } catch is CancellationError {
            return
        } catch {
            feedback = "无法保存联系人操作，请稍后重试。"
        }
    }

    private func loadProjectionPage(
        scope: V2ContactProjectionPageScope,
        matching query: String? = nil,
        before cursor: V2ClientRelationshipCursor?,
        revalidateProfiles: Bool,
        includeTotalCount: Bool = false
    ) async throws -> V2ContactProjectionPage {
        var page = try await dataSource.contactProjectionPage(
            scope: scope,
            matching: query,
            before: cursor,
            limit: Self.pageSize,
            includeTotalCount: includeTotalCount
        )
        let totalCount = page.totalCount
        let profileTargets = revalidateProfiles
            ? page.projections.map(\.userID)
            : page.projections.compactMap { $0.publicIdentity == nil ? $0.userID : nil }
        guard !profileTargets.isEmpty else { return page }
        do {
            try await dataSource.hydrateRelationshipProfiles(for: profileTargets)
            try Task.checkCancellation()
            page = try await dataSource.contactProjectionPage(
                scope: scope,
                matching: query,
                before: cursor,
                limit: Self.pageSize,
                includeTotalCount: false
            )
            page = .init(
                projections: page.projections,
                nextCursor: page.nextCursor,
                totalCount: totalCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A cached page remains useful offline. Missing profiles are
            // explicit and hydration work never expands beyond this page.
            feedback = "部分联系人资料暂不可更新。"
        }
        return page
    }

    private func loadMore(
        scope: V2ContactProjectionPageScope,
        matching query: String?,
        cursor: V2ClientRelationshipCursor?
    ) async {
        guard let cursor, !isLoadingMoreContacts else { return }
        let refreshGeneration = refreshingGeneration
        let currentSearchGeneration = searchGeneration
        isLoadingMoreContacts = true
        defer { isLoadingMoreContacts = false }
        do {
            let page = try await loadProjectionPage(scope: scope, matching: query, before: cursor, revalidateProfiles: false)
            try Task.checkCancellation()
            guard refreshGeneration == refreshingGeneration else { return }
            if let query {
                guard currentSearchGeneration == searchGeneration,
                      query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                else { return }
            }
            switch scope {
            case .friends where query != nil:
                appendUnique(makeItems(page.projections), to: &friendSearchResults)
                friendSearchNextCursor = page.nextCursor
            case .friends:
                apply(page.projections, scope: .friends, appending: true)
                friendsNextCursor = page.nextCursor
            case .incomingRequests:
                apply(page.projections, scope: .incomingRequests, appending: true)
                incomingRequestsNextCursor = page.nextCursor
            case .outgoingRequests:
                apply(page.projections, scope: .outgoingRequests, appending: true)
                outgoingRequestsNextCursor = page.nextCursor
            }
            rebuildAllItems()
        } catch is CancellationError {
            return
        } catch {
            feedback = "无法加载更多联系人。"
        }
    }

    private func apply(
        _ projections: [V2ContactProjection],
        scope: V2ContactProjectionPageScope,
        appending: Bool
    ) {
        let items = makeItems(projections)
        switch scope {
        case .friends:
            if appending { appendUnique(items, to: &friends) } else { friends = items }
        case .incomingRequests:
            if appending { appendUnique(items, to: &incomingRequests) } else { incomingRequests = items }
        case .outgoingRequests:
            if appending { appendUnique(items, to: &outgoingRequests) } else { outgoingRequests = items }
        }
        rebuildAllItems()
    }

    private func makeItems(_ projections: [V2ContactProjection]) -> [V2ContactListItem] {
        projections.compactMap { projection -> V2ContactListItem? in
            let relationship: V2ContactListItem.Relationship
            switch projection.state {
            case .accepted:
                relationship = .friend
            case .pending:
                relationship = projection.requestedByUserID == currentUserID ? .outgoingRequest : .incomingRequest
            case .none:
                return nil
            }
            return .init(
                userID: projection.userID,
                publicIdentity: projection.publicIdentity,
                relationship: relationship,
                updatedAt: projection.updatedAt
            )
        }
    }

    private func appendUnique(_ incoming: [V2ContactListItem], to existing: inout [V2ContactListItem]) {
        let existingIDs = Set(existing.map(\.id))
        existing.append(contentsOf: incoming.filter { !existingIDs.contains($0.id) })
    }

    private func rebuildAllItems() {
        allItems = Array(Dictionary(
            (friends + incomingRequests + outgoingRequests + friendSearchResults).map { ($0.id, $0) },
            uniquingKeysWith: { _, incoming in incoming }
        ).values)
    }
}

@MainActor
@Observable
final class V2RootNavigationStore {
    enum Tab: Hashable {
        case conversations
        case contacts
    }

    struct ConversationRequest: Identifiable, Hashable {
        let id: UUID
        let roomID: String
    }

    var selectedTab: Tab = .conversations
    private(set) var conversationRequest: ConversationRequest?

    func showConversation(roomID: String) {
        guard (try? RoomID(roomID)) != nil else { return }
        selectedTab = .conversations
        conversationRequest = .init(id: UUID(), roomID: roomID)
    }

    func consumeConversationRequest(id: UUID) {
        guard conversationRequest?.id == id else { return }
        conversationRequest = nil
    }
}

private enum V2ContactsRoute: Hashable {
    case requests
    case addFriend
    case contact(String)
}

struct V2ContactsRootView: View {
    @Bindable var store: V2ContactsStore
    let rootNavigation: V2RootNavigationStore
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch store.state {
                case .loading:
                    ProgressView("正在加载联系人…")
                case .failed:
                    ContentUnavailableView("无法读取联系人", systemImage: "person.crop.circle.badge.exclamationmark", description: Text("请检查网络或本地数据后重试。"))
                case .loaded:
                    contactList
                }
            }
            .navigationTitle("联系人")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: V2ContactsRoute.addFriend) {
                        Label("添加好友", systemImage: "person.badge.plus")
                    }
                    .accessibilityIdentifier("v2.contacts.add")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新", systemImage: "arrow.clockwise") {
                        Task { await store.refresh(revalidateProfiles: true) }
                    }
                    .accessibilityIdentifier("v2.contacts.refresh")
                }
            }
            .navigationDestination(for: V2ContactsRoute.self) { route in
                switch route {
                case .requests:
                    V2FriendRequestsView(store: store)
                case .addFriend:
                    V2AddFriendView(store: store)
                case .contact(let userID):
                    V2ContactDetailView(store: store, userID: userID, rootNavigation: rootNavigation)
                }
            }
            .task { await store.observeProjectionChanges() }
            .refreshable { await store.refresh(revalidateProfiles: true) }
        }
    }

    @ViewBuilder
    private var contactList: some View {
        List {
            NavigationLink(value: V2ContactsRoute.requests) {
                Label("新的朋友", systemImage: "person.crop.circle.badge.plus")
            }
            .accessibilityValue(store.incomingRequestCount == 0 ? "" : "\(store.incomingRequestCount) 个待处理申请")
            .accessibilityIdentifier("v2.contacts.requests")

            Section("我的好友") {
                if store.filteredFriends.isEmpty {
                    ContentUnavailableView(
                        store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无好友" : "未找到联系人",
                        systemImage: "person.2"
                    )
                } else {
                    ForEach(store.filteredFriends) { item in
                        NavigationLink(value: V2ContactsRoute.contact(item.id)) {
                            V2ContactRow(item: item)
                        }
                        .accessibilityIdentifier("v2.contacts.friend.\(item.id)")
                    }
                    if store.canLoadMoreFriends {
                        contactLoadMoreButton("加载更多好友") { await store.loadMoreFriends() }
                    }
                }
            }
        }
        .searchable(text: $store.searchQuery, prompt: "搜索好友")
        .task(id: store.searchQuery) {
            guard !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await store.refreshFriendSearch()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await store.refreshFriendSearch()
        }
        .accessibilityIdentifier("v2.contacts.list")
    }

    private func contactLoadMoreButton(
        _ title: String,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> some View {
        HStack {
            Spacer()
            if store.isLoadingMoreContacts {
                ProgressView().accessibilityLabel("正在加载更多联系人")
            } else {
                Button(title) { Task { await action() } }
            }
            Spacer()
        }
    }
}

private struct V2FriendRequestsView: View {
    @Bindable var store: V2ContactsStore
    @State private var actionTask: Task<Void, Never>?

    var body: some View {
        List {
            Section("收到的申请") {
                if store.incomingRequests.isEmpty {
                    Text("暂无待处理申请").foregroundStyle(.secondary)
                }
                ForEach(store.incomingRequests) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        V2ContactRow(item: item)
                        HStack {
                            Button("接受") { run { await store.accept(item) } }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.isUpdating(item))
                                .accessibilityIdentifier("v2.contacts.request.accept.\(item.id)")
                            Button("拒绝", role: .destructive) { run { await store.reject(item) } }
                                .buttonStyle(.bordered)
                                .disabled(store.isUpdating(item))
                                .accessibilityIdentifier("v2.contacts.request.reject.\(item.id)")
                        }
                    }
                }
                if store.incomingRequestsNextCursor != nil {
                    loadMoreButton("加载更多收到的申请") { await store.loadMoreIncomingRequests() }
                }
            }
            Section("已发出的申请") {
                if store.outgoingRequests.isEmpty {
                    Text("暂无已发申请").foregroundStyle(.secondary)
                }
                ForEach(store.outgoingRequests) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        V2ContactRow(item: item)
                        Button("撤销申请", role: .destructive) { run { await store.remove(item) } }
                            .buttonStyle(.bordered)
                            .disabled(store.isUpdating(item))
                            .accessibilityIdentifier("v2.contacts.request.cancel.\(item.id)")
                    }
                }
                if store.outgoingRequestsNextCursor != nil {
                    loadMoreButton("加载更多已发申请") { await store.loadMoreOutgoingRequests() }
                }
            }
            if let feedback = store.feedback {
                Section { Text(feedback).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("新的朋友")
        .onDisappear { actionTask?.cancel() }
    }

    private func run(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        actionTask?.cancel()
        actionTask = Task { await operation() }
    }

    private func loadMoreButton(
        _ title: String,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> some View {
        HStack {
            Spacer()
            if store.isLoadingMoreContacts {
                ProgressView().accessibilityLabel("正在加载更多联系人")
            } else {
                Button(title) { run(action) }
            }
            Spacer()
        }
    }
}

private struct V2AddFriendView: View {
    @Bindable var store: V2ContactsStore
    @State private var actionTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("公开 ID") {
                TextField("例如 @alice", text: $store.addFriendHandle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(store.addFriendState == .resolving)
                    .accessibilityIdentifier("v2.contacts.add.handle")
                Button("查找") { run { await store.resolveAddFriend() } }
                    .disabled(store.addFriendHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.addFriendState == .resolving)
                    .accessibilityIdentifier("v2.contacts.add.resolve")
            }
            if case .resolved(let userID, _, _) = store.addFriendState,
               let item = store.item(userID: userID) {
                Section("当前关系") {
                    V2ContactRow(item: item)
                }
            } else if case .resolved(_, let displayName, let handle) = store.addFriendState {
                Section("用户") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                        Text(handle).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("发送好友申请") { run { await store.sendFriendRequest() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("v2.contacts.add.submit")
                }
            }
            if let feedback = store.feedback {
                Section { Text(feedback).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("添加好友")
        .onDisappear {
            actionTask?.cancel()
            store.resetAddFriend()
        }
    }

    private func run(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        actionTask?.cancel()
        actionTask = Task { await operation() }
    }
}

private struct V2ContactDetailView: View {
    enum PendingAction: Identifiable {
        case remove(V2ContactListItem)
        case block(V2ContactListItem)
        var id: String {
            switch self {
            case .remove: "remove"
            case .block: "block"
            }
        }
    }

    @Bindable var store: V2ContactsStore
    let userID: String
    let rootNavigation: V2RootNavigationStore
    @State private var actionTask: Task<Void, Never>?
    @State private var pendingAction: PendingAction?

    var body: some View {
        Group {
            if let item = store.item(userID: userID) {
                List {
                    Section("联系人") { V2ContactRow(item: item) }
                    actions(for: item)
                    if let feedback = store.feedback {
                        Section { Text(feedback).foregroundStyle(.secondary) }
                    }
                }
                .navigationTitle(item.displayName)
                .confirmationDialog(
                    confirmationTitle,
                    isPresented: Binding(
                        get: { pendingAction != nil },
                        set: { if !$0 { pendingAction = nil } }
                    ),
                    presenting: pendingAction
                ) { action in
                    switch action {
                    case .remove(let target):
                        Button("删除好友", role: .destructive) {
                            pendingAction = nil
                            run { await store.remove(target) }
                        }
                    case .block(let target):
                        Button("屏蔽用户", role: .destructive) {
                            pendingAction = nil
                            run { await store.block(target) }
                        }
                    }
                } message: { _ in
                    Text(confirmationMessage)
                }
            } else {
                ContentUnavailableView("联系人已不可用", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .onDisappear { actionTask?.cancel() }
    }

    @ViewBuilder
    private func actions(for item: V2ContactListItem) -> some View {
        switch item.relationship {
        case .friend:
            Section {
                Button("发消息") {
                    run {
                        if let roomID = await store.openConversation(with: item) {
                            rootNavigation.showConversation(roomID: roomID)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isUpdating(item) || item.publicIdentity == nil)
                .accessibilityIdentifier("v2.contacts.detail.message.\(item.id)")
                Button("删除好友", role: .destructive) { pendingAction = .remove(item) }
                    .disabled(store.isUpdating(item))
                    .accessibilityIdentifier("v2.contacts.detail.remove.\(item.id)")
                Button("屏蔽用户", role: .destructive) { pendingAction = .block(item) }
                    .disabled(store.isUpdating(item))
                    .accessibilityIdentifier("v2.contacts.detail.block.\(item.id)")
            }
        case .incomingRequest:
            Section {
                Button("接受") { run { await store.accept(item) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isUpdating(item))
                Button("拒绝", role: .destructive) { run { await store.reject(item) } }
                    .disabled(store.isUpdating(item))
            }
        case .outgoingRequest:
            Section {
                Button("撤销申请", role: .destructive) { run { await store.remove(item) } }
                    .disabled(store.isUpdating(item))
            }
        }
    }

    private func run(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        actionTask?.cancel()
        actionTask = Task { await operation() }
    }

    private var confirmationTitle: String {
        switch pendingAction {
        case .remove: "确认删除好友？"
        case .block: "确认屏蔽用户？"
        case nil: ""
        }
    }

    private var confirmationMessage: String {
        switch pendingAction {
        case .remove: "删除后，你们不再属于好友关系。"
        case .block: "屏蔽后，你们之间不能继续发起新的私聊消息。"
        case nil: ""
        }
    }
}

private struct V2ContactRow: View {
    let item: V2ContactListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.displayName).font(.body)
            if let handle = item.handle {
                Text(handle).font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("资料暂不可用").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.handle.map { "\(item.displayName)，\($0)" } ?? item.displayName)
    }
}
