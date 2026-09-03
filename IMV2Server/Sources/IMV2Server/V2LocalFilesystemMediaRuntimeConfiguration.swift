import Foundation

/// Explicit local-development composition for the filesystem media provider.
/// It is opt-in: an absent mode leaves the account service without a media
/// byte edge, so this test substitute cannot silently reach production.
public struct V2LocalFilesystemMediaRuntimeConfiguration: Sendable {
    public let rootDirectory: URL
    public let publicBaseURL: URL
    public let signingKey: Data
    public let maximumBytes: Int64

    public init?(environment: any V2RuntimeEnvironment) throws {
        guard let rawMode = environment.value(for: "IM_V2_LOCAL_MEDIA_MODE")?.trimmingCharacters(in: .whitespacesAndNewlines), !rawMode.isEmpty else {
            guard environment.value(for: "IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY") == nil else {
                throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY")
            }
            return nil
        }
        guard rawMode == "filesystem" else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_LOCAL_MEDIA_MODE")
        }
        guard environment.value(for: "IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY") == "1" else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY")
        }
        guard let rawDirectory = environment.value(for: "IM_V2_LOCAL_MEDIA_ROOT_DIRECTORY")?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawDirectory.hasPrefix("/"),
              let rawBaseURL = environment.value(for: "IM_V2_LOCAL_MEDIA_PUBLIC_BASE_URL")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let publicBaseURL = URL(string: rawBaseURL),
              publicBaseURL.scheme?.lowercased() == "https",
              let publicHost = publicBaseURL.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(publicHost),
              publicBaseURL.query == nil,
              publicBaseURL.fragment == nil,
              let encodedSigningKey = environment.value(for: "IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let signingKey = Data(base64Encoded: encodedSigningKey),
              signingKey.count >= 32,
              let rawMaximumBytes = environment.value(for: "IM_V2_LOCAL_MEDIA_MAXIMUM_BYTES")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let maximumBytes = Int64(rawMaximumBytes),
              maximumBytes > 0,
              maximumBytes <= Int64(Int.max)
        else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_LOCAL_MEDIA_*")
        }
        rootDirectory = URL(fileURLWithPath: rawDirectory, isDirectory: true).standardizedFileURL
        self.publicBaseURL = publicBaseURL
        self.signingKey = signingKey
        self.maximumBytes = maximumBytes
    }
}
