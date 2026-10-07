import IMV2ClientKit
import SwiftUI
import UIKit

struct V2RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var inheritedTypeSize
    @Environment(\.layoutDirection) private var inheritedDirection
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
        ZStack {
            Group {
                switch store.route {
                case .launching:
                    ProgressView("正在恢复 V2 会话…")
                case .signedOut:
                    signedOutContent
                case .authenticating:
                    ProgressView("正在验证身份…")
                case .localReadOnly:
                    if let presentation = store.offlinePresentation {
                        V2OfflineRootView(presentation: presentation,
                            retryOnline: { await store.retryOnlineFromLocalReadOnly() }, signOut: { await store.signOut() })
                    } else { ProgressView("正在打开本地内容…") }
                case .signedIn:
                    if let conversationStore = store.conversationStore,
                       let contactsStore = store.contactsStore,
                       let privacySettingsStore = store.privacySettingsStore {
                        V2SignedInRootView(
                            conversationStore: conversationStore,
                            contactsStore: contactsStore,
                            privacySettingsStore: privacySettingsStore,
                            userBlockSettingsStore: store.userBlockSettingsStore,
                            publicIdentitySettingsStore: store.publicIdentitySettingsStore,
                            pushWakeSettingsStore: store.pushWakeSettingsStore,
                            deviceSessionsStore: store.deviceSessionsStore,
                            groupInvitationStore: store.groupInvitationStore,
                            pendingGroupAvatarsStore: store.pendingGroupAvatarsStore,
                            localE2EConversationLaunchFixture: localE2EConversationLaunchFixture,
                            passwordLifecycleClient: store.passwordLifecycleClient(),
                            signOut: { await store.signOut() }
                        )
                        .environment(\.v2MediaThumbnailCache, store.mediaThumbnailCache)
                        .environment(\.v2AvatarPipeline, store.avatarPipeline)
                        .safeAreaInset(edge:.top) {
                            VStack(spacing: 0) {
                            if store.realtimeCoverage?.state == .recovering {
                                Text("实时通知正在恢复，可继续发送消息。")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .padding(.horizontal).padding(.vertical, 6)
                                    .accessibilityIdentifier("v2.realtime.recovering")
                            }
                            if store.accountWorkPaused {
                                HStack {
                                    Text("账户后台同步已暂停，已保存的操作会保留。")
                                    Button("重新连接") { Task { await store.resumeAccountWork() } }
                                        .disabled(store.isResumingAccountWork)
                                        .accessibilityIdentifier("v2.account-work.resume")
                                }
                                .padding().background(.regularMaterial)
                            }
                            }
                        }
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
            .safeAreaInset(edge: .bottom) {
                V2DeviceRevocationStatusView(state: revocationPresentation) {
                    #if DEBUG
                    if revocationVisualFixture != nil { revocationVisualFixture = .pending; return }
                    #endif
                    await store.retryDeviceRevocation()
                }
            }

            if scenePhase != .active {
                V2PrivacyShieldView()
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .environment(\.dynamicTypeSize, revocationTypeSize)
        .environment(\.layoutDirection, revocationDirection)
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
            pendingGroupInvitationURL = url
            openPendingGroupInvitationIfPossible()
        }
        .onChange(of: store.groupInvitationStore != nil) { _, isAvailable in
            guard isAvailable else { return }
            openPendingGroupInvitationIfPossible()
        }
    }

    @ViewBuilder private var signedOutContent: some View {
        #if DEBUG
        if let scope = mediaFileTestScope {
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

    private var revocationTypeSize: DynamicTypeSize {
        #if DEBUG
        if revocationVisualAccessibility { return .accessibility5 }
        #endif
        return inheritedTypeSize
    }

    private var revocationDirection: LayoutDirection {
        #if DEBUG
        if revocationVisualAccessibility { return .rightToLeft }
        #endif
        return inheritedDirection
    }

    private var revocationPresentation: V2DeviceRevocationPresentation {
        #if DEBUG
        if let revocationVisualFixture { return revocationVisualFixture }
        #endif
        return store.deviceRevocationPresentation
    }

    private func openPendingGroupInvitationIfPossible() {
        guard let url = pendingGroupInvitationURL,
              let invitations = store.groupInvitationStore
        else { return }
        pendingGroupInvitationURL = nil
        Task { await invitations.open(url.absoluteString) }
    }

    #if DEBUG
    private static func launchArgumentValue(_ arguments: [String], named name: String) -> String? {
        guard let argumentIndex = arguments.firstIndex(of: name) else { return nil }
        let valueIndex = arguments.index(after: argumentIndex)
        return valueIndex < arguments.endIndex ? arguments[valueIndex] : nil
    }
    #endif
}

/// 在 UIKit 记录应用切换器快照之前遮盖敏感会话像素。
///
/// 它刻意保持不透明且不做动画，使从活跃到非活跃的切换过程中不会暴露
/// 底层视图层级中的任何一帧内容。
private struct V2PrivacyShieldView: View {
    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
            .overlay {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .accessibilityIdentifier("v2.privacy-shield")
    }
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
        Form {
            if !dynamicTypeSize.isAccessibilitySize {
                Section {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .accessibilityHidden(true)
                }
                .listRowBackground(Color.clear)
            }
            Section {
                Picker("操作", selection: $mode) {
                    Text("登录").tag(V2AppStore.PasswordMode.signIn)
                    Text("注册").tag(V2AppStore.PasswordMode.register)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("v2.password.mode")
            }
            if let feedbackMessage {
                Section {
                    Text(feedbackMessage)
                        .font(.body)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("v2.authentication.message")
                }
            }
            Section("账号密码") {
                TextField("账号", text: $accountHandle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("v2.password.account-handle")
                SecureField("密码", text: $password)
                    .textContentType(mode == .register ? .newPassword : .password)
                .accessibilityIdentifier("v2.password.value")
                if mode == .register {
                    TextField("公开 ID", text: $publicHandle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityHint("例如 @alice")
                        .accessibilityIdentifier("v2.identity.public-handle")
                    TextField("显示名称", text: $displayName)
                        .accessibilityIdentifier("v2.identity.display-name")
                }
                Button(mode == .register ? "注册" : "使用密码登录") {
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
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("v2.password.submit")
            }

            Section {
                Button("找回账号与账号安全") { securityPresented = true }
                    .accessibilityIdentifier("v2.security.open")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mode == .register ? "注册" : "登录")
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
    private enum PresentedSettingsSheet: String, Identifiable {
        case accountSecurity
        case privacy
        case publicIdentity
        case deviceSessions
        case pendingGroupAvatars
        case favorites

        var id: String { rawValue }
    }

    let conversationStore: V2ConversationListStore
    let contactsStore: V2ContactsStore
    let privacySettingsStore: V2PrivacySettingsStore
    let userBlockSettingsStore: V2UserBlockSettingsStore?
    let publicIdentitySettingsStore: V2PublicIdentitySettingsStore?
    let pushWakeSettingsStore: V2PushWakeSettingsStore?
    let deviceSessionsStore: V2DeviceSessionsStore?
    let groupInvitationStore: V2GroupInvitationStore?
    let pendingGroupAvatarsStore: V2PendingGroupAvatarsStore?
    let localE2EConversationLaunchFixture: V2LiveLocalAccountE2EConversationLaunchFixture?
    let passwordLifecycleClient: V2PasswordLifecycleClient?
    let signOut: @MainActor @Sendable () async -> Void
    @State private var signOutTask: Task<Void, Never>?
    @State private var presentedSettingsSheet: PresentedSettingsSheet?
    @State var rootNavigation = V2RootNavigationStore()

    var body: some View {
        @Bindable var rootNavigation = rootNavigation
        TabView(selection: $rootNavigation.selectedTab) {
            V2ConversationListView(
                store: conversationStore,
                localE2EConversationLaunchFixture: localE2EConversationLaunchFixture,
                rootNavigation: rootNavigation,
                groupInvitationStore: groupInvitationStore
            )
            .tabItem { Label("消息", systemImage: "message") }
            .tag(V2RootNavigationStore.Tab.conversations)

            V2ContactsRootView(store: contactsStore, rootNavigation: rootNavigation)
                .tabItem { Label("联系人", systemImage: "person.2") }
                .badge(contactsStore.incomingRequestCount)
                .tag(V2RootNavigationStore.Tab.contacts)
            V2AccountHomeView(
                displayName: publicIdentitySettingsStore?.displayName ?? "我的资料",
                handle: publicIdentitySettingsStore?.handle ?? "",
                canOpenPublicIdentity: publicIdentitySettingsStore != nil,
                canOpenDevices: deviceSessionsStore != nil,
                canOpenSecurity: passwordLifecycleClient != nil,
                canOpenPendingAvatars: pendingGroupAvatarsStore != nil,
                openPublicIdentity: { presentedSettingsSheet = .publicIdentity },
                openDevices: { presentedSettingsSheet = .deviceSessions },
                openPrivacy: { presentedSettingsSheet = .privacy },
                openSecurity: { presentedSettingsSheet = .accountSecurity },
                openPendingAvatars: { presentedSettingsSheet = .pendingGroupAvatars },
                openFavorites: { presentedSettingsSheet = .favorites },
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
            .onDisappear { signOutTask?.cancel() }
            .sheet(item: $presentedSettingsSheet) { sheet in
                switch sheet {
                case .favorites:
                    V2FavoriteMessagesSheet(store: conversationStore) { item in
                        presentedSettingsSheet = nil
                        rootNavigation.showConversation(roomID: item.roomID, messageID: item.id)
                    }

                case .pendingGroupAvatars:
                    if let pendingGroupAvatarsStore { V2PendingGroupAvatarsView(store: pendingGroupAvatarsStore) }
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
                                ToolbarItem(placement: .cancellationAction) {
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
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("完成") { presentedSettingsSheet = nil }
                                            .accessibilityIdentifier("v2.identity.done")
                                    }
                                }
                        }
                    }
                case .deviceSessions:
                    if let deviceSessionsStore {
                        NavigationStack {
                            V2DeviceSessionsView(store: deviceSessionsStore)
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("完成") { presentedSettingsSheet = nil }
                                            .accessibilityIdentifier("v2.device-sessions.done")
                                    }
                                }
                        }
                    }
                }
            }
    }
}
