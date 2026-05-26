import Foundation

enum LoginFormMode: String, CaseIterable, Identifiable {
    case signIn = "登录"
    case register = "注册"

    var id: Self { self }

    var title: String {
        switch self {
        case .signIn:
            return "登录"
        case .register:
            return "注册账号"
        }
    }

    var submitTitle: String {
        switch self {
        case .signIn:
            return "继续"
        case .register:
            return "创建账号"
        }
    }
}

struct LoginFormInput: Equatable {
    var mode: LoginFormMode
    var email: String
    var password: String
    var confirmPassword: String

    var normalizedEmail: String {
        email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var trimmedPassword: String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSubmittable: Bool {
        validationMessage == nil
    }

    var validationMessage: String? {
        if normalizedEmail.isEmpty {
            return "请输入邮箱。"
        }

        if !Self.isPlausibleEmail(normalizedEmail) {
            return "请输入有效的邮箱地址。"
        }

        if trimmedPassword.isEmpty {
            return "请输入密码。"
        }

        if trimmedPassword.count < 10 {
            return "密码至少需要 10 位。"
        }

        if Self.isCommonWeakPassword(trimmedPassword) {
            return "请使用更安全的密码。"
        }

        if mode == .register, password != confirmPassword {
            return "两次输入的密码不一致。"
        }

        return nil
    }

    private static func isPlausibleEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let local = parts.first,
              let domain = parts.last,
              !local.isEmpty,
              domain.contains("."),
              !domain.hasPrefix("."),
              !domain.hasSuffix(".")
        else {
            return false
        }

        return !email.contains(" ")
    }

    private static func isCommonWeakPassword(_ password: String) -> Bool {
        let normalized = password.lowercased()
        return ["password", "1234567890", "qwerty12345"].contains(normalized)
    }
}
