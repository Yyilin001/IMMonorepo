import Foundation
@testable import IMV2Server
import Testing

struct V2AccountRuntimeConfigurationTests {
    @Test("account service accepts only an internal listener with explicit secrets")
    func parsesStrictConfiguration() throws {
        let configuration = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        let expectedListener = try V2AccountListenerConfiguration(host: "127.0.0.1", port: 8444)
        let expectedRateLimit = try V2PasswordLoginRateLimitPolicy(maximumFailures: 5, window: 900, lockout: 900)
        #expect(configuration.listener == expectedListener)
        #expect(configuration.accountAssertionKey.count == 32)
        #expect(configuration.passwordLoginRateLimit == expectedRateLimit)
    }

    @Test("account service rejects public binding")
    func rejectsPublicListener() {
        var publicValues = values
        publicValues["IM_V2_ACCOUNT_LISTEN_HOST"] = "0.0.0.0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_LISTEN_HOST/IM_V2_ACCOUNT_LISTEN_PORT")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(publicValues))
        }
    }

    @Test("account service rejects a non-positive password login rate-limit policy")
    func rejectsInvalidPasswordLoginRateLimit() {
        var invalidValues = values
        invalidValues["IM_V2_PASSWORD_LOGIN_MAX_FAILURES"] = "0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_PASSWORD_LOGIN_MAX_FAILURES/IM_V2_PASSWORD_LOGIN_WINDOW_SECONDS/IM_V2_PASSWORD_LOGIN_LOCKOUT_SECONDS")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(invalidValues))
        }
    }

    private var values: [String: String] {
        [
            "IM_V2_DATABASE_URL": "postgres://v2:password@db/im_v2",
            "IM_V2_ACCOUNT_LISTEN_HOST": "127.0.0.1",
            "IM_V2_ACCOUNT_LISTEN_PORT": "8444",
            "IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64": Data(repeating: 1, count: 32).base64EncodedString(),
            "IM_V2_CREDENTIAL_REPLAY_ENVELOPE_KEY_BASE64": Data(repeating: 2, count: 32).base64EncodedString(),
            "IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64": Data(repeating: 4, count: 32).base64EncodedString(),
            "IM_V2_ACCOUNT_ASSERTION_HMAC_KEY_BASE64": Data(repeating: 3, count: 32).base64EncodedString(),
            "IM_V2_PASSWORD_DUMMY_BCRYPT_HASH": "$2b$12$123456789012345678901u12345678901234567890123456789012",
            "IM_V2_PASSWORD_LOGIN_MAX_FAILURES": "5",
            "IM_V2_PASSWORD_LOGIN_WINDOW_SECONDS": "900",
            "IM_V2_PASSWORD_LOGIN_LOCKOUT_SECONDS": "900",
        ]
    }
}
