@testable import IMApp
import Testing

struct LoginFormModelTests {
    @Test func normalizesEmailBeforeAuthentication() {
        let input = LoginFormInput(
            mode: .signIn,
            email: "  DEMO@Example.COM  ",
            password: "password1234",
            confirmPassword: ""
        )

        #expect(input.normalizedEmail == "demo@example.com")
        #expect(input.validationMessage == nil)
    }

    @Test func rejectsInvalidEmail() {
        let input = LoginFormInput(
            mode: .signIn,
            email: "demo",
            password: "password1234",
            confirmPassword: ""
        )

        #expect(input.validationMessage == "请输入有效的邮箱地址。")
        #expect(!input.isSubmittable)
    }

    @Test func rejectsShortPassword() {
        let input = LoginFormInput(
            mode: .signIn,
            email: "demo@example.com",
            password: "short",
            confirmPassword: ""
        )

        #expect(input.validationMessage == "密码至少需要 8 位。")
        #expect(!input.isSubmittable)
    }

    @Test func requiresMatchingConfirmationWhenRegistering() {
        let input = LoginFormInput(
            mode: .register,
            email: "demo@example.com",
            password: "password1234",
            confirmPassword: "password5678"
        )

        #expect(input.validationMessage == "两次输入的密码不一致。")
        #expect(!input.isSubmittable)
    }
}
