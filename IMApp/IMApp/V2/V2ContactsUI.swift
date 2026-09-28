import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

/// 在本地投影边界组装好的展示数据。
///
/// 视图既不会收到 GRDB 行或传输 DTO，也不会渲染不透明标识。
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

struct V2ContactProjectionWindow: Sendable {
    let page: V2ContactProjectionPage
    let anchorID: String?
    let hasEarlier: Bool
}

protocol V2ContactsWindowReading: Sendable {
    func contactProjectionWindow(scope: V2ContactProjectionPageScope, matching query: String?, around anchor: V2ClientRelationshipCursor, limit: Int, precedingCount: Int, includeTotalCount: Bool) async throws -> V2ContactProjectionWindow
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

/// 应用侧对可复用 ClientKit 存储的组合。
///
/// 资料读取器只会收到关系授权上下文，因此无法把一组标识变成全局资料目录。
actor V2GRDBContactsDataSource: V2ContactsReading, V2ContactsWindowReading {
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
        return try await projectionPage(page)
    }

    func contactProjectionWindow(scope: V2ContactProjectionPageScope, matching query: String?, around anchor: V2ClientRelationshipCursor, limit: Int, precedingCount: Int, includeTotalCount: Bool) async throws -> V2ContactProjectionWindow {
        let clientScope: V2ClientRelationshipPageScope = switch scope {
        case .friends: .accepted
        case .incomingRequests: .incomingRequests(currentUserID: currentUserID)
        case .outgoingRequests: .outgoingRequests(currentUserID: currentUserID)
        }
        let window = try await localStore.relationshipWindow(scope: clientScope, matching: query, around: anchor, limit: limit, precedingCount: precedingCount)
        let page = try await projectionPage(window.page)
        let total = includeTotalCount ? try await localStore.relationshipPage(scope: clientScope, matching: query, limit: 1, includeTotalCount: true).totalCount : nil
        return .init(page: .init(projections: page.projections, nextCursor: page.nextCursor, totalCount: total), anchorID: window.anchor?.targetUserID.rawValue, hasEarlier: window.hasEarlier)
    }

    private func projectionPage(_ page: V2ClientRelationshipPage) async throws -> V2ContactProjectionPage {
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
    let friendsViewport = V2ListViewport()
    let requestsViewport = V2ListViewport()

    enum State: Equatable {
        case loading
        case loaded
        case failed
    }

    enum AddFriendState: Equatable {
        case entering
        case resolving
        case resolved(V2PublicIdentityLookupSnapshot)
        case failed
    }

    private let dataSource: any V2ContactsReading
    private let windowReader: (any V2ContactsWindowReading)?
    private let identityResolver: any V2PublicIdentityPresentationResolving
    private(set) var socialPending:[V2SocialOperationPending]=[]
    private(set) var socialProposals:[V2SocialOperationProposal]=[]
    var socialConfirmation:V2SocialConfirmationProposal?
    private let relationshipChanger: any V2RelationshipChanging
    private let userBlockChanger: any V2UserBlockChanging
    private let directConversationOpener: any V2DirectConversationOpening
    private let currentUserID: UserID
    private let projectionChangeNotifier: V2ProjectionChangeNotifier?
    private var allItems: [V2ContactListItem] = []
    private var friendSearchResults: [V2ContactListItem] = []
    private var addFriendDemand = UUID()
    private var addFriendFlight: (id: UUID, task: Task<V2PublicIdentityLookupSnapshot, Error>)?
    private var refreshingGeneration = 0
    private var searchGeneration = 0
    private var updatingUserIDs = Set<UserID>()
    private enum PageLane: Hashable { case friends, search, incoming, outgoing }
    private var pageOperations: [PageLane: UUID] = [:]
    private var refreshOperation: UUID?
    private var searchRefreshOperation: UUID?
    private var loadedSearchQuery: String?
    private var earlierLanes = Set<PageLane>()
    var hasEarlierFriends: Bool { earlierLanes.contains(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .friends : .search) }
    var hasEarlierIncomingRequests: Bool { earlierLanes.contains(.incoming) }
    var hasEarlierOutgoingRequests: Bool { earlierLanes.contains(.outgoing) }

    private(set) var state: State = .loading
    private(set) var isStale = false
    private(set) var readFeedback: String?
    var canUseContactActions: Bool { state == .loaded && !isStale }
    private(set) var friends: [V2ContactListItem] = []
    private(set) var incomingRequests: [V2ContactListItem] = []
    private(set) var outgoingRequests: [V2ContactListItem] = []
    private(set) var incomingRequestCount = 0
    private(set) var friendsNextCursor: V2ClientRelationshipCursor?
    private(set) var incomingRequestsNextCursor: V2ClientRelationshipCursor?
    private(set) var outgoingRequestsNextCursor: V2ClientRelationshipCursor?
    private(set) var friendSearchNextCursor: V2ClientRelationshipCursor?
    var isLoadingMoreContacts: Bool { !pageOperations.isEmpty }
    private(set) var feedback: String?
    private(set) var addFriendState: AddFriendState = .entering
    var searchQuery = ""
    var addFriendHandle = "" {
        didSet {
            guard oldValue != addFriendHandle else { return }
            invalidateAddFriendResolution()
        }
    }
    var resolvedAddFriend: V2PublicIdentityLookupSnapshot? {
        guard case .resolved(let snapshot) = addFriendState, snapshot.isValid() else { return nil }
        return snapshot
    }
    var addFriendExpiration: ContinuousClock.Instant? {
        guard case .resolved(let snapshot) = addFriendState else { return nil }
        return snapshot.deadline
    }

    init(
        dataSource: any V2ContactsReading,
        identityResolver: any V2PublicIdentityPresentationResolving,
        relationshipChanger: any V2RelationshipChanging,
        userBlockChanger: any V2UserBlockChanging,
        directConversationOpener: any V2DirectConversationOpening,
        currentUserID: UserID,
        projectionChangeNotifier: V2ProjectionChangeNotifier? = nil,
        nameOperations: V2NameOperationService? = nil
    ) {
        self.dataSource = dataSource
        windowReader = dataSource as? any V2ContactsWindowReading
        self.identityResolver = identityResolver
        self.relationshipChanger = relationshipChanger
        self.userBlockChanger = userBlockChanger
        self.directConversationOpener = directConversationOpener
        self.currentUserID = currentUserID
        self.projectionChangeNotifier = projectionChangeNotifier
        self.nameOperations = nameOperations
    }

    private let nameOperations: V2NameOperationService?
    func nameEditor(for item: V2ContactListItem) -> V2NameEditorStore? {
        guard canUseContactActions, item.relationship == .friend, let nameOperations else { return nil }
        return .init(target: .contact(item.userID), service: nameOperations)
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
        let operation = UUID()
        refreshOperation = operation
        pageOperations.removeAll()
        defer { if refreshOperation == operation { refreshOperation = nil } }
        let friendCount = max(Self.pageSize, friends.count)
        let incomingCount = max(Self.pageSize, incomingRequests.count)
        let outgoingCount = max(Self.pageSize, outgoingRequests.count)
        if allItems.isEmpty { state = .loading }
        do {
            while true {
                let capturedFriendAnchor = friendsViewport.anchorID
                let requestAnchor = requestsViewport.anchorID
                let requestAnchorIsIncoming = incomingRequests.contains { $0.id == requestAnchor }
                let friendWindow = try await loadRetainedWindow(lane: .friends, viewportAnchorID: capturedFriendAnchor, count: friendCount, revalidateProfiles: revalidateProfiles)
                let incomingWindow = try await loadRetainedWindow(lane: .incoming, viewportAnchorID: requestAnchor, count: incomingCount, revalidateProfiles: revalidateProfiles, includeTotalCount: true)
                let outgoingWindow = try await loadRetainedWindow(lane: .outgoing, viewportAnchorID: requestAnchor, count: outgoingCount, revalidateProfiles: revalidateProfiles)
                let friendPage = friendWindow.page, incomingPage = incomingWindow.page, outgoingPage = outgoingWindow.page
                try Task.checkCancellation()
                guard generation == refreshingGeneration else { return }
                let friendRestoration: String?
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if case let .ready(target) = friendsViewport.resolveRead(capturedAnchorID: capturedFriendAnchor,
                        returnedIDs: friendPage.projections.map { $0.userID.rawValue }, fallback: friendWindow.anchorID) { friendRestoration = target }
                    else if windowReader != nil { continue }
                    else { friendRestoration = nil }
                } else { friendRestoration = nil }
                let requestRestoration: String?
                if case let .ready(target) = requestsViewport.resolveRead(capturedAnchorID: requestAnchor,
                    returnedIDs: (incomingPage.projections + outgoingPage.projections).map { $0.userID.rawValue },
                    fallback: requestAnchor == nil ? nil : (requestAnchorIsIncoming ? incomingWindow.anchorID : outgoingWindow.anchorID)) { requestRestoration = target }
                else if windowReader != nil { continue }
                else { requestRestoration = nil }
                apply(friendPage.projections, scope: .friends, appending: false)
                apply(incomingPage.projections, scope: .incomingRequests, appending: false)
                apply(outgoingPage.projections, scope: .outgoingRequests, appending: false)
                friendsNextCursor = friendPage.nextCursor
                incomingRequestsNextCursor = incomingPage.nextCursor
                outgoingRequestsNextCursor = outgoingPage.nextCursor
                incomingRequestCount = incomingPage.totalCount ?? incomingPage.projections.count
                setEarlier(friendWindow.hasEarlier, lane: .friends)
                setEarlier(incomingWindow.hasEarlier, lane: .incoming)
                setEarlier(outgoingWindow.hasEarlier, lane: .outgoing)
                reconcileViewports()
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { friendsViewport.restore(to: friendRestoration) }
                requestsViewport.restore(to: requestRestoration)
                isStale = false
                readFeedback = nil
                state = .loaded
                if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await refreshFriendSearch()
                }
                return
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == refreshingGeneration else { return }
            handleReadFailure(error)
        }
    }

    private func isAuthoritativeReadDenial(_ error: Error) -> Bool {
        (error as? V2HTTPFailure)?.statusCode == 403
            || (error as? V2AuthSessionError) == .unauthenticated
            || (error as? V2AuthSessionError) == .sessionInvalidated
    }

    private func handleReadFailure(_ error: Error) {
        // Withdraw the observed confirmation, retaining its durable proposal.
        // A stale directory must not leave a new sensitive command enabled.
        socialConfirmation = nil
        let denied = isAuthoritativeReadDenial(error)
        if denied {
            allItems = []; friends = []; incomingRequests = []; outgoingRequests = []; friendSearchResults = []
            incomingRequestCount = 0
            friendsNextCursor = nil; incomingRequestsNextCursor = nil; outgoingRequestsNextCursor = nil; friendSearchNextCursor = nil
            refreshingGeneration &+= 1
            searchGeneration &+= 1
            pageOperations.removeAll(); earlierLanes.removeAll()
            isStale = false
            readFeedback = "联系人访问权限已失效，请重新登录或刷新。"
            state = .failed
        } else {
            isStale = true
            readFeedback = "刷新失败，显示上次联系人内容；刷新成功后可继续操作。"
            state = allItems.isEmpty ? .failed : .loaded
        }
    }

    func refreshFriendSearch() async {
        guard state == .loaded else { return }
        searchGeneration &+= 1
        let generation = searchGeneration
        let operation = UUID()
        searchRefreshOperation = operation
        defer { if searchRefreshOperation == operation { searchRefreshOperation = nil } }
        pageOperations[.search] = nil
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if (loadedSearchQuery ?? "") != query {
            friendsViewport.reset()
            earlierLanes.remove(.search)
        }
        guard !query.isEmpty else {
            friendSearchResults = []
            friendSearchNextCursor = nil
            loadedSearchQuery = nil
            rebuildAllItems()
            reconcileViewports()
            return
        }
        do {
            let retainedCount = loadedSearchQuery == query ? max(Self.pageSize, friendSearchResults.count) : Self.pageSize
            while true {
                let capturedAnchor = friendsViewport.anchorID
                let window = try await loadRetainedWindow(lane: .search, viewportAnchorID: capturedAnchor, query: query, count: retainedCount, revalidateProfiles: false)
                let page = window.page
                try Task.checkCancellation()
                guard generation == searchGeneration,
                      query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                else { return }
                let restorationID: String?
                if case let .ready(target) = friendsViewport.resolveRead(capturedAnchorID: capturedAnchor,
                    returnedIDs: page.projections.map { $0.userID.rawValue }, fallback: window.anchorID) { restorationID = target }
                else if windowReader != nil { continue }
                else { restorationID = nil }
                friendSearchResults = makeItems(page.projections)
                friendSearchNextCursor = page.nextCursor
                loadedSearchQuery = query
                setEarlier(window.hasEarlier, lane: .search)
                rebuildAllItems()
                reconcileViewports()
                friendsViewport.restore(to: restorationID)
                return
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == searchGeneration else { return }
            handleReadFailure(error)
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

    func loadEarlierFriends() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        await loadEarlier(query.isEmpty ? .friends : .search, query: query.isEmpty ? nil : query)
    }
    func loadEarlierIncomingRequests() async { await loadEarlier(.incoming) }
    func loadEarlierOutgoingRequests() async { await loadEarlier(.outgoing) }

    func returnToFirstFriends() async {
        friendsViewport.reset()
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            friends = []; friendsNextCursor = nil; earlierLanes.remove(.friends)
            await refresh()
        } else {
            friendSearchResults = []; friendSearchNextCursor = nil; earlierLanes.remove(.search)
            await refreshFriendSearch()
        }
    }

    func observeProjectionChanges() async {
        guard let projectionChangeNotifier else {
            await refresh()
            return
        }
        await V2ProjectionRefreshObserver.run(await projectionChangeNotifier.updates(scopes: .contacts)) { [self] in
            await refresh()
        }
    }

    func resolveAddFriend() async {
        let handle = addFriendHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        let demand = UUID()
        addFriendDemand = demand
        if let previous = addFriendFlight {
            previous.task.cancel()
            // A noncooperative lookup still owns its slot until it returns.
            _ = await previous.task.result
        }
        guard addFriendDemand == demand else { return }
        guard !Task.isCancelled else {
            addFriendState = .entering
            return
        }
        guard let canonical = try? V2PublicHandle(handle) else {
            addFriendState = .failed
            feedback = "请输入有效的公开 ID。"
            return
        }
        addFriendState = .resolving
        feedback = nil
        let resolver = identityResolver
        let task = Task { try await resolver.resolveForPresentation(handle: canonical.rawValue) }
        addFriendFlight = (demand, task)
        defer { if addFriendFlight?.id == demand { addFriendFlight = nil } }
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard addFriendDemand == demand else { return }
            guard snapshot.isValid(), snapshot.resolution.actorUserID == currentUserID,
                  snapshot.identity.handle == canonical else { throw V2PublicIdentityDirectoryClientError.invalidResponse }
            guard snapshot.identity.userID != currentUserID else {
                addFriendState = .failed
                feedback = "不能添加自己为好友。"
                return
            }
            addFriendState = .resolved(snapshot)
        } catch is CancellationError {
            if addFriendDemand == demand { addFriendState = .entering }
        } catch {
            // Preserve the directory's privacy boundary: the UI never says
            // whether a handle is absent, blocked, or otherwise unavailable.
            guard addFriendDemand == demand else { return }
            addFriendState = .failed
            feedback = "无法找到此用户或当前无法添加。"
        }
    }

    func sendFriendRequest() async {
        guard let snapshot = resolvedAddFriend,
              (try? V2PublicHandle(addFriendHandle.trimmingCharacters(in: .whitespacesAndNewlines))) == snapshot.identity.handle else {
            invalidateAddFriendResolution()
            feedback = "请先确认要添加的用户。"
            return
        }
        await changeRelationship(target: snapshot.identity.userID, action: .request)
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
        guard canUseContactActions else {
            feedback = "请刷新联系人后再操作。"
            return
        }
        guard !updatingUserIDs.contains(item.userID) else { return }
        updatingUserIDs.insert(item.userID)
        defer { updatingUserIDs.remove(item.userID) }
        feedback = nil
        do {
            if let manager=userBlockChanger as? any V2SocialOperationManaging {
                let confirmationGeneration = refreshingGeneration
                let id=try await manager.saveSocialProposal(action:.userBlock(.block),target:item.userID)
                let baseline=try await manager.socialBaseline(target:item.userID)
                try Task.checkCancellation()
                guard confirmationGeneration == refreshingGeneration, canUseContactActions else { return }
                socialConfirmation = .init(snapshot:baseline,action:.userBlock(.block),proposalID:id)
                return
            }
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
        guard canUseContactActions else {
            feedback = "请刷新联系人后再打开会话。"
            return nil
        }
        guard let identity = item.publicIdentity else {
            feedback = "联系人资料暂不可用，请刷新后重试。"
            return nil
        }
        do {
            let roomID = try await directConversationOpener.openConversation(with: identity)
            try Task.checkCancellation()
            return roomID
        } catch V2DirectConversationOpeningState.queued {
            feedback = "已保存私聊请求，完成后会显示在会话列表中。再次点击可继续核对原请求。"
            return nil
        } catch V2DirectConversationOpeningState.expired {
            feedback = "私聊请求已过期，可重新发起。"
            return nil
        } catch V2DirectConversationOpeningState.rejected {
            feedback = "当前无法与对方创建私聊。"
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            feedback = "无法打开会话，请稍后重试。"
            return nil
        }
    }

    func resetAddFriend() {
        addFriendHandle = ""
        invalidateAddFriendResolution()
    }

    func invalidateAddFriendResolution() {
        addFriendDemand = UUID()
        addFriendFlight?.task.cancel()
        addFriendState = .entering
        feedback = nil
    }

    func expireAddFriendResolution(at now: ContinuousClock.Instant = .now) {
        guard case .resolved(let snapshot) = addFriendState, !snapshot.isValid(at: now) else { return }
        invalidateAddFriendResolution()
        feedback = "查找结果已过期，请重新查找。"
    }

    func observeSocialProposals() async {
        guard let manager=relationshipChanger as? any V2SocialOperationManaging else { return }
        do { for try await values in await manager.socialProposals() { guard !Task.isCancelled else {return};socialProposals=values } } catch is CancellationError {} catch {feedback="保存的联系人提案暂不可读。"}
    }
    private func canConfirmSocialAction(_ action: V2SocialOperationAction) -> Bool {
        if case .relationship(.request) = action { return !isStale && state != .failed }
        return canUseContactActions
    }
    func prepareSocialProposal(_ proposal:V2SocialOperationProposal) async {
        guard canConfirmSocialAction(proposal.action), let manager=relationshipChanger as? any V2SocialOperationManaging else {
            feedback="请刷新联系人后再确认，提案已保留。"; return
        }
        let confirmationGeneration = refreshingGeneration
        do {
            let baseline=try await manager.socialBaseline(target:proposal.targetUserID)
            try Task.checkCancellation()
            guard confirmationGeneration == refreshingGeneration, canConfirmSocialAction(proposal.action) else { return }
            socialConfirmation = .init(snapshot:baseline,action:proposal.action,proposalID:proposal.id)
        } catch is CancellationError { }
        catch {feedback="提案已保留，读取权威基线后才能确认。"}
    }
    func discardSocialProposal(_ id:UUID) async {
        guard let manager=relationshipChanger as? any V2SocialOperationManaging else {return}
        do {try await manager.discardSocialProposal(id:id)} catch {feedback="无法取消提案。"}
    }
    func observeSocialOperations() async {
        guard let manager=relationshipChanger as? any V2SocialOperationManaging else { return }
        do { for try await values in await manager.socialUpdates() { guard !Task.isCancelled else { return };socialPending=values } }
        catch is CancellationError {} catch { feedback="联系人操作状态暂时无法读取。" }
    }
    func confirmSocialOperation() async {
        guard let proposal=socialConfirmation,let manager=relationshipChanger as? any V2SocialOperationManaging else { return }
        socialConfirmation=nil
        guard canConfirmSocialAction(proposal.action) else { feedback="请刷新联系人后再确认，提案已保留。"; return }
        guard proposal.expiresAt > .now else { feedback="确认基线已过期，请重新读取后确认。";return }
        do { if let id=proposal.proposalID {try await manager.confirmSocialProposal(id:id,snapshot:proposal.snapshot)} else {try await manager.enqueueSocial(action:proposal.action,snapshot:proposal.snapshot)};feedback="原联系人操作已保存，正在核对。" }
        catch { feedback="无法保存联系人操作，请重新读取后确认。" }
    }
    func resumeSocialOperation(_ id:UUID) async {
        guard let manager=relationshipChanger as? any V2SocialOperationManaging else { return }
        do { try await manager.resumeSocialConfirmation(workID:id) } catch { feedback="无法继续核对原联系人操作。" }
    }
    private func changeRelationship(target: UserID, action: V2RelationshipAction) async {
        guard action == .request || canUseContactActions else {
            feedback = "请刷新联系人后再操作。"
            return
        }
        guard !updatingUserIDs.contains(target) else { return }
        updatingUserIDs.insert(target)
        defer { updatingUserIDs.remove(target) }
        feedback = nil
        do {
            if let manager=relationshipChanger as? any V2SocialOperationManaging {
                let confirmationGeneration = refreshingGeneration
                let id=try await manager.saveSocialProposal(action:.relationship(action),target:target)
                let baseline=try await manager.socialBaseline(target:target)
                try Task.checkCancellation()
                guard confirmationGeneration == refreshingGeneration, canConfirmSocialAction(.relationship(action)) else { return }
                socialConfirmation = .init(snapshot:baseline,action:.relationship(action),proposalID:id)
                return
            }
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

    private func laneItems(_ lane: PageLane) -> [V2ContactListItem] {
        switch lane { case .friends: friends; case .search: friendSearchResults; case .incoming: incomingRequests; case .outgoing: outgoingRequests }
    }

    private func laneScope(_ lane: PageLane) -> V2ContactProjectionPageScope {
        switch lane { case .friends, .search: .friends; case .incoming: .incomingRequests; case .outgoing: .outgoingRequests }
    }

    private func windowLimit(_ lane: PageLane) -> Int { lane == .friends || lane == .search ? 300 : 150 }

    private func setEarlier(_ value: Bool, lane: PageLane) {
        if value { earlierLanes.insert(lane) } else { earlierLanes.remove(lane) }
    }

    private func reconcileViewports() {
        friendsViewport.reconcile(ids: filteredFriends.map(\.id))
        requestsViewport.reconcile(ids: (incomingRequests + outgoingRequests).map(\.id))
    }

    private func loadRetainedWindow(lane: PageLane, viewportAnchorID: String?, query: String? = nil, count: Int, revalidateProfiles: Bool, includeTotalCount: Bool = false) async throws -> V2ContactProjectionWindow {
        let values = laneItems(lane)
        let activeID = lane == .friends && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : viewportAnchorID
        let anchorID = values.contains(where: { $0.id == activeID }) ? activeID : (earlierLanes.contains(lane) ? values.first?.id : nil)
        let limit = min(count, windowLimit(lane))
        guard let windowReader, let index = values.firstIndex(where: { $0.id == anchorID }) else {
            let page = try await loadProjectionWindow(scope: laneScope(lane), matching: query, count: limit, revalidateProfiles: revalidateProfiles, includeTotalCount: includeTotalCount)
            return .init(page: page, anchorID: nil, hasEarlier: false)
        }
        let anchor = V2ClientRelationshipCursor(updatedAt: values[index].updatedAt, targetUserID: values[index].userID)
        return try await loadAnchoredWindow(reader: windowReader, lane: lane, query: query, anchor: anchor,
            limit: limit, precedingCount: min(50, index, limit - 1), revalidateProfiles: revalidateProfiles, includeTotalCount: includeTotalCount)
    }

    private func loadAnchoredWindow(reader: any V2ContactsWindowReading, lane: PageLane, query: String?,
        anchor: V2ClientRelationshipCursor, limit: Int, precedingCount: Int,
        revalidateProfiles: Bool, includeTotalCount: Bool) async throws -> V2ContactProjectionWindow {
        let generation = refreshingGeneration, queryGeneration = searchGeneration
        var window = try await reader.contactProjectionWindow(scope: laneScope(lane), matching: query, around: anchor,
            limit: limit, precedingCount: precedingCount, includeTotalCount: includeTotalCount)
        try Task.checkCancellation()
        guard generation == refreshingGeneration,
              lane != .search || (queryGeneration == searchGeneration && query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw CancellationError() }
        let targets = revalidateProfiles ? window.page.projections.map(\.userID) : window.page.projections.compactMap { $0.publicIdentity == nil ? $0.userID : nil }
        if !targets.isEmpty {
            do {
                try await dataSource.hydrateRelationshipProfiles(for: targets)
                try Task.checkCancellation()
                guard generation == refreshingGeneration,
                      lane != .search || (queryGeneration == searchGeneration && query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
                else { throw CancellationError() }
                let refreshed = try await reader.contactProjectionWindow(scope: laneScope(lane), matching: query, around: anchor,
                    limit: limit, precedingCount: precedingCount, includeTotalCount: false)
                try Task.checkCancellation()
                guard generation == refreshingGeneration,
                      lane != .search || (queryGeneration == searchGeneration && query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
                else { throw CancellationError() }
                window = .init(page: .init(projections: refreshed.page.projections, nextCursor: refreshed.page.nextCursor, totalCount: window.page.totalCount), anchorID: refreshed.anchorID, hasEarlier: refreshed.hasEarlier)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                guard generation == refreshingGeneration,
                      lane != .search || (queryGeneration == searchGeneration && query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
                else { throw CancellationError() }
                if isAuthoritativeReadDenial(error) { throw error }
                feedback = "部分联系人资料暂不可更新。"
            }
        }
        return window
    }

    private func loadProjectionWindow(
        scope: V2ContactProjectionPageScope,
        matching query: String? = nil,
        count: Int,
        revalidateProfiles: Bool,
        includeTotalCount: Bool = false
    ) async throws -> V2ContactProjectionPage {
        let generation = refreshingGeneration, queryGeneration = searchGeneration
        var projections: [V2ContactProjection] = []
        var seen = Set<UserID>()
        var cursor: V2ClientRelationshipCursor?
        var totalCount: Int?
        for offset in stride(from: 0, to: count, by: Self.pageSize) {
            let page = try await loadProjectionPage(scope: scope, matching: query, before: cursor,
                revalidateProfiles: revalidateProfiles, includeTotalCount: includeTotalCount && offset == 0)
            try Task.checkCancellation()
            guard generation == refreshingGeneration,
                  query == nil || (queryGeneration == searchGeneration && query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
            else { throw CancellationError() }
            guard page.nextCursor == nil || page.nextCursor != cursor else { throw V2ClientProjectionError.invalidMessagePayload }
            projections.append(contentsOf: page.projections.filter { seen.insert($0.userID).inserted })
            cursor = page.nextCursor
            if offset == 0 { totalCount = page.totalCount }
            if cursor == nil { break }
        }
        return .init(projections: projections, nextCursor: cursor, totalCount: totalCount)
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
        try Task.checkCancellation()
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
            try Task.checkCancellation()
            page = .init(
                projections: page.projections,
                nextCursor: page.nextCursor,
                totalCount: totalCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            if isAuthoritativeReadDenial(error) { throw error }
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
        let lane: PageLane = switch scope {
        case .friends: query == nil ? .friends : .search
        case .incomingRequests: .incoming
        case .outgoingRequests: .outgoing
        }
        guard let cursor, state == .loaded, refreshOperation == nil, pageOperations[lane] == nil else { return }
        if lane == .search {
            guard searchRefreshOperation == nil, query == loadedSearchQuery else { return }
        }
        let refreshGeneration = refreshingGeneration
        let currentSearchGeneration = searchGeneration
        let operation = UUID()
        pageOperations[lane] = operation
        defer { if pageOperations[lane] == operation { pageOperations[lane] = nil } }
        do {
            let page = try await loadProjectionPage(scope: scope, matching: query, before: cursor, revalidateProfiles: false)
            try Task.checkCancellation()
            guard refreshGeneration == refreshingGeneration else { return }
            if let query {
                guard currentSearchGeneration == searchGeneration,
                      query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                else { return }
            }
            let viewport = lane == .friends || lane == .search ? friendsViewport : requestsViewport
            let anchorID = viewport.anchorID ?? laneItems(lane).last?.id
            let values = laneItems(lane)
            let existingIDs = Set(values.map(\.id))
            let additions = Set(page.projections.map { $0.userID.rawValue }).subtracting(existingIDs).count
            let removedCount = max(0, values.count + additions - windowLimit(lane))
            if let activeID = viewport.anchorID, values.prefix(removedCount).contains(where: { $0.id == activeID }) { return }
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
            let removed = trimWindow(lane)
            rebuildAllItems()
            reconcileViewports()
            if removed { viewport.restore(to: anchorID ?? laneItems(lane).first?.id) }
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == refreshingGeneration,
                  query == nil || (currentSearchGeneration == searchGeneration && query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return }
            handleReadFailure(error)
            feedback = "无法加载更多联系人。"
        }
    }

    private func trimWindow(_ lane: PageLane) -> Bool {
        let excess = max(0, laneItems(lane).count - windowLimit(lane))
        guard excess > 0 else { return false }
        switch lane {
        case .friends: friends.removeFirst(excess)
        case .search: friendSearchResults.removeFirst(excess)
        case .incoming: incomingRequests.removeFirst(excess)
        case .outgoing: outgoingRequests.removeFirst(excess)
        }
        earlierLanes.insert(lane)
        return true
    }

    private func loadEarlier(_ lane: PageLane, query: String? = nil) async {
        guard let windowReader, earlierLanes.contains(lane), refreshOperation == nil, pageOperations[lane] == nil,
              let first = laneItems(lane).first else { return }
        if lane == .search { guard searchRefreshOperation == nil, loadedSearchQuery == query else { return } }
        let operation = UUID(), generation = refreshingGeneration, queryGeneration = searchGeneration
        let viewport = lane == .friends || lane == .search ? friendsViewport : requestsViewport
        let capturedAnchorID = viewport.anchorID
        pageOperations[lane] = operation
        defer { if pageOperations[lane] == operation { pageOperations[lane] = nil } }
        do {
            let window = try await loadAnchoredWindow(reader: windowReader, lane: lane, query: query,
                anchor: .init(updatedAt: first.updatedAt, targetUserID: first.userID), limit: windowLimit(lane),
                precedingCount: windowLimit(lane) - 50, revalidateProfiles: false, includeTotalCount: false)
            try Task.checkCancellation()
            guard generation == refreshingGeneration,
                  lane != .search || (queryGeneration == searchGeneration && query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            let otherRequestIDs: [String] = switch lane {
            case .incoming: outgoingRequests.map(\.id)
            case .outgoing: incomingRequests.map(\.id)
            case .friends, .search: []
            }
            guard case let .ready(restorationID) = viewport.resolveRead(capturedAnchorID: capturedAnchorID,
                returnedIDs: window.page.projections.map { $0.userID.rawValue } + otherRequestIDs,
                fallback: window.page.projections.first?.userID.rawValue) else { return }
            switch lane {
            case .friends: friends = makeItems(window.page.projections); friendsNextCursor = window.page.nextCursor
            case .search: friendSearchResults = makeItems(window.page.projections); friendSearchNextCursor = window.page.nextCursor
            case .incoming: incomingRequests = makeItems(window.page.projections); incomingRequestsNextCursor = window.page.nextCursor
            case .outgoing: outgoingRequests = makeItems(window.page.projections); outgoingRequestsNextCursor = window.page.nextCursor
            }
            setEarlier(window.hasEarlier, lane: lane)
            rebuildAllItems()
            reconcileViewports()
            viewport.restore(to: restorationID)
        } catch is CancellationError { return }
        catch {
            guard generation == refreshingGeneration,
                  lane != .search || (queryGeneration == searchGeneration && query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            handleReadFailure(error)
            feedback = "无法加载前面的联系人。"
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
    @State private var profilePageID = UUID()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch store.state {
                case .loading:
                    ProgressView("正在加载联系人…")
                case .failed:
                    ContentUnavailableView("无法读取联系人", systemImage: "person.crop.circle.badge.exclamationmark", description: Text(store.readFeedback ?? "请检查网络或本地数据后重试。"))
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
            .safeAreaInset(edge:.bottom) { VStack { V2SocialProposalList(proposals:store.socialProposals,prepare:{await store.prepareSocialProposal($0)},discard:{await store.discardSocialProposal($0)})
                V2SocialPendingStatusView(pending:store.socialPending) { id in await store.resumeSocialOperation(id) } } }
            .confirmationDialog("确认联系人操作",isPresented:Binding(get:{store.socialConfirmation != nil},set:{if !$0 {store.socialConfirmation=nil}})) { Button("确认保存原操作") { Task {await store.confirmSocialOperation()} } } message: { Text(store.socialConfirmation?.description ?? "") }
            .task { await store.observeSocialProposals() }
            .task { await store.observeSocialOperations() }
            .task { await store.observeProjectionChanges() }
            .refreshable { await store.refresh(revalidateProfiles: true) }
        }
    }

    @ViewBuilder
    private var contactList: some View {
        List {
            if let message = store.readFeedback {
                Text(message).foregroundStyle(.secondary).accessibilityIdentifier("v2.contacts.readFeedback")
            }
            NavigationLink(value: V2ContactsRoute.requests) {
                Label("新的朋友", systemImage: "person.crop.circle.badge.plus")
            }
            .accessibilityValue(store.incomingRequestCount == 0 ? "" : "\(store.incomingRequestCount) 个待处理申请")
            .accessibilityIdentifier("v2.contacts.requests")

            Section("我的好友") {
                if store.hasEarlierFriends {
                    Button("查看前面的好友") { Task { await store.loadEarlierFriends() } }
                        .accessibilityIdentifier("v2.contacts.friends.load-earlier")
                    Button("回到好友列表开头") { Task { await store.returnToFirstFriends() } }
                        .accessibilityIdentifier("v2.contacts.friends.return-to-first")
                }
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
                        .id(item.id)
                        .modifier(V2ListViewportRow(viewport: store.friendsViewport, itemID: item.id, coordinateSpace: "v2.contacts.friends.viewport"))
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
        .authorPresentationPage(context: .list(profilePageID))
        .modifier(V2ListViewportContainer(viewport: store.friendsViewport, coordinateSpace: "v2.contacts.friends.viewport"))
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

struct V2FriendRequestsView: View {
    @Bindable var store: V2ContactsStore
    @State private var actionTask: Task<Void, Never>?
    @State private var profilePageID = UUID()

    var body: some View {
        List {
            Section("收到的申请") {
                if store.hasEarlierIncomingRequests {
                    Button("查看前面的收到申请") { run { await store.loadEarlierIncomingRequests() } }
                        .accessibilityIdentifier("v2.contacts.incoming.load-earlier")
                }
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
                    .id(item.id)
                    .modifier(V2ListViewportRow(viewport: store.requestsViewport, itemID: item.id, coordinateSpace: "v2.contacts.requests.viewport"))
                }
                if store.incomingRequestsNextCursor != nil {
                    loadMoreButton("加载更多收到的申请") { await store.loadMoreIncomingRequests() }
                }
            }
            Section("已发出的申请") {
                if store.hasEarlierOutgoingRequests {
                    Button("查看前面的已发申请") { run { await store.loadEarlierOutgoingRequests() } }
                        .accessibilityIdentifier("v2.contacts.outgoing.load-earlier")
                }
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
                    .id(item.id)
                    .modifier(V2ListViewportRow(viewport: store.requestsViewport, itemID: item.id, coordinateSpace: "v2.contacts.requests.viewport"))
                }
                if store.outgoingRequestsNextCursor != nil {
                    loadMoreButton("加载更多已发申请") { await store.loadMoreOutgoingRequests() }
                }
            }
            if let feedback = store.feedback {
                Section { Text(feedback).foregroundStyle(.secondary) }
            }
        }
        .modifier(V2ListViewportContainer(viewport: store.requestsViewport, coordinateSpace: "v2.contacts.requests.viewport"))
        .navigationTitle("新的朋友")
        .authorPresentationPage(context: .list(profilePageID))
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
    @Environment(\.scenePhase) private var scenePhase
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
            if scenePhase == .active, let snapshot = store.resolvedAddFriend,
               let item = store.item(userID: snapshot.identity.userID.rawValue) {
                Section("当前关系") {
                    V2ContactRow(item: item)
                }
            } else if scenePhase == .active, let snapshot = store.resolvedAddFriend {
                Section("用户") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.identity.displayName)
                        Text(snapshot.identity.handle.description).font(.footnote).foregroundStyle(.secondary)
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
        .task(id: store.addFriendExpiration) {
            guard let deadline = store.addFriendExpiration else { return }
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            store.expireAddFriendResolution()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                actionTask?.cancel()
                store.invalidateAddFriendResolution()
            }
        }
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
    @State private var nameEditor: V2NameEditorStore?
    @State private var showsNameEditor = false

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
                .navigationTitle("联系人资料")
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
        .sheet(isPresented: $showsNameEditor) {
            if let nameEditor { V2NameEditorView(store: nameEditor) }
        }
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
                Button("编辑备注") {
                    nameEditor = store.nameEditor(for: item)
                    showsNameEditor = nameEditor != nil
                }
                .accessibilityIdentifier("v2.contacts.detail.remark.\(item.id)")
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
        V2AuthorizedAvatarView(key: .init(userID: item.userID, context: .relationship), showsName: true)
    }
}
