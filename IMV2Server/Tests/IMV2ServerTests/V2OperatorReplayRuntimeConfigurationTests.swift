import Foundation
@testable import IMV2Server
import Testing

struct V2OperatorReplayRuntimeConfigurationTests {
    @Test("operator replay configuration requires loopback listener, explicit credential and audited principal")
    func parsesStrictConfiguration() throws {
        let configuration = try V2OperatorReplayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        let expectedListener = try V2OperatorReplayListenerConfiguration(host: "127.0.0.1", port: 9445)
        #expect(configuration.listener == expectedListener)
        #expect(configuration.authenticator.isAuthorized(bearerToken: values["IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64"]))
        #expect(!configuration.authenticator.isAuthorized(bearerToken: "wrong"))
        #expect(configuration.operatorPrincipal == "oncall-primary")
        #expect(configuration.userShardStorage.map(\.bucket) == ["users-primary", "users-next"])
    }

    @Test("operator replay configuration rejects public listener and weak credential")
    func rejectsUnsafeConfiguration() {
        var publicValues = values
        publicValues["IM_V2_OPERATOR_REPLAY_LISTEN_HOST"] = "0.0.0.0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_OPERATOR_REPLAY_LISTEN_HOST/IM_V2_OPERATOR_REPLAY_LISTEN_PORT")) {
            _ = try V2OperatorReplayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(publicValues))
        }
        var weakValues = values
        weakValues["IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64"] = Data(repeating: 1, count: 31).base64EncodedString()
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64")) {
            _ = try V2OperatorReplayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(weakValues))
        }
    }

    private var values: [String: String] {
        [
            "IM_V2_DATABASE_URL": "postgres://v2:password@db/im_v2",
            "IM_V2_OPERATOR_REPLAY_LISTEN_HOST": "127.0.0.1",
            "IM_V2_OPERATOR_REPLAY_LISTEN_PORT": "9445",
            "IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64": Data(repeating: 12, count: 32).base64EncodedString(),
            "IM_V2_OPERATOR_REPLAY_PRINCIPAL": "oncall-primary",
            "IM_V2_USER_SHARD_STORES_JSON": """
            [{"bucket":"users-primary","database_url":"postgres://v2:password@db/im_v2","schema":"im_v2"},
             {"bucket":"users-next","database_url":"postgres://v2:password@db-next/im_v2","schema":"im_v2"}]
            """,
        ]
    }
}
