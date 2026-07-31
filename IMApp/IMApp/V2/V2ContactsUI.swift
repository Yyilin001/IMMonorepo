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

protocol V2ContactsReading: Sendable {
    func contactProjections() async throws -> [V2ContactProjection]
    func hydrateRelationshipProfiles(for userIDs: [UserID]) async throws
}

/// App-side composition of the reusable ClientKit stores. The profile reader
/// receives the relationship authorization context; it cannot turn a list of
/// IDs into a global profile directory.
actor V2GRDBContactsDataSource: V2ContactsReading {
    private let localStore: GRDBV2LocalSyncStore
    private let profiles: V2ProfileRepository

    init(localStore: GRDBV2LocalSyncStore, profiles: V2ProfileRepository) {
        self.localStore = localStore
        self.profiles = profiles
    }

    func contactProjections() async throws -> [V2ContactProjection] {
        let relationships = try await localStore.relationships()
        let active = relationships.filter { $0.state == .pending || $0.state == .accepted }
        let profileViews = try await localStore.profileViews(userIDs: active.map(\.targetUserID))
        return active.map {
            .init(
                userID: $0.targetUserID,
                state: $0.state,
                requestedByUserID: $0.requestedByUserID,
                updatedAt: $0.updatedAt,
                publicIdentity: profileViews[$0.targetUserID]?.publicIdentity
            )
        }
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
    private var resolvedAddIdentity: V2PublicIdentity?
    private var refreshingGeneration = 0
    private var updatingUserIDs = Set<UserID>()

    private(set) var state: State = .loading
    private(set) var friends: [V2ContactListItem] = []
    private(set) var incomingRequests: [V2ContactListItem] = []
    private(set) var outgoingRequests: [V2ContactListItem] = []
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
        guard !query.isEmpty else { return friends }
        return friends.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || ($0.handle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var incomingRequestCount: Int { incomingRequests.count }

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
            var projections = try await dataSource.contactProjections()
            try Task.checkCancellation()
            let profileTargets: [UserID]
            if revalidateProfiles {
                profileTargets = projections.map(\.userID)
            } else {
                profileTargets = projections.compactMap { $0.publicIdentity == nil ? $0.userID : nil }
            }
            if !profileTargets.isEmpty {
                do {
                    try await dataSource.hydrateRelationshipProfiles(for: profileTargets)
                    try Task.checkCancellation()
                    projections = try await dataSource.contactProjections()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A cached contact list remains useful offline. The row
                    // itself makes the missing-profile state explicit.
                    feedback = "部分联系人资料暂不可更新。"
                }
            }
            guard generation == refreshingGeneration else { return }
            apply(projections)
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshingGeneration else { return }
            state = .failed
        }
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

    private func apply(_ projections: [V2ContactProjection]) {
        let items = projections.compactMap { projection -> V2ContactListItem? in
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
        allItems = items
        friends = items.filter { $0.relationship == .friend }.sorted(by: contactOrdering)
        incomingRequests = items.filter { $0.relationship == .incomingRequest }.sorted(by: recentFirst)
        outgoingRequests = items.filter { $0.relationship == .outgoingRequest }.sorted(by: recentFirst)
    }

    private func contactOrdering(_ lhs: V2ContactListItem, _ rhs: V2ContactListItem) -> Bool {
        let lhsName = lhs.displayName
        let rhsName = rhs.displayName
        let result = lhsName.localizedStandardCompare(rhsName)
        return result == .orderedSame ? lhs.id < rhs.id : result == .orderedAscending
    }

    private func recentFirst(_ lhs: V2ContactListItem, _ rhs: V2ContactListItem) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
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
            .accessibilityValue(store.incomingRequestCount == 0 ? "" : "(store.incomingRequestCount) 个待处理申请")
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
                }
            }
        }
        .searchable(text: $store.searchQuery, prompt: "搜索好友")
        .accessibilityIdentifier("v2.contacts.list")
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
