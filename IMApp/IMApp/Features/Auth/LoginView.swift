import SwiftUI

struct LoginView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "登录"
        case register = "注册"

        var id: Self { self }
    }

    @EnvironmentObject private var authManager: AuthManager

    let message: String?

    @State private var mode: Mode = .signIn
    @State private var email = "demo@example.com"
    @State private var password = "password1234"
    @State private var confirmPassword = ""
    @State private var localMessage: String?

    private let demoAccounts = DemoLoginAccount.defaults

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(mode == .signIn ? "登录" : "注册账号")
                            .font(.largeTitle.bold())
                        Text("SwiftUI App 连接 Vapor API，支持轮换刷新令牌")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Picker("模式", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _, _ in
                        localMessage = nil
                    }

                    if mode == .signIn {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("测试账号")
                                .font(.headline)

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                                ForEach(demoAccounts) { account in
                                    Button {
                                        selectDemoAccount(account)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(account.name)
                                                .font(.subheadline.weight(.semibold))
                                            Text(account.email)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 12)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(email == account.email ? .accentColor : .secondary)
                                    .disabled(authManager.isBusy)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(spacing: 16) {
                        TextField("邮箱", text: $email)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .padding()
                            .background(.background)
                            .clipShape(RoundedRectangle(cornerRadius: 14))

                        SecureField("密码", text: $password)
                            .padding()
                            .background(.background)
                            .clipShape(RoundedRectangle(cornerRadius: 14))

                        if mode == .register {
                            SecureField("确认密码", text: $confirmPassword)
                                .padding()
                                .background(.background)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }

                    if let displayMessage, !displayMessage.isEmpty {
                        Text(displayMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        submit()
                    } label: {
                        if authManager.isBusy {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(mode == .signIn ? "继续" : "创建账号")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(authManager.isBusy || email.isEmpty || password.isEmpty || (mode == .register && confirmPassword.isEmpty))

                    if mode == .signIn {
                        Text("开发环境默认密码：password1234")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("注册成功后会立即登录，并绑定到当前设备会话。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer(minLength: 0)
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    private func selectDemoAccount(_ account: DemoLoginAccount) {
        localMessage = nil
        email = account.email
        password = account.password
        Task {
            await authManager.login(email: account.email, password: account.password)
        }
    }

    private var displayMessage: String? {
        localMessage ?? message
    }

    private func submit() {
        localMessage = nil

        if mode == .register, password != confirmPassword {
            localMessage = "两次输入的密码不一致。"
            return
        }

        Task {
            switch mode {
            case .signIn:
                await authManager.login(email: email, password: password)
            case .register:
                await authManager.register(email: email, password: password)
            }
        }
    }
}

private struct DemoLoginAccount: Identifiable {
    let name: String
    let email: String
    let password: String

    var id: String { email }

    static let defaults = [
        DemoLoginAccount(name: "Demo", email: "demo@example.com", password: "password1234"),
        DemoLoginAccount(name: "Alice", email: "alice@example.com", password: "password1234"),
        DemoLoginAccount(name: "Bob", email: "bob@example.com", password: "password1234"),
        DemoLoginAccount(name: "Carol", email: "carol@example.com", password: "password1234"),
        DemoLoginAccount(name: "Dave", email: "dave@example.com", password: "password1234")
    ]
}
