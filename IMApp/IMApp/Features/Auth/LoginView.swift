import SwiftUI

struct LoginView: View {
    private enum Field: Hashable {
        case email
        case password
        case confirmPassword
        case code
        case newPassword
        case confirmNewPassword
    }

    private enum AuxiliaryFlow: Equatable {
        case credentials
        case emailVerification
        case passwordResetRequest
        case passwordResetConfirm
    }

    private let sessionStore: AppSessionStore
    private let authentication: AuthenticationFacade

    @State private var mode: LoginFormMode = .signIn
    @State private var flow: AuxiliaryFlow = .credentials
    @State private var email = LoginDefaults.email
    @State private var password = LoginDefaults.password
    @State private var confirmPassword = ""
    @State private var verificationCode = ""
    @State private var newPassword = ""
    @State private var confirmNewPassword = ""
    @State private var showsPassword = false
    @State private var showsConfirmPassword = false
    @State private var showsNewPassword = false
    @State private var showsConfirmNewPassword = false
    @State private var localMessage: String?
    @FocusState private var focusedField: Field?

    #if DEBUG
    private let demoAccounts = DemoLoginAccount.defaults
    #endif

    init(authentication: AuthenticationFacade) {
        self.authentication = authentication
        self.sessionStore = authentication.sessionStore
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.xLarge) {
                    header
                    if flow == .credentials {
                        modePicker
                    }
                    form
                    notice
                    primaryAction
                    secondaryArea
                }
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 64)
                .padding(.bottom, 36)
            }
            .background(AppSurface.groupedBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: authentication.notice) { _, notice in
            if notice?.code == .emailVerificationRequired {
                flow = .emailVerification
                password = ""
                confirmPassword = ""
                verificationCode = ""
                focusedField = .code
            }
        }
    }

    private var header: some View {
        VStack(spacing: AppSpacing.large) {
            Image(systemName: headerIcon)
                .font(.system(size: 30, weight: .semibold))
                .imageScale(.large)
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor, Color.blue.opacity(0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 22)
                )
                .accessibilityHidden(true)

            VStack(spacing: AppSpacing.xSmall) {
                Text("IMApp")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var headerIcon: String {
        switch flow {
        case .credentials:
            return "bubble.left.and.bubble.right.fill"
        case .emailVerification:
            return "envelope.badge.shield.half.filled"
        case .passwordResetRequest, .passwordResetConfirm:
            return "lock.rotation"
        }
    }

    private var headerSubtitle: String {
        switch flow {
        case .credentials:
            return mode == .signIn ? "登录后继续聊天" : "创建账号并绑定当前设备"
        case .emailVerification:
            return "输入邮箱验证码完成账号验证"
        case .passwordResetRequest:
            return "输入账号邮箱获取重置验证码"
        case .passwordResetConfirm:
            return "输入验证码并设置新密码"
        }
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
            emailRow

            switch flow {
            case .credentials:
                credentialsRows
            case .emailVerification:
                codeRows(accessibilityIdentifier: "auth.verificationCodeField")
            case .passwordResetRequest:
                EmptyView()
            case .passwordResetConfirm:
                codeRows(accessibilityIdentifier: "auth.passwordResetCodeField")
                Divider().padding(.leading, 52)
                passwordRow(
                    title: "新密码",
                    systemImage: "lock",
                    text: $newPassword,
                    isVisible: $showsNewPassword,
                    field: .newPassword,
                    submitLabel: .next,
                    accessibilityIdentifier: "auth.newPasswordField",
                    onSubmit: { focusedField = .confirmNewPassword }
                )
                Divider().padding(.leading, 52)
                passwordRow(
                    title: "确认新密码",
                    systemImage: "checkmark.shield",
                    text: $confirmNewPassword,
                    isVisible: $showsConfirmNewPassword,
                    field: .confirmNewPassword,
                    submitLabel: .go,
                    accessibilityIdentifier: "auth.confirmNewPasswordField",
                    onSubmit: submit
                )
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .animation(.snappy(duration: 0.18), value: mode)
        .animation(.snappy(duration: 0.18), value: flow)
        .accessibilityIdentifier("auth.form")
    }

    private var emailRow: some View {
        fieldRow(systemImage: "envelope") {
            TextField("邮箱", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .textContentType(.username)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focusedField, equals: .email)
                .onSubmit { focusedField = nextFieldAfterEmail }
                .accessibilityIdentifier("auth.emailField")
        }
    }

    @ViewBuilder
    private var credentialsRows: some View {
        Divider().padding(.leading, 52)
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
            Divider().padding(.leading, 52)
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

    private func codeRows(accessibilityIdentifier: String) -> some View {
        Group {
            Divider().padding(.leading, 52)
            fieldRow(systemImage: "number") {
                TextField("验证码", text: $verificationCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .code)
                    .onSubmit { focusedField = flow == .passwordResetConfirm ? .newPassword : nil }
                    .accessibilityIdentifier(accessibilityIdentifier)
            }
        }
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
        .disabled(isBusy || !isSubmittable)
        .accessibilityIdentifier("auth.submitButton")
    }

    private var secondaryArea: some View {
        VStack(spacing: AppSpacing.medium) {
            switch flow {
            case .credentials:
                credentialsSecondaryArea
            case .emailVerification:
                Button {
                    submitResendVerification()
                } label: {
                    Label("重新发送验证码", systemImage: "paperplane")
                }
                .buttonStyle(.borderless)
                .disabled(isBusy || normalizedEmail.isEmpty)
                .accessibilityIdentifier("auth.resendVerificationButton")

                Button("返回登录") {
                    switchToCredentials()
                }
                .buttonStyle(.borderless)
            case .passwordResetRequest:
                Button("返回登录") {
                    switchToCredentials()
                }
                .buttonStyle(.borderless)
            case .passwordResetConfirm:
                Button("返回登录") {
                    switchToCredentials()
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var credentialsSecondaryArea: some View {
        if mode == .signIn {
            Button("忘记密码") {
                flow = .passwordResetRequest
                localMessage = nil
                focusedField = .email
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("auth.forgotPasswordButton")

            #if DEBUG
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

            Text("测试账号仅用于本地开发环境")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif
        } else {
            Text("注册后需要完成邮箱验证，再使用账号登录。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
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

    #if DEBUG
    private func selectDemoAccount(_ account: DemoLoginAccount) {
        localMessage = nil
        flow = .credentials
        mode = .signIn
        email = account.email
        password = account.password
        confirmPassword = ""
        focusedField = nil
        Task {
            await authentication.login(email: account.email, password: account.password)
        }
    }
    #endif

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
            case .verifyingEmail:
                return "正在验证"
            case .resettingPassword:
                return "正在处理"
            default:
                return "正在处理"
            }
        }

        switch flow {
        case .credentials:
            return mode.submitTitle
        case .emailVerification:
            return "完成验证"
        case .passwordResetRequest:
            return "获取验证码"
        case .passwordResetConfirm:
            return "重置密码"
        }
    }

    private var isBusy: Bool {
        sessionStore.authOperationState.isBusy
    }

    private var normalizedEmail: String {
        LoginFormInput(mode: mode, email: email, password: password, confirmPassword: confirmPassword).normalizedEmail
    }

    private var nextFieldAfterEmail: Field? {
        switch flow {
        case .credentials:
            return .password
        case .emailVerification, .passwordResetConfirm:
            return .code
        case .passwordResetRequest:
            return nil
        }
    }

    private var isSubmittable: Bool {
        validationMessage == nil
    }

    private var validationMessage: String? {
        switch flow {
        case .credentials:
            return LoginFormInput(
                mode: mode,
                email: email,
                password: password,
                confirmPassword: confirmPassword
            ).validationMessage
        case .emailVerification:
            return validateEmailAndCode()
        case .passwordResetRequest:
            return validateEmail()
        case .passwordResetConfirm:
            if let message = validateEmailAndCode() {
                return message
            }
            return LoginFormInput(
                mode: .register,
                email: email,
                password: newPassword,
                confirmPassword: confirmNewPassword
            ).validationMessage
        }
    }

    private func validateEmail() -> String? {
        LoginFormInput(
            mode: .signIn,
            email: email,
            password: "password123",
            confirmPassword: ""
        ).validationMessage.flatMap { message in
            message.contains("密码") ? nil : message
        }
    }

    private func validateEmailAndCode() -> String? {
        if let message = validateEmail() {
            return message
        }
        if verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入验证码。"
        }
        return nil
    }

    private func submit() {
        localMessage = nil
        if let validationMessage {
            localMessage = validationMessage
            return
        }

        focusedField = nil
        Task {
            switch flow {
            case .credentials:
                switch mode {
                case .signIn:
                    await authentication.login(email: normalizedEmail, password: password.trimmingCharacters(in: .whitespacesAndNewlines))
                case .register:
                    await authentication.register(email: normalizedEmail, password: password.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            case .emailVerification:
                await authentication.confirmEmailVerification(email: normalizedEmail, code: verificationCode)
            case .passwordResetRequest:
                await authentication.requestPasswordReset(email: normalizedEmail)
                flow = .passwordResetConfirm
                verificationCode = ""
                focusedField = .code
            case .passwordResetConfirm:
                await authentication.confirmPasswordReset(
                    email: normalizedEmail,
                    code: verificationCode,
                    newPassword: newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                if authentication.notice?.severity == .info {
                    switchToCredentials()
                }
            }
        }
    }

    private func submitResendVerification() {
        localMessage = nil
        if let message = validateEmail() {
            localMessage = message
            return
        }
        Task {
            await authentication.resendEmailVerification(email: normalizedEmail)
        }
    }

    private func switchToCredentials() {
        flow = .credentials
        mode = .signIn
        localMessage = nil
        verificationCode = ""
        newPassword = ""
        confirmNewPassword = ""
        focusedField = .email
    }
}

private enum LoginDefaults {
    #if DEBUG
    static let email = "demo@example.com"
    static let password = "password1234"
    #else
    static let email = ""
    static let password = ""
    #endif
}

#if DEBUG
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
#endif

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
