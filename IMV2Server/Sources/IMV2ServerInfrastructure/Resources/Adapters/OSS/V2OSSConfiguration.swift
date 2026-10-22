import Foundation
import IMV2ServerApplication
import IMV2ServerContracts

/// Only the composition root and OSS adapters interpret these provider-specific settings.
public struct V2OSSConfiguration: Sendable {
    public let bucket: String
    public let region: String
    public let endpoint: URL
    public let prefix: String
    public let binding: V2StorageBinding

    public init(bucket: String, region: String, endpoint: URL, prefix: String, binding: V2StorageBinding) throws {
        func validLabel(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
        guard validLabel(bucket), (3...63).contains(bucket.count), !bucket.hasPrefix("-"), !bucket.hasSuffix("-"),
              validLabel(region), endpoint.scheme == "https", endpoint.port == nil,
              endpoint.host == "\(bucket).oss-\(region).aliyuncs.com" || endpoint.host == "\(bucket).oss-\(region)-internal.aliyuncs.com",
              endpoint.path.isEmpty || endpoint.path == "/", endpoint.query == nil, endpoint.fragment == nil,
              endpoint.user == nil, endpoint.password == nil,
              !prefix.isEmpty, prefix.count <= 256, !prefix.hasPrefix("/"), prefix.hasSuffix("/"),
              prefix.split(separator: "/").allSatisfy({ validLabel(String($0)) })
        else { throw V2ResourceProviderError.configurationInvalid }
        self.bucket = bucket; self.region = region; self.endpoint = endpoint
        self.prefix = prefix; self.binding = binding
    }
}

/// Refreshable credentials are fetched for each request, never captured in business state.
public struct V2OSSCredentialProvider: Sendable {
    let load: @Sendable () async throws -> V2OSSCredentials

    public init(load: @escaping @Sendable () async throws -> V2OSSCredentials) { self.load = load }

    public init(environment: any V2RuntimeEnvironment, prefix: String = "IM_V2_OSS_") {
        load = {
            if let path = environment.value(for: prefix + "CREDENTIAL_FILE") {
                return try Self.readRotatingCredentials(path: path)
            }
            guard let id = environment.value(for: prefix + "ACCESS_KEY_ID"), !id.isEmpty,
                  let secret = environment.value(for: prefix + "ACCESS_KEY_SECRET"), !secret.isEmpty
            else { throw V2ResourceProviderError.configurationInvalid }
            let token = environment.value(for: prefix + "SECURITY_TOKEN").flatMap { $0.isEmpty ? nil : $0 }
            if let expiration = environment.value(for: prefix + "CREDENTIAL_EXPIRATION"),
               !expiration.isEmpty,
               ISO8601DateFormatter().date(from: expiration).map({ $0 > Date().addingTimeInterval(30) }) != true {
                throw V2ResourceProviderError.configurationInvalid
            }
            return .init(accessKeyID: id, accessKeySecret: secret, securityToken: token)
        }
    }

    /// A host credential agent atomically replaces this private file. Read it for
    /// each request so ECS role rotation does not require restarting the service.
    private static func readRotatingCredentials(path: String) throws -> V2OSSCredentials {
        struct Document: Decodable {
            let AccessKeyId: String
            let AccessKeySecret: String
            let SecurityToken: String
            let Expiration: String
        }
        do {
            guard path.hasPrefix("/"), let file = FileHandle(forReadingAtPath: path) else {
                throw V2ResourceProviderError.configurationInvalid
            }
            defer { try? file.close() }
            let data = try file.read(upToCount: 16_385) ?? Data()
            guard data.count <= 16_384 else { throw V2ResourceProviderError.configurationInvalid }
            let value = try JSONDecoder().decode(Document.self, from: data)
            guard !value.AccessKeyId.isEmpty, !value.AccessKeySecret.isEmpty, !value.SecurityToken.isEmpty,
                  ISO8601DateFormatter().date(from: value.Expiration).map({ $0 > Date().addingTimeInterval(30) }) == true
            else { throw V2ResourceProviderError.configurationInvalid }
            return .init(accessKeyID: value.AccessKeyId, accessKeySecret: value.AccessKeySecret, securityToken: value.SecurityToken)
        } catch {
            // Never include credential file contents or decoder details in errors.
            throw V2ResourceProviderError.configurationInvalid
        }
    }
}
