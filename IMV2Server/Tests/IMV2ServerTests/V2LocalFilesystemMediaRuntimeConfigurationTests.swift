@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 local filesystem media runtime configuration")
struct V2LocalFilesystemMediaRuntimeConfigurationTests {
    @Test("local media is opt-in and accepts only explicit filesystem settings")
    func explicitFilesystemConfiguration() throws {
        #expect(try V2LocalFilesystemMediaRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment([:])) == nil)

        let optionalConfiguration = try V2LocalFilesystemMediaRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment([
            "IM_V2_LOCAL_MEDIA_MODE": "filesystem",
            "IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY": "1",
            "IM_V2_LOCAL_MEDIA_ROOT_DIRECTORY": "/var/lib/im-v2-media",
            "IM_V2_LOCAL_MEDIA_PUBLIC_BASE_URL": "https://localhost:8443",
            "IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64": Data(repeating: 1, count: 32).base64EncodedString(),
            "IM_V2_LOCAL_MEDIA_MAXIMUM_BYTES": "1024",
        ]))
        let configuration = try #require(optionalConfiguration)
        #expect(configuration.rootDirectory.path == "/var/lib/im-v2-media")
        #expect(configuration.publicBaseURL == URL(string: "https://localhost:8443"))
        #expect(configuration.maximumBytes == 1_024)
    }

    @Test("local media rejects an unsafe public target and undersized key")
    func invalidConfigurationIsRejected() {
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY")) {
            _ = try V2LocalFilesystemMediaRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment([
                "IM_V2_LOCAL_MEDIA_MODE": "filesystem",
            ]))
        }
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_LOCAL_MEDIA_*")) {
            _ = try V2LocalFilesystemMediaRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment([
                "IM_V2_LOCAL_MEDIA_MODE": "filesystem",
                "IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY": "1",
                "IM_V2_LOCAL_MEDIA_ROOT_DIRECTORY": "/var/lib/im-v2-media",
                "IM_V2_LOCAL_MEDIA_PUBLIC_BASE_URL": "http://localhost:8443",
                "IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64": Data(repeating: 1, count: 8).base64EncodedString(),
                "IM_V2_LOCAL_MEDIA_MAXIMUM_BYTES": "1024",
            ]))
        }
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_LOCAL_MEDIA_*")) {
            _ = try V2LocalFilesystemMediaRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment([
                "IM_V2_LOCAL_MEDIA_MODE": "filesystem",
                "IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY": "1",
                "IM_V2_LOCAL_MEDIA_ROOT_DIRECTORY": "/var/lib/im-v2-media",
                "IM_V2_LOCAL_MEDIA_PUBLIC_BASE_URL": "https://media.example.com",
                "IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64": Data(repeating: 1, count: 32).base64EncodedString(),
                "IM_V2_LOCAL_MEDIA_MAXIMUM_BYTES": "1024",
            ]))
        }
    }
}
