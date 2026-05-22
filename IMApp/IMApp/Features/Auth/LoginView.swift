import SwiftUI

struct LoginView: View {
    private enum Field: Hashable {
        case email
        case password
        case confirmPassword
    }

    private let sessionStore: AppSessionStore
    private let authentication: AuthenticationFacade

    @State private var mode: LoginFormMode = .signIn
    @State private var email = "demo@example.com"
    @State private var password = "password1234"
    @State private var confirmPassword = ""
    @State private var showsPassword = false
    @State private var showsConfirmPassword = false
    @State private var localMessage: String?
    @FocusState private var focusedField: Field?

    private let demoAccounts = DemoLoginAccount.defaults

    init(authentication: AuthenticationFacade) {
        self.authentication = authentication
        self.sessionStore = authentication.sessionStore
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    modePicker
                    form
                    notice
                    primaryAction
                    secondaryArea
                }
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
            }
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title.weight(.semibold))
                .imageScale(.large)
                .foregroundStyle(Color.accentColor)
                .padding(18)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(mode.title)
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("使用 IMApp 账号继续")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var modePicker: some View {
        Picker("模式", selection: $mode) {
            ForEach(LoginFormMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("auth.modePicker")
        .onChange(of: mode) { _, _ in
            localMessage = nil
            confirmPassword = ""
            showsConfirmPassword = false
            focusedField = .email
        }
    }

    private var form: some View {
        VStack(spacing: 0) {
            fieldRow(systemImage: "envelope") {
                TextField("邮箱", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .email)
                    .onSubmit { focusedField = .password }
                    .accessibilityIdentifier("auth.emailField")
            }

            Divider()
                .padding(.leading, 52)

            passwordRow(
                title: "密码",
                systemImage: "lock",
                text: $password,
                isVisible: $showsPassword,
                field: .password,
                submitLabel: mode == .signIn ? .go : .next,
                accessibilityIdentifier: "auth.passwordField",
                onSubmit: {
                    if mode == .signIn {
                        submit()
                    } else {
                        focusedField = .confirmPassword
                    }
                }
            )

            if mode == .register {
                Divider()
                    .padding(.leading, 52)

                passwordRow(
                    title: "确认密码",
                    systemImage: "checkmark.shield",
                    text: $confirmPassword,
                    isVisible: $showsConfirmPassword,
                    field: .confirmPassword,
                    submitLabel: .go,
                    accessibilityIdentifier: "auth.confirmPasswordField",
                    onSubmit: submit
                )
                .transition(.opacity)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .animation(.snappy(duration: 0.18), value: mode)
    }

    @ViewBuilder
    private var notice: some View {
        if let displayNotice {
            AuthNoticeBanner(notice: displayNotice)
                .accessibilityIdentifier("auth.notice")
        }
    }

    private var primaryAction: some View {
        Button {
            submit()
        } label: {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                        .accessibilityHidden(true)
                }

                Text(submitTitle)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .controlSize(.large)
        .disabled(isBusy)
        .accessibilityIdentifier("auth.submitButton")
    }

    private var secondaryArea: some View {
        VStack(spacing: 12) {
            if mode == .signIn {
                Menu {
                    ForEach(demoAccounts) { account in
                        Button(account.email) {
                            selectDemoAccount(account)
                        }
                        .accessibilityIdentifier("auth.demoAccount.\(account.id)")
                    }
                } label: {
                    Label("使用测试账号", systemImage: "person.crop.circle")
                        .font(.subheadline)
                }
                .controlSize(.regular)
                .disabled(isBusy)

                Text("开发环境默认密码：password1234")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("注册成功后会立即登录，并绑定当前设备。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func fieldRow<Content: View>(
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            content()
                .font(.body)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func passwordRow(
        title: String,
        systemImage: String,
        text: Binding<String>,
        isVisible: Binding<Bool>,
        field: Field,
        submitLabel: SubmitLabel,
        accessibilityIdentifier: String,
        onSubmit: @escaping () -> Void
    ) -> some View {
        fieldRow(systemImage: systemImage) {
            HStack(spacing: 8) {
                Group {
                    if isVisible.wrappedValue {
                        TextField(title, text: text)
                    } else {
                        SecureField(title, text: text)
                    }
                }
                .textContentType(field == .password ? .password : .newPassword)
                .submitLabel(submitLabel)
                .focused($focusedField, equals: field)
                .onSubmit(onSubmit)
                .accessibilityIdentifier(accessibilityIdentifier)

                Button {
                    isVisible.wrappedValue.toggle()
                } label: {
                    Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
                        .font(.body.weight(.medium))
                        .imageScale(.medium)
                        .padding(.vertical, 6)
                        .padding(.leading, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isVisible.wrappedValue ? "隐藏\(title)" : "显示\(title)")
            }
        }
    }

    private func selectDemoAccount(_ account: DemoLoginAccount) {
        localMessage = nil
        email = account.email
        password = account.password
        confirmPassword = ""
        focusedField = nil
        Task {
            await authentication.login(email: account.email, password: account.password)
        }
    }

    private var displayNotice: AuthNotice? {
        if let localMessage {
            return AuthNotice(
                code: .unknown,
                message: localMessage,
                severity: .error,
                isRecoverable: true
            )
        }
        return authentication.notice
    }

    private var submitTitle: String {
        if isBusy {
            switch sessionStore.authOperationState {
            case .authenticating(.login):
                return "正在登录"
            case .authenticating(.register):
                return "正在创建"
            default:
                return "正在处理"
            }
        }
        return mode.submitTitle
    }

    private var isBusy: Bool {
        sessionStore.authOperationState.isBusy
    }

    private var formInput: LoginFormInput {
        LoginFormInput(
            mode: mode,
            email: email,
            password: password,
            confirmPassword: confirmPassword
        )
    }

    private func submit() {
        localMessage = nil

        let input = formInput
        if let validationMessage = input.validationMessage {
            localMessage = validationMessage
            return
        }

        focusedField = nil
        Task {
            switch mode {
            case .signIn:
                await authentication.login(email: input.normalizedEmail, password: input.trimmedPassword)
            case .register:
                await authentication.register(email: input.normalizedEmail, password: input.trimmedPassword)
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

private struct AuthNoticeBanner: View {
    let notice: AuthNotice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.medium))
                .imageScale(.medium)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(notice.message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var icon: String {
        switch notice.severity {
        case .info:
            return "info.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .error:
            return "exclamationmark.circle"
        }
    }

    private var tint: Color {
        switch notice.severity {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
