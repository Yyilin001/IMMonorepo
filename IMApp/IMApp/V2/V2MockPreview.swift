#if DEBUG
import SwiftUI
import IMV2ClientKit
import IMV2Core

/// Explicit visual fixtures. UUID-scoped resource tests may open their own
/// temporary files; no credentials or production storage are opened.
@MainActor
struct V2MockPreview: View {
    @State private var appStore = V2AppStore(startupMode: .uiTestingSignedOut)
    @State private var conversations: V2ConversationListStore
    @State private var contacts: V2ContactsStore
    @State private var privacy: V2PrivacySettingsStore
    @State private var navigation = V2RootNavigationStore()
    @State private var screen = "messages"
    @State private var resourceStagingStatus: String?
    private let source: V2MockPreviewSource
    private let notifier: V2ProjectionChangeNotifier

    init() {
        let source = V2MockPreviewSource()
        let notifier = V2ProjectionChangeNotifier()
        self.source = source
        self.notifier = notifier
        _conversations = State(initialValue: .init(environment: .init(userID: source.user.rawValue, projections: .init(dataSource: source, messageSearcher: ProcessInfo.processInfo.arguments.contains("-v2-mock-search") ? source : nil), messages: .init(sender: source), discovery: .init(directConversationOpener: source), runtime: .init(projectionChangeNotifier: notifier))))
        _contacts = State(initialValue: .init(dataSource: source, identityResolver: source, relationshipChanger: source,
            userBlockChanger: source, directConversationOpener: source, currentUserID: source.user))
        _privacy = State(initialValue: .init(reader: source, updater: source))
        let navigation = V2RootNavigationStore()
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-v2-mock-resource-staging-scope") {
            _resourceStagingStatus = State(initialValue: "正在准备附件测试")
        }
        if let i = args.firstIndex(of: "-v2-mock-screen"), i + 1 < args.count {
            let value = args[i + 1]
            _screen = State(initialValue: value)
            navigation.selectedTab = value == "contacts" ? .contacts : value == "me" ? .account : .conversations
        }
        _navigation = State(initialValue: navigation)
    }

    var body: some View {
        Group {
            if let resourceStagingStatus {
                Text(resourceStagingStatus).accessibilityIdentifier("mock.resource-staging.status")
            } else if ProcessInfo.processInfo.arguments.contains("-v2-mock-hide-controls") {
                VStack(spacing: 0) {
                    if ProcessInfo.processInfo.arguments.contains("-v2-mock-incoming-controls") {
                        Button("模拟收到消息") {
                            Task {
                                await source.receiveMessages()
                                await notifier.publish(.init(scopes: .conversationTimeline, requiresImmediateRefresh: true))
                            }
                        }.accessibilityIdentifier("mock.receive-messages")
                    }
                    previewContent
                }
            } else {
                VStack(spacing: 0) { previewControls; previewContent }
            }
        }
        .environment(\.v2MockProfileNames, Dictionary(uniqueKeysWithValues: [201: "小林", 202: "陈晨", 203: "阿青", 211: "李晓", 221: "周宁"].map { (String(format: "00000000-0000-0000-0000-%012d", $0.key), $0.value) }))
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "-v2-mock-resource-staging-scope"), index + 1 < args.count,
                  let scope = UUID(uuidString: args[index + 1]) else {
                await conversations.refresh(); return
            }
            await runResourceStagingFixture(scope: scope, cleanup: args.contains("-v2-mock-resource-staging-cleanup"))
        }
    }

    /// Opt-in filesystem integration only. Ordinary previews remain memory-only.
    /// The UUID is supplied by the test; cleanup cannot select another root.
    private func runResourceStagingFixture(scope: UUID, cleanup: Bool) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "v2-mock-resource-staging-" + scope.uuidString)
        do {
            if cleanup {
                if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
                resourceStagingStatus = "附件测试数据已清理"; return
            }
            let local = try await V2LocalStoreBootstrapper(bindingStore: V2MockResourceBinding(value: scope))
                .open(databaseURL: root.appending(path: "account.sqlite"), userID: source.user)
            let center: V2ResourceCenter
            do {
                center = try await .make(scope: .init(incarnation: scope, accountID: source.user,
                    directory: root.appending(path: "support"), cacheDirectory: root.appending(path: "cache")), store: local)
            } catch { try? await local.close(); throw error }
            let stager = V2FileConversationAttachmentStager(resources: center)
            conversations = .init(environment: .init(userID: source.user.rawValue,
                projections: .init(dataSource: source), messages: .init(sender: source),
                discovery: .init(directConversationOpener: source), media: .init(attachmentStager: stager),
                runtime: .init(projectionChangeNotifier: notifier)))
            await conversations.refresh()
            resourceStagingStatus = nil
            let lifetime = AsyncStream<Void>.makeStream()
            await withTaskCancellationHandler {
                for await _ in lifetime.stream { }
            } onCancel: { lifetime.continuation.finish() }
            await stager.close(); await center.close(); try await local.close()
        } catch { resourceStagingStatus = "附件测试准备失败" }
    }

    private var previewControls: some View {
        HStack {
            Text("Mock 界面预览").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu("切换页面") {
                ForEach(["messages", "chat", "contacts", "me", "privacy", "login", "register"], id: \.self) { item in
                    Button(title(item)) {
                        navigation.selectedTab = item == "contacts" ? .contacts : item == "me" ? .account : .conversations
                        screen = item
                    }
                }
            }.accessibilityIdentifier("mock.screens")
        }.padding(.horizontal).padding(.vertical, 8)
    }

    @ViewBuilder private var previewContent: some View {
        switch screen {
        case "chat":
            if conversations.state == .loaded {
                NavigationStack { V2ConversationDetailView(store: conversations.detailStore(for: V2MockPreviewSource.room)) }
            } else {
                ProgressView("正在载入示例消息…")
            }
        case "privacy":
            NavigationStack { V2PrivacySettingsView(store: privacy, pushWakeSettingsStore: nil, userBlockSettingsStore: nil) }
        case "login", "register":
            NavigationStack {
                V2SignInView(store: V2AppStore(startupMode: .uiTestingSignedOut), authenticationMessage: nil,
                    initialPasswordMode: screen == "register" ? .register : .signIn,
                    initialAccountHandle: nil, initialPassword: nil, initialPublicHandle: nil, initialDisplayName: nil)
            }
        default:
            V2SignedInRootView(
                appStore: appStore,
                conversationStore: conversations,
                contactsStore: contacts,
                privacySettingsStore: privacy,
                userBlockSettingsStore: nil,
                publicIdentitySettingsStore: nil,
                pushWakeSettingsStore: nil,
                deviceSessionsStore: nil,
                groupInvitationStore: nil,
                pendingGroupInvitationURL: .constant(nil),
                makeGroupAvatarManagement: nil,
                localE2EConversationLaunchFixture: nil,
                passwordLifecycleClient: nil,
                signOut: { screen = "login" },
                rootNavigation: navigation
            )
        }
    }
    private func title(_ value: String) -> String {
        switch value { case "me": "我的"; case "chat": "聊天详情"; case "contacts": "联系人"; case "privacy": "消息接收设置"; case "login": "登录"; case "register": "注册"; default: "会话列表" }
    }
}

private struct V2MockProfileNamesKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}
extension EnvironmentValues {
    var v2MockProfileNames: [String: String] {
        get { self[V2MockProfileNamesKey.self] }
        set { self[V2MockProfileNamesKey.self] = newValue }
    }
}

private struct V2MockResourceBinding: V2InstallationBindingStore {
    let value: UUID
    func load() -> V2LocalInstallationBinding? { .init(value: value) }
    func save(_ binding: V2LocalInstallationBinding) throws {
        guard binding == .init(value: value) else { throw V2ResourceStorageError.conflict }
    }
    func delete() throws { throw V2ResourceStorageError.unavailable }
}

private actor V2MockPreviewSource: V2ConversationDataSource, V2ConversationMessageSearching, V2ContactsReading, V2PublicIdentityPresentationResolving,
    V2RelationshipChanging, V2UserBlockChanging, V2DirectConversationOpening, V2StrangerMessagePreferenceReading, V2StrangerMessagePreferenceUpdating, V2GroupRolePolicyAccessing, V2ConversationSending {
    let user = try! UserID("00000000-0000-0000-0000-000000000001")
    private var sentMessages: [String: [V2ConversationMessageItem]] = [:]
    static let room = "00000000-0000-0000-0000-000000000101"
    func conversationSummaryPage(for userID: String, isArchived: Bool, before cursor: V2ClientConversationListCursor?, limit: Int) async throws -> V2ConversationListPage {
        let names = ["产品设计讨论", "周末出行计划", "iOS 开发交流", "读书分享"]
        let previews = ["新的界面方案已经整理好了，大家看看～", "周六上午十点集合，可以吗？", "这个版本的动画流畅了很多 👍", "推荐大家看看这本书"]
        let items = names.indices.map { i in V2ConversationListItem(id: String(format: "00000000-0000-0000-0000-%012d", 101 + i), title: names[i], preview: previews[i], lastActivity: Date().addingTimeInterval(Double(-i * 1800)), isOutgoing: i == 2, kind: .group, isPinned: i == 0, unreadCount: i == 0 ? 3 : 0) }
        return .init(items: isArchived || cursor != nil ? [] : items, nextCursor: nil)
    }
    func timelinePage(in roomID: String, for userID: String, before cursor: V2ConversationTimelineCursor?, limit: Int) async throws -> V2ConversationTimelinePage {
        let texts = ["大家早上好！我们今天一起看一下新的界面。", "会话列表和联系人页面都已经完成了。", "收到，我觉得布局挺清楚的 👍", "晚点我再补充一下交互细节。", "好的，下午三点一起讨论～"]
        return .init(items: cursor == nil ? texts.indices.map { i in .message(.init(id: "mock-message-\(i)", roomSequence: UInt64(i + 1), revision: 1, text: texts[i], createdAt: Date().addingTimeInterval(Double(i - 5) * 120), isOutgoing: i == 2 || i == 4, isWithdrawn: false, reactions: i == 1 ? [.init(reaction: "👍", count: 3, includesCurrentUser: true)] : [], senderUserID: try! UserID("00000000-0000-0000-0000-000000000201")), timelineSequence: UInt64(i + 1)) } + (sentMessages[roomID] ?? []).enumerated().map { .message($0.element, timelineSequence: UInt64($0.offset + 6)) } : [], olderCursor: nil)
    }
    func timelineWindow(in roomID: String, for userID: String, around messageID: String, before: Int, after: Int) async throws -> V2ConversationTimelineLocation { .found(page: try await timelinePage(in: roomID, for: userID, before: nil, limit: 50), newerBoundary: nil) }
    func searchMessages(_ request: V2MessageSearchRequest) async throws -> V2MessageSearchPage {
        guard request.cursor == nil, request.contentFilter == .all else { return .init(hits: [], nextCursor: nil) }
        let room: RoomID = if case .room(let room) = request.scope { room } else { try .init(Self.room) }
        let page = try await timelinePage(in: room.rawValue, for: user.rawValue, before: nil, limit: 50)
        let hits = try page.items.compactMap { item -> V2MessageSearchHit? in
            guard case .message(let message, _) = item, message.text.contains(request.query),
                  request.senderUserID == nil || request.senderUserID == message.senderUserID else { return nil }
            return .init(messageID: try .init(message.id), roomID: room, roomSequence: message.roomSequence,
                senderUserID: message.senderUserID ?? user, text: message.text, createdAt: message.createdAt)
        }
        return .init(hits: Array(hits.prefix(request.limit)), nextCursor: nil)
    }

    func contactProjectionPage(scope: V2ContactProjectionPageScope, matching query: String?, before cursor: V2ClientRelationshipCursor?, limit: Int, includeTotalCount: Bool) async throws -> V2ContactProjectionPage {
        let names = scope == .friends ? ["小林", "陈晨", "阿青"] : scope == .incomingRequests ? ["李晓"] : ["周宁"]
        let items = try names.enumerated().map { i, name in
            let identity = try V2PublicIdentity(userID: .init(String(format: "00000000-0000-0000-0000-%012d", (scope == .friends ? 201 : scope == .incomingRequests ? 211 : 221) + i)), handle: .init("friend\(i + 1)"), displayName: name, accountKind: .regular)
            return V2ContactProjection(userID: identity.userID, state: scope == .friends ? .accepted : .pending, requestedByUserID: scope == .incomingRequests ? identity.userID : user, updatedAt: .now, publicIdentity: identity)
        }
        return .init(projections: cursor == nil ? items.filter { query == nil || query!.isEmpty || $0.publicIdentity!.displayName.contains(query!) } : [], nextCursor: nil, totalCount: items.count)
    }
    func hydrateRelationshipProfiles(for userIDs: [UserID]) async throws {}
    func resolveForPresentation(handle: String) async throws -> V2PublicIdentityLookupSnapshot { throw V2PublicIdentityValidationError.invalidHandle }
    func changeRelationship(targetUserID: String, action: V2RelationshipAction) async throws -> V2RelationshipChangeOutcome { .rejected(code: "mock-preview") }
    func changeBlock(targetUserID: String, action: V2UserBlockAction) async throws -> V2UserBlockChangeOutcome { .rejected(code: "mock-preview") }
    func openConversation(with publicIdentity: V2PublicIdentity) async throws -> String { Self.room }
    func strangerMessagePreference() async throws -> Bool? { true }
    func update(allowsStrangerMessages: Bool) async throws -> V2StrangerMessagePreferenceUpdateOutcome { .rejected(code: "mock-preview") }
    func groupRolePolicyState(in roomID: String) async throws -> V2ClientGroupRolePolicyState { .init(policies: [], recovery: .ready) }
    func retryGroupRolePolicyRecovery(in roomID: String) async throws -> V2ClientGroupRolePolicyState { .init(policies: [], recovery: .ready) }
    func receiveMessages() {
        for _ in 0..<12 {
            let sequence = UInt64((sentMessages[Self.room]?.count ?? 0) + 6)
            sentMessages[Self.room, default: []].append(.init(id: "incoming-\(sequence)", roomSequence: sequence,
                revision: 1, text: "实时接收测试消息 \(sequence)", createdAt: .now,
                isOutgoing: false, isWithdrawn: false, senderUserID: try! UserID("00000000-0000-0000-0000-000000000201")))
        }
    }

    func send(text: String, media: [V2MediaReference], in roomID: String) async throws -> V2ConversationSendOutcome {
        try await send(text: text, media: media, mentions: [], in: roomID)
    }
    func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], in roomID: String) async throws -> V2ConversationSendOutcome {
        try await send(text: text, media: media, mentions: mentions, entities: [], replyTo: nil, in: roomID)
    }
    func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], entities: [V2MessageEntity], replyTo: V2MessageReplyReference?, in roomID: String) async throws -> V2ConversationSendOutcome {
        guard media.isEmpty else { return .rejected(code: "mock-media-unavailable") }
        let sequence = UInt64((sentMessages[roomID]?.count ?? 0) + 6)
        sentMessages[roomID, default: []].append(.init(id: UUID().uuidString, roomSequence: sequence, revision: 1,
            text: text, mentions: mentions, entities: entities, replyTo: replyTo, createdAt: .now,
            isOutgoing: true, isWithdrawn: false, senderUserID: user))
        return .accepted
    }

}
#endif
