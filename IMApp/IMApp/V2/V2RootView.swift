import SwiftUI

struct V2RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    private let appPushDelegate: V2AppPushDelegate
    private let initialPasswordMode: V2AppStore.PasswordMode
    private let initialLocalE2ETestAccountHandle: String?
    private let initialLocalE2ETestPassword: String?
    private let initialLocalE2ETestPublicHandle: String?
    private let initialLocalE2ETestDisplayName: String?
    @State private var store: V2AppStore

    init(appPushDelegate: V2AppPushDelegate) {
        self.appPushDelegate = appPushDelegate
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let startupMode: V2AppStore.StartupMode
        if arguments.contains("-v2-ui-testing-live-local-account") {
            startupMode = arguments.contains("-v2-ui-testing-cleanup-local-account")
                ? .uiTestingLiveLocalAccountCleanup
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
        let liveLocalAccountE2ETestScope = startupMode.usesLiveLocalAccountE2ETestScope
            ? Self.launchArgumentValue(arguments, named: "-v2-ui-testing-e2e-scope").flatMap(V2LiveLocalAccountE2ETestScope.init(rawValue:))
            : nil
        #else
        let startupMode: V2AppStore.StartupMode = .production
        initialPasswordMode = .signIn
        initialLocalE2ETestAccountHandle = nil
        initialLocalE2ETestPassword = nil
        initialLocalE2ETestPublicHandle = nil
        initialLocalE2ETestDisplayName = nil
        let liveLocalAccountE2ETestScope: V2LiveLocalAccountE2ETestScope? = nil
        #endif
        _store = State(initialValue: V2AppStore(
            startupMode: startupMode,
            liveLocalAccountE2ETestScope: liveLocalAccountE2ETestScope,
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
                        publicIdentitySettingsStore: store.publicIdentitySettingsStore,
                        pushWakeSettingsStore: store.pushWakeSettingsStore,
                        signOut: { await store.signOut() }
                    )
                } else {
                    ProgressView("正在打开本地会话…")
                }
            case .uiTestingLiveLocalAccountCleanupCompleted:
                Text("本地 E2E 测试数据已清理")
                    .accessibilityIdentifier("v2.local-e2e.cleanup.completed")
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
                    Label("使用 Passkey 登录", systemImage: "key.fill")
                }
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
                    TextField("公开 ID（例如 @alice）", text: $publicHandle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                Button(mode == .register ? "创建账号" : "使用密码登录") {
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
                .disabled(accountHandle.isEmpty || password.isEmpty || (mode == .register && (publicHandle.isEmpty || displayName.isEmpty)))
                .accessibilityIdentifier("v2.password.submit")
            }

            if let authenticationMessage {
                Section {
                    Text(authenticationMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("v2.authentication.message")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("登录")
    }

    private func run(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        actionTask?.cancel()
        actionTask = Task { await operation() }
    }
}

private struct V2SignedInRootView: View {
    let conversationStore: V2ConversationListStore
    let privacySettingsStore: V2PrivacySettingsStore
    let publicIdentitySettingsStore: V2PublicIdentitySettingsStore?
    let pushWakeSettingsStore: V2PushWakeSettingsStore?
    let signOut: @MainActor @Sendable () async -> Void
    @State private var signOutTask: Task<Void, Never>?
    @State private var isPresentingPrivacySettings = false
    @State private var isPresentingPublicIdentitySettings = false

    var body: some View {
        V2ConversationListView(store: conversationStore)
            .overlay(alignment: .bottomTrailing) {
                Menu {
                    if publicIdentitySettingsStore != nil {
                        Button("我的资料") {
                            isPresentingPublicIdentitySettings = true
                        }
                        .accessibilityIdentifier("v2.identity.open")
                    }
                    Button("消息接收设置") {
                        isPresentingPrivacySettings = true
                    }
                    .accessibilityIdentifier("v2.privacy.open")
                    Button("退出登录", role: .destructive) {
                        signOutTask?.cancel()
                        signOutTask = Task { await signOut() }
                    }
                    .accessibilityIdentifier("v2.sign-out")
                } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.title2)
                        .padding()
                }
                .accessibilityLabel("账户和设置")
                .accessibilityHint("打开资料、消息接收设置和退出登录菜单")
                .accessibilityIdentifier("v2.account-menu")
            }
            .onDisappear { signOutTask?.cancel() }
            .sheet(isPresented: $isPresentingPrivacySettings) {
                NavigationStack {
                    V2PrivacySettingsView(store: privacySettingsStore, pushWakeSettingsStore: pushWakeSettingsStore)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("完成") { isPresentingPrivacySettings = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $isPresentingPublicIdentitySettings) {
                if let publicIdentitySettingsStore {
                    NavigationStack {
                        V2PublicIdentitySettingsView(store: publicIdentitySettingsStore)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("完成") { isPresentingPublicIdentitySettings = false }
                                }
                            }
                    }
                }
            }
    }
}
