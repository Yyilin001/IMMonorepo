import Foundation
import IMV2ServerApplication
import IMV2ServerContracts

/// Shared resource edge settings; storage provider configuration is parsed separately.
public struct V2ResourceRuntimeConfiguration: Sendable {
    public let rootDirectory: URL
    public let publicBaseURL: URL
    public let signingKey: Data
    public let maximumBytes: Int64

    public init?(environment: any V2RuntimeEnvironment) throws {
        guard let mode = environment.value(for: "IM_V2_RESOURCE_MODE") else {
            guard let local = try V2LocalFilesystemMediaRuntimeConfiguration(environment: environment) else { return nil }
            rootDirectory = local.rootDirectory; publicBaseURL = local.publicBaseURL
            signingKey = local.signingKey; maximumBytes = local.maximumBytes
            return
        }
        guard mode == "enabled", environment.value(for: "IM_V2_LOCAL_MEDIA_MODE") == nil,
              environment.value(for: "IM_V2_RESOURCE_STORAGE_BINDINGS_JSON") != nil,
              let directory = environment.value(for: "IM_V2_RESOURCE_WORK_DIRECTORY"), directory.hasPrefix("/"),
              let rawURL = environment.value(for: "IM_V2_RESOURCE_PUBLIC_BASE_URL"), let url = URL(string: rawURL),
              url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let encoded = environment.value(for: "IM_V2_RESOURCE_SIGNING_KEY_BASE64"),
              let key = Data(base64Encoded: encoded), key.count == 32,
              let rawMaximum = environment.value(for: "IM_V2_RESOURCE_MAXIMUM_BYTES"),
              let maximum = Int64(rawMaximum), maximum > 0, maximum <= 256 * 1_024 * 1_024
        else { throw V2ResourceProviderError.configurationInvalid }
        rootDirectory = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        publicBaseURL = url; signingKey = key; maximumBytes = maximum
    }
}
