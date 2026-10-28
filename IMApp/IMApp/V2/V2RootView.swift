import IMV2Core
import IMV2ClientKit
import OSLog
import SwiftUI
import UIKit

struct V2RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    private let appPushDelegate: V2AppPushDelegate
    private let initialPasswordMode: V2AppStore.PasswordMode
    private let initialLocalE2ETestAccountHandle: String?
    private let initialLocalE2ETestPassword: String?
    private let initialLocalE2ETestPublicHandle: String?
    private let initialLocalE2ETestDisplayName: String?
    private let localE2EConversationLaunchFixture: V2LiveLocalAccountE2EConversationLaunchFixture?
    @State private var store: V2AppStore
    @State private var protectedDataRetryTask: Task<Void, Never>?
    @State private var pendingGroupInvitationURL: URL?
    #if DEBUG
    private let revocationVisualAccessibility: Bool
    private let groupAvatarRecoveryTestScope: UUID?
    private let mediaFileTestScope: UUID?
    private let resourceCenterTestScope: UUID?
    @State private var revocationVisualFixture: V2DeviceRevocationPresentation?
    #endif

    init(appPushDelegate: V2AppPushDelegate) {
        self.appPushDelegate = appPushDelegate
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let startupMode = appPushDelegate.store.startupMode
        groupAvatarRecoveryTestScope = startupMode == .uiTestingSignedOut
            ? Self.launchArgumentValue(arguments, named: "-v2-ui-testing-resource-scope").flatMap(UUID.init(uuidString:)) : nil
        mediaFileTestScope = startupMode == .uiTestingSignedOut
            ? Self.launchArgumentValue(arguments, named: "-v2-ui-testing-media-scope").flatMap(UUID.init(uuidString:)) : nil
        resourceCenterTestScope = startupMode == .uiTestingSignedOut
            ? Self.launchArgumentValue(arguments, named: "-v2-ui-testing-resource-center-scope").flatMap(UUID.init(uuidString:)) : nil
        revocationVisualAccessibility = startupMode == .uiTestingSignedOut && arguments.contains("-v2-ui-testing-revocation-accessibility")
        _revocationVisualFixture = State(initialValue: startupMode == .uiTestingSignedOut && arguments.contains("-v2-ui-testing-revocation-paused") ? .paused : nil)
        initialPasswordMode = arguments.contains("-v2-ui-testing-password-register") ? .register : .signIn
        initialLocalE2ETestAccountHandle = startupMode == .uiTestingLiveLocalAccount
            ? Self.launchArgumentValue(arguments, named: "-v2-ui-testing-account-handle")
            : nil
        initialLocalE2ETestPassword = startupMode == .uiTestingLiveLocalAccount
            ? Self.launchArgumentValue(arguments, named: "-v2-ui-testing-local-password")
            : nil
        initialLocalE2ETestPublicHandle = startupMode == .uiTestingLiveLocalAccount
            ? Self.launchArgumentValue(arguments, named: "-v2-ui-testing-public-handle")
            : nil
        initialLocalE2ETestDisplayName = startupMode == .uiTestingLiveLocalAccount
            ? Self.launchArgumentValue(arguments, named: "-v2-ui-testing-display-name")
            : nil
        localE2EConversationLaunchFixture = startupMode.usesLiveLocalAccountE2ETestScope
            ? .init(
                directTargetHandle: Self.launchArgumentValue(arguments, named: "-v2-ui-testing-direct-target"),
                initialMessage: Self.launchArgumentValue(arguments, named: "-v2-ui-testing-message"),
                initialMentionHandles: Self.launchArgumentValue(arguments, named: "-v2-ui-testing-message-mentions"),
                initialGroupTitle: Self.launchArgumentValue(arguments, named: "-v2-ui-testing-group-title"),
                initialGroupMemberHandles: Self.launchArgumentValue(arguments, named: "-v2-ui-testing-group-members")
            )
            : nil
        #else
        initialPasswordMode = .signIn
        initialLocalE2ETestAccountHandle = nil
        initialLocalE2ETestPassword = nil
        initialLocalE2ETestPublicHandle = nil
        initialLocalE2ETestDisplayName = nil
        localE2EConversationLaunchFixture = nil
        #endif
        _store = State(initialValue: appPushDelegate.store)
    }

    var body: some View {
        #if DEBUG
        if revocationVisualAccessibility {
            rootContent
                .environment(\.dynamicTypeSize, .accessibility5)
                .environment(\.layoutDirection, .rightToLeft)
        } else {
            rootContent
        }
        #else
        rootContent
        #endif
    }

    @ViewBuilder private var rootContent: some View {
        ZStack {
            Group {
                switch store.route {
                case .launching:
                    // Keep the native launch background until local account data
                    // is ready; authentication recovery never becomes a page.
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                        .accessibilityIdentifier("v2.launch.local-bootstrap")
                case .signedOut:
                    signedOutContent
                        .safeAreaInset(edge: .bottom) {
                            V2DeviceRevocationStatusView(state: revocationPresentation) {
                                #if DEBUG
                                if revocationVisualFixture != nil { revocationVisualFixture = .pending; return }
                                #endif
                                await store.retryDeviceRevocation()
                            }
                        }
                case .authenticating:
                    ProgressView("正在验证身份…")
                case .localReadOnly:
                    if store.offlineStartupPresentation == .restoringSession {
                        ProgressView("正在恢复 V2 会话…")
                    } else if let presentation = store.offlinePresentation {
                        V2OfflineRootView(presentation: presentation,
                            retryOnline: { await store.retryOnlineFromLocalReadOnly() }, signOut: { store.requestSignOut() })
                    } else { ProgressView("正在打开本地内容…") }
                case .signedIn:
                    if let conversationStore = store.conversationStore,
                       let contactsStore = store.contactsStore,
                       let privacySettingsStore = store.privacySettingsStore {
                        V2SignedInRootView(
                            appStore: store,
                            conversationStore: conversationStore,
                            contactsStore: contactsStore,
                            privacySettingsStore: privacySettingsStore,
                            userBlockSettingsStore: store.userBlockSettingsStore,
                            publicIdentitySettingsStore: store.publicIdentitySettingsStore,
                            pushWakeSettingsStore: store.pushWakeSettingsStore,
                            deviceSessionsStore: store.deviceSessionsStore,
                            groupInvitationStore: store.groupInvitationStore,
                            pendingGroupInvitationURL: $pendingGroupInvitationURL,
                            makeGroupAvatarManagement: store.makeGroupAvatarManagement,
                            localE2EConversationLaunchFixture: localE2EConversationLaunchFixture,
                            passwordLifecycleClient: store.passwordLifecycleClient(),
                            signOut: { store.requestSignOut() }
                        )
                        .environment(\.v2ResourceManagement, store.resourceManagement)
                        .environment(\.v2MediaThumbnailCache, store.mediaThumbnailCache)
                        .environment(\.v2AvatarPipeline, store.avatarPipeline)
                    } else {
                        ProgressView("正在打开本地会话…")
                    }
                case .uiTestingLiveLocalAccountCleanupCompleted:
                    Text("本地 E2E 测试数据已清理")
                        .accessibilityIdentifier("v2.local-e2e.cleanup.completed")
                case .protectedDataUnavailable:
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "受保护凭据暂不可用",
                            systemImage: "lock.trianglebadge.exclamationmark",
                            description: Text("请解锁设备后重试。")
                        )
                        Button("重试") {
                            protectedDataRetryTask?.cancel()
                            protectedDataRetryTask = Task { await store.retryProtectedDataAccess() }
                        }
                        .accessibilityIdentifier("v2.protected-data.retry")
                    }
                case .signOutPendingCredentialDeletion:
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "正在完成退出登录",
                            systemImage: "lock.trianglebadge.exclamationmark",
                            description: Text("请解锁设备后重试，以保存退出任务并删除本机登录凭据。")
                        )
                        Button("重试") {
                            protectedDataRetryTask?.cancel()
                            protectedDataRetryTask = Task { await store.retryPendingCredentialDeletion() }
                        }
                        .accessibilityIdentifier("v2.sign-out.pending.retry")
                    }
                case .unavailable(let message):
                    ContentUnavailableView("V2 暂不可用", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onDisappear { protectedDataRetryTask?.cancel() }
        .task { await store.restore() }
        .task(id: scenePhase) {
            switch scenePhase {
            case .active:
                await store.applicationDidBecomeActive()
            case .background:
                await store.applicationDidEnterBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "iim", url.host == "group-invite" else { return }
            Logger(subsystem: "com.stskcxfz.imapp", category: "GroupInvitationRouting")
                .info("Invitation URL received; scene active: \(scenePhase == .active, privacy: .public)")
            pendingGroupInvitationURL = url
        }
    }

    @ViewBuilder private var signedOutContent: some View {
        #if DEBUG
        if let scope = resourceCenterTestScope {
            V2ResourceCenterUITestView(scope: scope,
                cleanup: ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-cleanup"))
        } else if let scope = mediaFileTestScope {
            V2MediaFileUsageUITestView(scope: scope,
                cleanup: ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-media-cleanup"))
        } else if let scope = groupAvatarRecoveryTestScope {
            V2GroupAvatarRecoveryUITestView(scope: scope,
                cleanup: ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-cleanup"))
        } else { signInContent }
        #else
        signInContent
        #endif
    }

    private var signInContent: some View {
        NavigationStack {
            V2SignInView(store: store, authenticationMessage: store.authenticationMessage,
                initialPasswordMode: initialPasswordMode, initialAccountHandle: initialLocalE2ETestAccountHandle,
                initialPassword: initialLocalE2ETestPassword, initialPublicHandle: initialLocalE2ETestPublicHandle,
                initialDisplayName: initialLocalE2ETestDisplayName)
        }
    }

    private var revocationPresentation: V2DeviceRevocationPresentation {
        #if DEBUG
        if let revocationVisualFixture { return revocationVisualFixture }
        #endif
        return store.deviceRevocationPresentation
    }

    #if DEBUG
    private static func launchArgumentValue(_ arguments: [String], named name: String) -> String? {
        guard let argumentIndex = arguments.firstIndex(of: name) else { return nil }
        let valueIndex = arguments.index(after: argumentIndex)
        return valueIndex < arguments.endIndex ? arguments[valueIndex] : nil
    }
    #endif
}

struct V2SignInView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var store: V2AppStore
    let authenticationMessage: String?
    @State private var accountHandle = ""
    @State private var password = ""
    @State private var publicHandle = ""
    @State private var displayName = ""
    @State private var mode: V2AppStore.PasswordMode = .signIn
    @State private var inputValidationMessage: String?
    @State private var actionTask: Task<Void, Never>?
    @State private var securityPresented = false

    init(
        store: V2AppStore,
        authenticationMessage: String?,
        initialPasswordMode: V2AppStore.PasswordMode = .signIn,
        initialAccountHandle: String? = nil,
        initialPassword: String? = nil,
        initialPublicHandle: String? = nil,
        initialDisplayName: String? = nil
    ) {
        self.store = store
        self.authenticationMessage = authenticationMessage
        _mode = State(initialValue: initialPasswordMode)
        _accountHandle = State(initialValue: initialAccountHandle ?? "")
        _password = State(initialValue: initialPassword ?? "")
        _publicHandle = State(initialValue: initialPublicHandle ?? "")
        _displayName = State(initialValue: initialDisplayName ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 12 : 24) {
                if !dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(V2VisualStyle.accent)
                            .frame(width: 72, height: 72)
                            .background(V2VisualStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 24))
                            .accessibilityHidden(true)
                        Text(mode == .register ? "开启新的交流" : "欢迎回来")
                            .font(.largeTitle.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        Text(mode == .register ? "创建账号，与朋友保持联系。" : "让每一次交流，更近一点。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 24).padding(.bottom, 8)
                }
                VStack {
                    Picker("操作", selection: $mode) {
                        Text("登录").tag(V2AppStore.PasswordMode.signIn)
                        Text("注册").tag(V2AppStore.PasswordMode.register)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("v2.password.mode")
                }
                if let feedbackMessage {
                    VStack {
                        Text(feedbackMessage)
                            .font(.body)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("v2.authentication.message")
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("账号信息").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("账号", text: $accountHandle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("v2.password.account-handle")
                        .v2InputSurface()
                    SecureField("密码", text: $password)
                        .textContentType(mode == .register ? .newPassword : .password)
                        .accessibilityIdentifier("v2.password.value")
                        .v2InputSurface()
                    if mode == .register {
                        TextField("公开 ID", text: $publicHandle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityHint("例如 @alice")
                            .accessibilityIdentifier("v2.identity.public-handle")
                            .v2InputSurface()
                        TextField("显示名称", text: $displayName)
                            .accessibilityIdentifier("v2.identity.display-name")
                            .v2InputSurface()
                    }
                    Button(mode == .register ? "注册" : "登录") {
                        guard canSubmitPasswordAction else {
                            inputValidationMessage = validationMessage
                            return
                        }

                        inputValidationMessage = nil
                        let submittedPassword = password
                        password = ""
                        run {
                            await store.authenticatePassword(
                                accountHandle: accountHandle,
                                password: submittedPassword,
                                mode: mode,
                                publicHandle: publicHandle,
                                displayName: displayName
                            )
                        }
                    }
                    .buttonStyle(V2PrimaryButtonStyle())
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("v2.password.submit")
                }

                VStack {
                    Button { securityPresented = true } label: {
                        Text("找回账号与账号安全")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("v2.security.open")
                }
            }.padding(dynamicTypeSize.isAccessibilitySize ? 16 : 24).frame(maxWidth: 480).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .v2PageSurface()
        .navigationTitle(mode == .register ? "注册" : "登录")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $securityPresented) {
            if let client = store.passwordLifecycleClient() {
                NavigationStack { V2AccountSecurityView(client: client, initialAction: .recover) }
            }
        }
        .onAppear {
            if let feedbackMessage {
                announceV2AccessibilityAnnouncement(feedbackMessage)
            }
        }
        .onChange(of: feedbackMessage) { _, updatedMessage in
            if let updatedMessage {
                announceV2AccessibilityAnnouncement(updatedMessage)
            }
        }
        // Submitting switches the root route to `.authenticating`, which
        // removes this view immediately. Cancelling here would therefore abort
        // the very account request the user just started. A replacement submit
        // still cancels the prior task in `run(_:)`.
    }

    private var canSubmitPasswordAction: Bool {
        !accountHandle.isEmpty
            && !password.isEmpty
            && (mode == .signIn || (!publicHandle.isEmpty && !displayName.isEmpty))
    }

    private var validationMessage: String {
        mode == .register
            ? "请输入账号、密码、公开 ID 和显示名称。"
            : "请输入账号和密码。"
    }

    private var feedbackMessage: String? {
        authenticationMessage ?? inputValidationMessage
    }

    private func run(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        actionTask?.cancel()
        actionTask = Task { await operation() }
    }
}

struct V2SignedInRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    private struct InvitationPresentationKey: Equatable {
        let url: URL?
        let isActive: Bool
    }
    private enum PresentedSettingsSheet: String, Identifiable {
        case accountSecurity
        case privacy
        case publicIdentity
        case deviceSessions
        case favorites

        var id: String { rawValue }
    }

    let appStore: V2AppStore
    let conversationStore: V2ConversationListStore
    let contactsStore: V2ContactsStore
    let privacySettingsStore: V2PrivacySettingsStore
    let userBlockSettingsStore: V2UserBlockSettingsStore?
    let publicIdentitySettingsStore: V2PublicIdentitySettingsStore?
    let pushWakeSettingsStore: V2PushWakeSettingsStore?
    let deviceSessionsStore: V2DeviceSessionsStore?
    let groupInvitationStore: V2GroupInvitationStore?
    @Binding var pendingGroupInvitationURL: URL?
    let makeGroupAvatarManagement: (@MainActor @Sendable (RoomID, GroupAvatarOperationID) -> V2GroupAvatarManagementStore)?
    let localE2EConversationLaunchFixture: V2LiveLocalAccountE2EConversationLaunchFixture?
    let passwordLifecycleClient: V2PasswordLifecycleClient?
    let signOut: @MainActor @Sendable () async -> Void
    @State private var signOutTask: Task<Void, Never>?
    @State private var presentedSettingsSheet: PresentedSettingsSheet?
    @State private var conversationAfterSettingsDismissal: V2ConversationRoute?
    @State var rootNavigation = V2RootNavigationStore()
    @State private var signedInProfilePageID = UUID()

    var body: some View {
        @Bindable var rootNavigation = rootNavigation
        NavigationStack(path: $rootNavigation.path) {
        TabView(selection: $rootNavigation.selectedTab) {
            V2ConversationListView(
                store: conversationStore,
                localE2EConversationLaunchFixture: localE2EConversationLaunchFixture,
                rootNavigation: rootNavigation
            )
            .environment(\.v2UserInteractionContext, .init(contacts: contactsStore, conversations: conversationStore, navigation: rootNavigation))
            .tabItem { Label("消息", systemImage: "message") }
            .tag(V2RootNavigationStore.Tab.conversations)

            V2ContactsRootView(store: contactsStore, rootNavigation: rootNavigation)
                .environment(\.v2UserInteractionContext, .init(contacts: contactsStore, conversations: conversationStore, navigation: rootNavigation))
                .tabItem { Label("联系人", systemImage: "person.2") }
                .badge(contactsStore.incomingRequestCount)
                .tag(V2RootNavigationStore.Tab.contacts)
            V2AccountHomeView(
                displayName: publicIdentitySettingsStore?.displayName ?? "我的资料",
                handle: publicIdentitySettingsStore?.handle ?? "",
                avatarKey: publicIdentitySettingsStore?.profileUserID.map { .init(userID: $0, context: .relationship) },
                avatar: publicIdentitySettingsStore?.currentAvatar,
                canOpenPublicIdentity: publicIdentitySettingsStore != nil,
                canOpenDevices: deviceSessionsStore != nil,
                canOpenSecurity: passwordLifecycleClient != nil,
                openPublicIdentity: { presentedSettingsSheet = .publicIdentity },
                openDevices: { presentedSettingsSheet = .deviceSessions },
                openPrivacy: { presentedSettingsSheet = .privacy },
                openSecurity: { presentedSettingsSheet = .accountSecurity },
                openFavorites: { presentedSettingsSheet = .favorites },
                openResources: appStore.resourceManagement == nil ? nil : { rootNavigation.path.append(V2ResourceRoute.home) },
                signOut: {
                    guard signOutTask == nil else { return }
                    signOutTask = Task {
                        await signOut()
                        guard !Task.isCancelled else { return }
                        signOutTask = nil
                    }
                }
            )
            .task { await publicIdentitySettingsStore?.load() }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }
            .tag(V2RootNavigationStore.Tab.account)

        }
            .navigationTitle(rootNavigation.selectedTab == .conversations ? (conversationStore.isShowingArchived ? "已归档" : "消息") : rootNavigation.selectedTab == .contacts ? "联系人" : "我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if rootNavigation.selectedTab == .conversations {
                    ToolbarItem(placement: .principal) {
                        V2ConnectionStatusButton(store: appStore, navigationTitle:
                            conversationStore.isShowingArchived ? "已归档" : "消息")
                    }
                }
                if rootNavigation.selectedTab == .conversations {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                    Section("发起聊天") {
                    Button("新建群聊", systemImage: "person.2") {
                        rootNavigation.conversationAction = .newGroup
                    }
                    .accessibilityIdentifier("v2.conversation.new-group")
                    if let groupInvitationStore {
                        Button("加入群聊", systemImage: "qrcode.viewfinder") {
                            groupInvitationStore.isPresentingJoin = true
                        }
                        .accessibilityIdentifier("v2.group-join.open")
                    }
                    }
                    Section("查找内容") {
                        Button(conversationStore.isShowingArchived ? "返回收件箱" : "已归档", systemImage: conversationStore.isShowingArchived ? "tray" : "archivebox") {
                            Task { await conversationStore.toggleArchivedConversations() }
                        }
                        .accessibilityIdentifier("v2.conversation.archive-toggle")
                        Button("搜索消息", systemImage: "magnifyingglass") {
                            rootNavigation.conversationAction = .search
                        }
                        .accessibilityIdentifier("v2.message.search")
                        Button("收藏", systemImage: "star") {
                            rootNavigation.conversationAction = .favorites
                        }
                        .accessibilityIdentifier("v2.message.favorites")
                    }
                    Section("同步") {
                        Button("刷新", systemImage: "arrow.clockwise") { Task { await conversationStore.refresh() } }
                            .accessibilityIdentifier("v2.conversation.refresh")
                        if conversationStore.preferenceActivity != nil {
                            Button("待同步设置", systemImage: "arrow.triangle.2.circlepath") { rootNavigation.conversationAction = .preferences }
                        }
                    }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("会话工具")
                    .accessibilityHint("打开归档、搜索和收藏")
                    .accessibilityIdentifier("v2.conversation.tools")
                    Button("新建私聊", systemImage: "square.and.pencil") {
                        rootNavigation.conversationAction = .newDirect
                    }
                    .accessibilityIdentifier("v2.conversation.new-direct")

                }
                } else if rootNavigation.selectedTab == .contacts {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: V2ContactsRoute.addFriend) {
                            Label("添加好友", systemImage: "person.badge.plus")
                        }.accessibilityIdentifier("v2.contacts.add")
                    }
                }
            }
            .navigationDestination(for: V2ConversationRoute.self) { route in
                V2ConversationDetailView(
                    store: conversationStore.detailStore(for: route.roomID,
                        initialDraft: rootNavigation.fixtureRoomID == route.roomID ? localE2EConversationLaunchFixture?.initialMessage : nil,
                        initialMentionHandles: rootNavigation.fixtureRoomID == route.roomID ? localE2EConversationLaunchFixture?.initialMentionHandles : nil),
                    initiallyFocusedMessageID: route.messageID,
                    groupInvitationStore: groupInvitationStore)
            }
            .v2ResourceDestinations(service: appStore.resourceManagement, navigation: rootNavigation,
                profile: publicIdentitySettingsStore, groups: makeGroupAvatarManagement)
            .navigationDestination(for: V2LocalDirectConversationRoute.self) { route in
                if let service = conversationStore.localDirectConversationService {
                    V2LocalDirectConversationView(operationID: route.operationID,
                        service: service, conversations: conversationStore,
                        groupInvitations: groupInvitationStore)
                }
            }
            .navigationDestination(for: V2ContactsRoute.self) { route in
                switch route {
                case .groups:
                    V2GroupDirectoryView(store: conversationStore.makeGroupDirectoryStore(), conversations: conversationStore,
                        navigation: rootNavigation, invitations: groupInvitationStore)
                case .requests: V2FriendRequestsView(store: contactsStore)
                case .addFriend: V2AddFriendView(store: contactsStore)
                case .contact(let userID):
                    if let user = try? UserID(userID) {
                        V2UserProfileSheet(key: .init(userID: user, context: .relationship), usesNavigationStack: false)
                    }
                }
            }
            .task(id: InvitationPresentationKey(url: pendingGroupInvitationURL, isActive: scenePhase == .active)) {
                guard scenePhase == .active,
                      let url = pendingGroupInvitationURL, let invitations = groupInvitationStore else { return }
                // The signed-in presentation owns this work. Cold-start URLs
                // remain pending until its shared invitation sheet host is mounted.
                rootNavigation.selectedTab = .conversations
                Logger(subsystem: "com.stskcxfz.imapp", category: "GroupInvitationRouting")
                    .info("Opening pending invitation on active signed-in presentation")
                await invitations.open(url.absoluteString)
                Logger(subsystem: "com.stskcxfz.imapp", category: "GroupInvitationRouting")
                    .info("Invitation preview returned; cancelled: \(Task.isCancelled, privacy: .public), presenting: \(invitations.isPresentingJoin, privacy: .public)")
                guard !Task.isCancelled, pendingGroupInvitationURL == url else { return }
                pendingGroupInvitationURL = nil
            }
            .environment(\.v2ResourceNavigation, rootNavigation)
            .onDisappear { signOutTask?.cancel() }
            .sheet(item: $presentedSettingsSheet, onDismiss: {
                guard let route = conversationAfterSettingsDismissal else { return }
                conversationAfterSettingsDismissal = nil
                rootNavigation.showConversation(roomID: route.roomID, messageID: route.messageID)
            }) { sheet in
                switch sheet {
                case .favorites:
                    V2FavoriteMessagesSheet(store: conversationStore) { item in
                        conversationAfterSettingsDismissal = .init(roomID: item.roomID, messageID: item.id)
                        presentedSettingsSheet = nil
                    }

                case .accountSecurity:
                    if let passwordLifecycleClient {
                        NavigationStack { V2AccountSecurityView(client: passwordLifecycleClient, passwordChanged: signOut) }
                    }
                case .privacy:
                    NavigationStack {
                        V2PrivacySettingsView(
                            store: privacySettingsStore,
                            pushWakeSettingsStore: pushWakeSettingsStore,
                            userBlockSettingsStore: userBlockSettingsStore
                        )
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("完成") { presentedSettingsSheet = nil }
                                        .accessibilityIdentifier("v2.privacy.done")
                                }
                            }
                    }
                case .publicIdentity:
                    if let publicIdentitySettingsStore {
                        NavigationStack {
                            V2PublicIdentitySettingsView(store: publicIdentitySettingsStore)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("完成") { presentedSettingsSheet = nil }
                                            .accessibilityIdentifier("v2.identity.done")
                                    }
                                }
                        }
                    }
                case .deviceSessions:
                    if let deviceSessionsStore {
                        NavigationStack {
                            V2DeviceSessionsView(
                                store: deviceSessionsStore,
                                exitConfirmation: appStore.deviceRevocationPresentation,
                                retryExitConfirmation: { await appStore.retryDeviceRevocation() }
                            )
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("完成") { presentedSettingsSheet = nil }
                                            .accessibilityIdentifier("v2.device-sessions.done")
                                    }
                                }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { groupInvitationStore?.isPresentingJoin == true },
            set: { if !$0 { groupInvitationStore?.dismissJoin() } }
        )) {
            if let groupInvitationStore { V2GroupJoinSheet(store: groupInvitationStore) }
        }
        .task { await conversationStore.observeGroupCreation() }
        .authorPresentationPage(context: .list(signedInProfilePageID))
        .environment(\.v2ResourceNavigation, rootNavigation)
        .environment(\.v2ResourceManagement, appStore.resourceManagement)
        .environment(\.v2UserInteractionContext, .init(contacts: contactsStore, conversations: conversationStore, navigation: rootNavigation))
    }
}
