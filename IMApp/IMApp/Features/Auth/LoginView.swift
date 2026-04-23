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
                        Text("开发环境默认账号：demo@example.com / password1234")
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
