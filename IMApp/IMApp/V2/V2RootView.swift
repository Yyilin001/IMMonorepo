import SwiftUI

struct V2RootView: View {
    private let appPushDelegate: V2AppPushDelegate
    @State private var store: V2AppStore

    init(appPushDelegate: V2AppPushDelegate) {
        self.appPushDelegate = appPushDelegate
        _store = State(initialValue: V2AppStore(remoteNotificationRegistrar: appPushDelegate))
    }

    var body: some View {
        Group {
            switch store.route {
            case .launching:
                ProgressView("正在恢复 V2 会话…")
            case .signedOut:
                V2SignInView(store: store, authenticationMessage: store.authenticationMessage)
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
    }
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
        .onDisappear { actionTask?.cancel() }
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
