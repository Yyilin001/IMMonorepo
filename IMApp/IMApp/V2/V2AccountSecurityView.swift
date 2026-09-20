import SwiftUI
import IMV2ClientKit
import IMV2Core

@MainActor @Observable
final class V2AccountSecurityStore {
    enum State: Equatable { case editing, working, completed(String), failed(String) }
    var state: State = .editing
    private let client: V2PasswordLifecycleClient
    private let passwordChanged: @MainActor @Sendable () async -> Void
    init(client: V2PasswordLifecycleClient, passwordChanged: @escaping @MainActor @Sendable () async -> Void) {
        self.client = client
        self.passwordChanged = passwordChanged
    }
    func perform(_ action: V2PasswordLifecycleAction, account: String, current: String, next: String, code: String) async {
        guard state != .working else { return }
        state = .working
        do {
            try await client.perform(action, accountHandle: account, deviceID: .init(uuid: UUID()),
                                     currentPassword: current, newPassword: next, recoveryCode: code)
            try Task.checkCancellation()
            state = .completed(action == .recoveryCode
                ? "恢复码已启用。请将已保存的副本放在安全位置；旧恢复码已失效。"
                : "密码已更新，全部设备已退出登录。请使用新密码登录，并重新设置恢复码。")
            if action != .recoveryCode { await passwordChanged() }
        } catch is CancellationError {
            state = .editing
        } catch V2AccountAuthenticationError.rateLimited(let seconds) {
            state = .failed(seconds.map { "尝试过于频繁，请在 \($0) 秒后重试。" } ?? "尝试过于频繁，请稍后重试。")
        } catch V2AccountAuthenticationError.authenticationRejected {
            state = .failed("账号、当前密码或恢复码不正确，或已被更换。若上次请求中断，请先尝试用新密码登录。")
        } catch V2AccountAuthenticationError.invalidRecoveryCode {
            state = .failed("恢复码须为保存时的 64 位小写字母和数字，请检查是否完整。")
        } catch V2AccountAuthenticationError.invalidPassword {
            state = .failed("密码须为 12–1024 个 UTF-8 字节，不能包含空字符。")
        } catch V2AccountAuthenticationError.serverStatus(400) {
            state = .failed("请检查账号和恢复码格式；新密码不能与当前密码相同。")
        } catch {
            // A response can be lost after commit. Never claim the mutation failed or
            // automatically repeat it with a different recovery code.
            state = .failed("尚未确认操作结果。若修改或重置密码，请先尝试用新密码登录；若设置恢复码，请保留已保存的副本，稍后用同一码重试。")
        }
    }
}

struct V2AccountSecurityView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store: V2AccountSecurityStore
    @State private var action: V2PasswordLifecycleAction
    @State private var account = ""
    @State private var current = ""
    @State private var next = ""
    @State private var confirmation = ""
    @State private var code = ""
    @State private var savedCode = false
    @State private var operation: Task<Void, Never>?

    init(client: V2PasswordLifecycleClient, initialAction: V2PasswordLifecycleAction = .change,
         passwordChanged: @escaping @MainActor @Sendable () async -> Void = {}) {
        _store = State(initialValue: V2AccountSecurityStore(client: client, passwordChanged: passwordChanged))
        _action = State(initialValue: initialAction)
    }

    var body: some View {
        Form {
            Section {
                Picker("操作", selection: $action) {
                    Text("修改密码").tag(V2PasswordLifecycleAction.change)
                    Text("设置恢复码").tag(V2PasswordLifecycleAction.recoveryCode)
                    Text("找回账号").tag(V2PasswordLifecycleAction.recover)
                }
                .accessibilityIdentifier("v2.security.action")
                TextField("登录账号", text: $account)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("v2.security.account")
                if action != .recover {
                    SecureField("当前密码", text: $current).textContentType(.password)
                        .accessibilityIdentifier("v2.security.current-password")
                }
                if action != .recoveryCode {
                    SecureField("新密码", text: $next).textContentType(.newPassword)
                        .accessibilityIdentifier("v2.security.new-password")
                    SecureField("确认新密码", text: $confirmation).textContentType(.newPassword)
                    Text("密码更新后所有设备都会退出登录，现有恢复码也会失效。")
                }
                if action == .recover {
                    SecureField("已保存的恢复码", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("v2.security.recovery-code")
                    Text("需要此前保存的恢复码。没有密码和恢复码时，无法仅凭公开资料找回账号。")
                }
            }
            if action == .recoveryCode {
                Section("离线恢复码") {
                    Text("恢复码可以重置你的密码。请保存到安全的密码管理器或离线介质，不要分享给他人。启用新码后旧码失效。")
                    if code.isEmpty {
                        Button("生成恢复码") {
                            do { code = try V2PasswordLifecycleClient.generateRecoveryCode() }
                            catch { store.state = .failed("无法生成恢复码，请稍后重试。") }
                        }.accessibilityIdentifier("v2.security.generate-code")
                    } else {
                        Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .privacySensitive()
                        Toggle("我已在应用外安全保存恢复码", isOn: $savedCode)
                            .accessibilityIdentifier("v2.security.saved-code")
                    }
                }
            }
            Section {
                Button(action == .recoveryCode ? "启用恢复码" : "更新密码") {
                    guard operation == nil else { return }
                    let submittedAction = action, submittedAccount = account
                    let submittedCurrent = current, submittedNext = next, submittedCode = code
                    current = ""; next = ""; confirmation = ""
                    if action != .recoveryCode { code = "" }
                    operation = Task {
                        await store.perform(submittedAction, account: submittedAccount, current: submittedCurrent, next: submittedNext, code: submittedCode)
                        operation = nil
                    }
                }
                .disabled(!canSubmit)
                .accessibilityIdentifier("v2.security.submit")
                switch store.state {
                case .working: ProgressView("正在处理…")
                case .failed(let message), .completed(let message):
                    Text(message).accessibilityIdentifier("v2.security.feedback")
                case .editing: EmptyView()
                }
            }
        }
        .disabled(store.state == .working || operation != nil)
        .navigationTitle("账号安全")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(store.state == .working) } }
        .interactiveDismissDisabled(store.state == .working)
        .onChange(of: action) { _, _ in current = ""; next = ""; confirmation = ""; code = ""; savedCode = false; store.state = .editing }
        .onDisappear { operation?.cancel(); current = ""; next = ""; confirmation = ""; code = "" }
    }
    private var canSubmit: Bool {
        guard !account.isEmpty, store.state != .working, operation == nil else { return false }
        if case .completed = store.state { return false }
        return (action == .recover || !current.isEmpty)
            && (action == .recoveryCode || (!next.isEmpty && next == confirmation))
            && (action == .change || (!code.isEmpty && (action == .recover || savedCode)))
    }
}
