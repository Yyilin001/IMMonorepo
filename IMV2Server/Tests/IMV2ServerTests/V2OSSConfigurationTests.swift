import Foundation
import Testing
import IMV2Server
import IMV2ServerApplication
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure

struct V2OSSConfigurationTests {
    @Test func mixedBindingsPreserveLocalResourcesAndSelectOSS() throws {
        let values = ["IM_V2_RESOURCE_STORAGE_BINDINGS_JSON": """
            [{"id":"local-filesystem","revision":1,"directory":"/srv/old"},
             {"id":"oss","revision":1,"kind":"oss","oss":{"bucket":"example-bucket","region":"cn-shenzhen",
              "endpoint":"https://example-bucket.oss-cn-shenzhen.aliyuncs.com","prefix":"imv2/"}}]
            """, "IM_V2_RESOURCE_DEFAULT_BINDING": "oss"]
        let config = try V2ResourceBackendConfiguration(environment: V2DictionaryRuntimeEnvironment(values), defaultDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(config.entries.map(\.providerKind) == [.local, .oss])
        #expect(config.defaultBinding.id == "oss")
    }

    @Test(arguments: ["http://example-bucket.oss-cn-shenzhen.aliyuncs.com",
                      "https://attacker.example", "https://example-bucket.oss-cn-shenzhen.aliyuncs.com/path",
                      "https://example-bucket.oss-cn-shenzhen.aliyuncs.com?token=secret"])
    func rejectsCredentialDestinationConfusion(endpoint: String) throws {
        #expect(throws: V2ResourceProviderError.configurationInvalid) {
            _ = try V2OSSConfiguration(bucket: "example-bucket", region: "cn-shenzhen", endpoint: URL(string: endpoint)!,
                prefix: "imv2/", binding: .init(id: "oss", configurationRevision: 1))
        }
    }

    @Test func cloudRuntimeDoesNotRequireUnsafeLocalMode() throws {
        let values = ["IM_V2_RESOURCE_MODE": "enabled", "IM_V2_RESOURCE_STORAGE_BINDINGS_JSON": "[]",
                      "IM_V2_RESOURCE_WORK_DIRECTORY": "/tmp/resource-work", "IM_V2_RESOURCE_PUBLIC_BASE_URL": "https://media.example",
                      "IM_V2_RESOURCE_SIGNING_KEY_BASE64": Data(repeating: 1, count: 32).base64EncodedString(),
                      "IM_V2_RESOURCE_MAXIMUM_BYTES": "1048576"]
        let runtime = try #require(try V2ResourceRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values)))
        #expect(runtime.maximumBytes == 1_048_576)
        var ambiguous = values
        ambiguous["IM_V2_LOCAL_MEDIA_MODE"] = "filesystem"
        #expect(throws: V2ResourceProviderError.configurationInvalid) {
            _ = try V2ResourceRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(ambiguous))
        }
    }

    @Test func expiresCredentialsBeforeMakingRequests() async throws {
        let provider = V2OSSCredentialProvider(environment: V2DictionaryRuntimeEnvironment([
            "IM_V2_OSS_ACCESS_KEY_ID": "ak", "IM_V2_OSS_ACCESS_KEY_SECRET": "sk",
            "IM_V2_OSS_CREDENTIAL_EXPIRATION": "2000-01-01T00:00:00Z"]))
        await #expect(throws: V2ResourceProviderError.configurationInvalid) { _ = try await provider.load() }
    }

    @Test func tokenCannotInjectHeaders() throws {
        let signer = V2OSSSigner(region: "cn-shenzhen", bucket: "example-bucket",
            credentials: .init(accessKeyID: "ak", accessKeySecret: "sk", securityToken: "a\r\nb"))
        #expect(throws: V2ResourceProviderError.configurationInvalid) {
            _ = try signer.authorization(method: "GET", key: "object", now: Date())
        }
    }

    @Test func temporaryCredentialIDsAllowSTSPrefix() throws {
        let signer = V2OSSSigner(region: "cn-shenzhen", bucket: "example-bucket",
            credentials: .init(accessKeyID: "STS.example", accessKeySecret: "sk", securityToken: "token"))
        let headers = try signer.authorization(method: "GET", key: "object", now: Date())
        #expect(headers["authorization"]?.contains("Credential=STS.example/") == true)
    }

    @Test func credentialFileRotationIsObservedWithoutRecreatingProvider() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        func save(_ id: String, expiration: String = "2100-01-01T00:00:00Z") throws {
            try JSONSerialization.data(withJSONObject: ["AccessKeyId": id, "AccessKeySecret": "test-secret",
                "SecurityToken": "test-token", "Expiration": expiration]).write(to: file, options: .atomic)
        }
        let provider = V2OSSCredentialProvider(environment: V2DictionaryRuntimeEnvironment([
            "IM_V2_OSS_CREDENTIAL_FILE": file.path]))
        try save("STS.first")
        #expect(try await provider.load().accessKeyID == "STS.first")
        try save("STS.rotated")
        #expect(try await provider.load().accessKeyID == "STS.rotated")
        try save("STS.expired", expiration: "2000-01-01T00:00:00Z")
        await #expect(throws: V2ResourceProviderError.configurationInvalid) { _ = try await provider.load() }
    }

    @Test func invalidCredentialFileDoesNotFallBackToEnvironmentSecrets() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = V2OSSCredentialProvider(environment: V2DictionaryRuntimeEnvironment([
            "IM_V2_OSS_CREDENTIAL_FILE": file.path,
            "IM_V2_OSS_ACCESS_KEY_ID": "fallback", "IM_V2_OSS_ACCESS_KEY_SECRET": "fallback"]))
        for data in [Data(), Data("invalid-json".utf8), Data(repeating: 32, count: 16_385)] {
            try data.write(to: file, options: .atomic)
            await #expect(throws: V2ResourceProviderError.configurationInvalid) { _ = try await provider.load() }
        }
        try FileManager.default.removeItem(at: file)
        await #expect(throws: V2ResourceProviderError.configurationInvalid) { _ = try await provider.load() }
    }
}
