import Foundation

/// 本地文件系统媒体提供方的显式开发配置。
///
/// 该能力需主动开启：未配置模式时账号服务不会装配媒体字节边缘，
/// 因此这个测试替身不会在生产环境被动生效。
///
/// 解析的环境变量为：
/// `IM_V2_LOCAL_MEDIA_MODE` 必须为 `filesystem`；
/// `IM_V2_LOCAL_MEDIA_UNSAFE_TEST_ONLY` 必须为 `1`；
/// `IM_V2_LOCAL_MEDIA_ROOT_DIRECTORY` 为绝对路径；
/// `IM_V2_LOCAL_MEDIA_PUBLIC_BASE_URL` 为指向本机回环地址的 HTTPS 地址且不带查询与片段；
/// `IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64` 为至少 32 字节的 Base64 密钥；
/// `IM_V2_LOCAL_MEDIA_MAXIMUM_BYTES` 为正的 `Int64` 且不超过 `Int.max`。
public struct V2LocalFilesystemMediaRuntimeConfiguration: Sendable {
    /// 媒体对象落盘的根目录，已标准化。
    public let rootDirectory: URL
    /// 对外发布的回环 HTTPS 基础地址。
    public let publicBaseURL: URL
    /// 用于签名本地链接的密钥材料。
    public let signingKey: Data
    /// 单个媒体对象允许的最大字节数。
    public let maximumBytes: Int64

    /// 从运行环境解析本地媒体配置。
    ///
    /// - Parameter environment: 读取环境变量的运行时视图。
    /// - Returns: 未配置媒体模式时返回 `nil`，表示不装配本地媒体边缘。
    /// - Throws: 仅设置了测试开关而未设置模式，或任一变量缺失、格式不符时抛出
    ///   ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
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
