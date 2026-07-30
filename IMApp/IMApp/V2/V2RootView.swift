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

    init(appPushDelegate: V2AppPushDelegate) {
        self.appPushDelegate = appPushDelegate
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let startupMode: V2AppStore.StartupMode
        if arguments.contains("-v2-ui-testing-live-local-account") {
            startupMode = arguments.contains("-v2-ui-testing-cleanup-local-account")
                ? .uiTestingLiveLocalAccountCleanup
                : arguments.contains("-v2-ui-testing-restore-local-account")
                    ? .uiTestingLiveLocalAccountRestore
                    : .uiTestingLiveLocalAccount
        } else if arguments.contains("-v2-ui-testing-signed-out") {
            startupMode = .uiTestingSignedOut
        } else {
            startupMode = .production
        }
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
        let liveLocalAccountE2ETestScope = startupMode.usesLiveLocalAccountE2ETestScope
            ? Self.launchArgumentValue(arguments, named: "-v2-ui-testing-e2e-scope").flatMap(V2LiveLocalAccountE2ETestScope.init(rawValue:))
            : nil
        let debugForcesUnavailableRealtimeForLiveLocalAccountE2E = startupMode.usesLiveLocalAccountE2ETestScope
            && arguments.contains("-v2-ui-testing-unavailable-realtime")
        #else
        let startupMode: V2AppStore.StartupMode = .production
        initialPasswordMode = .signIn
        initialLocalE2ETestAccountHandle = nil
        initialLocalE2ETestPassword = nil
        initialLocalE2ETestPublicHandle = nil
        initialLocalE2ETestDisplayName = nil
        localE2EConversationLaunchFixture = nil
        let liveLocalAccountE2ETestScope: V2LiveLocalAccountE2ETestScope? = nil
        let debugForcesUnavailableRealtimeForLiveLocalAccountE2E = false
        #endif
        _store = State(initialValue: V2AppStore(
            startupMode: startupMode,
            liveLocalAccountE2ETestScope: liveLocalAccountE2ETestScope,
            debugForcesUnavailableRealtimeForLiveLocalAccountE2E: debugForcesUnavailableRealtimeForLiveLocalAccountE2E,
            remoteNotificationRegistrar: appPushDelegate
        ))
    }

    var body: some View {
        Group {
            switch store.route {
            case .launching:
                ProgressView("正在恢复 V2 会话…")
            case .signedOut:
                V2SignInView(
                    store: store,
                    authenticationMessage: store.authenticationMessage,
                    initialPasswordMode: initialPasswordMode,
                    initialAccountHandle: initialLocalE2ETestAccountHandle,
                    initialPassword: initialLocalE2ETestPassword,
                    initialPublicHandle: initialLocalE2ETestPublicHandle,
                    initialDisplayName: initialLocalE2ETestDisplayName
                )
            case .authenticating:
                ProgressView("正在验证身份…")
            case .signedIn:
                if let conversationStore = store.conversationStore,
                   let privacySettingsStore = store.privacySettingsStore {
                   V2SignedInRootView(
                        conversationStore: conversationStore,
                        privacySettingsStore: privacySettingsStore,
                        userBlockSettingsStore: store.userBlockSettingsStore,
                        publicIdentitySettingsStore: store.publicIdentitySettingsStore,
                        pushWakeSettingsStore: store.pushWakeSettingsStore,
                        localE2EConversationLaunchFixture: localE2EConversationLaunchFixture,
                        signOut: { await store.signOut() }
                    )
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
                        description: Text("请联网并解锁设备后重试，以移除后台唤醒端点并删除受保护凭据。")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            appPushDelegate.tokenReceiver = store
            appPushDelegate.wakeHandler = store
        }
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
    }

    #if DEBUG
    private static func launchArgumentValue(_ arguments: [String], named name: String) -> String? {
        guard let argumentIndex = arguments.firstIndex(of: name) else { return nil }
        let valueIndex = arguments.index(after: argumentIndex)
        return valueIndex < arguments.endIndex ? arguments[valueIndex] : nil
    }
    #endif
}

private struct V2SignInView: View {
    @Bindable var store: V2AppStore
    let authenticationMessage: String?
    @State private var accountHandle = ""
    @State private var password = ""
    @State private var publicHandle = ""
    @State private var displayName = ""
    @State private var mode: V2AppStore.PasswordMode = .signIn
    @State private var inputValidationMessage: String?
    @State private var actionTask: Task<Void, Never>?

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
            Section {
                Button {
                    run { await store.signInWithPasskey() }
                } label: {
                    Image(systemName: "key.fill")
                }
                .accessibilityLabel("使用 Passkey 登录")
                .accessibilityIdentifier("v2.passkey.sign-in")
            } footer: {
                Text("Passkey 是推荐方式；系统会使用 Face ID、Touch ID 或设备密码。")
            }

            Section("密码兜底") {
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
                Picker("操作", selection: $mode) {
                    Text("登录").tag(V2AppStore.PasswordMode.signIn)
                    Text("注册").tag(V2AppStore.PasswordMode.register)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("v2.password.mode")
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
                .accessibilityIdentifier("v2.password.submit")
            }

            if let feedbackMessage {
                Section {
                    Text(feedbackMessage)
                        .font(.body)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("v2.authentication.message")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("登录")
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

private struct V2SignedInRootView: View {
    private enum PresentedSettingsSheet: String, Identifiable {
        case privacy
        case publicIdentity

        var id: String { rawValue }
    }

    let conversationStore: V2ConversationListStore
    let privacySettingsStore: V2PrivacySettingsStore
    let userBlockSettingsStore: V2UserBlockSettingsStore?
    let publicIdentitySettingsStore: V2PublicIdentitySettingsStore?
    let pushWakeSettingsStore: V2PushWakeSettingsStore?
    let localE2EConversationLaunchFixture: V2LiveLocalAccountE2EConversationLaunchFixture?
    let signOut: @MainActor @Sendable () async -> Void
    @State private var signOutTask: Task<Void, Never>?
    @State private var presentedSettingsSheet: PresentedSettingsSheet?

    var body: some View {
        V2ConversationListView(
            store: conversationStore,
            localE2EConversationLaunchFixture: localE2EConversationLaunchFixture,
            accountMenu: V2ConversationAccountMenu(
                canOpenPublicIdentity: publicIdentitySettingsStore != nil,
                openPublicIdentity: { presentedSettingsSheet = .publicIdentity },
                openPrivacySettings: { presentedSettingsSheet = .privacy },
                signOut: {
                    guard signOutTask == nil else { return }
                    signOutTask = Task {
                        await signOut()
                        guard !Task.isCancelled else { return }
                        signOutTask = nil
                    }
                }
            )
        )
            .onDisappear { signOutTask?.cancel() }
            .sheet(item: $presentedSettingsSheet) { sheet in
                switch sheet {
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
                }
            }
    }
}
