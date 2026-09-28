import Foundation
import IMV2ClientKit

/// 应用运行配置。
struct V2AppConfiguration: Sendable {
    /// 账号服务基础地址。
    let accountBaseURL: URL
    /// 实时网关地址。
    let realtimeEndpoint: V2RealtimeEndpoint
    let messageSendTransportMode: V2MessageSendTransportMode
    /// 钥匙串服务名。
    let keychainService: String
    /// 推送端点运行环境。
    let pushEndpointEnvironment: V2ClientPushEndpointEnvironment

    /// 从应用包读取配置。
    ///
    /// - Parameter bundle: 提供配置键的应用包，默认主包。
    /// - Throws: 账号地址、实时网关地址或推送环境缺失或非法时抛出
    ///   ``V2AppConfigurationError``。
    init(bundle: Bundle = .main) throws {
        try self.init(bundle: bundle, realtimeEndpointOverride: nil)
    }

    #if DEBUG
    /// 仅供 Debug 构建使用的确定性离线界面夹具配置。
    ///
    /// 账号 HTTPS 源保持真实，使已建立的本地会话仍能打开其 SQLite 投影；
    /// 这里只让实时传输不可用。
    ///
    /// - Parameters:
    ///   - localE2ETestForcesUnavailableRealtime: 是否强制实时传输不可用。
    ///   - bundle: 提供配置键的应用包。
    /// - Throws: 与常规构造相同的配置错误。
    init(localE2ETestForcesUnavailableRealtime: Bool, bundle: Bundle = .main) throws {
        let realtimeEndpointOverride = localE2ETestForcesUnavailableRealtime
            ? try V2RealtimeEndpoint(host: "127.0.0.1", port: 1)
            : nil
        try self.init(bundle: bundle, realtimeEndpointOverride: realtimeEndpointOverride)
    }
    #endif

    /// 读取并校验配置键后保存。
    ///
    /// 账号地址必须是带主机名的 HTTPS 地址；网关端口需可解析为 `UInt16`；
    /// 推送环境必须是已知取值。
    ///
    /// - Parameters:
    ///   - bundle: 提供配置键的应用包。
    ///   - realtimeEndpointOverride: 可覆盖实时网关地址，用于离线夹具。
    /// - Throws: 任一配置缺失或非法时抛出 ``V2AppConfigurationError``。
    private init(bundle: Bundle, realtimeEndpointOverride: V2RealtimeEndpoint?) throws {
        guard let rawBaseURL = bundle.object(forInfoDictionaryKey: "IMV2AccountBaseURL") as? String,
              let accountBaseURL = URL(string: rawBaseURL),
              accountBaseURL.scheme?.lowercased() == "https", accountBaseURL.host != nil
        else { throw V2AppConfigurationError.invalidAccountBaseURL }
        guard let gatewayHost = bundle.object(forInfoDictionaryKey: "IMV2GatewayHost") as? String,
              let rawGatewayPort = bundle.object(forInfoDictionaryKey: "IMV2GatewayPort"),
              let gatewayPort = UInt16(String(describing: rawGatewayPort))
        else { throw V2AppConfigurationError.invalidRealtimeEndpoint }
        self.accountBaseURL = accountBaseURL
        if let rawMode = bundle.object(forInfoDictionaryKey: "IMV2MessageSendTransportMode") as? String {
            guard let mode = V2MessageSendTransportMode(rawValue: rawMode) else {
                throw V2AppConfigurationError.invalidMessageSendTransportMode
            }
            messageSendTransportMode = mode
        } else {
            messageSendTransportMode = .automatic
        }
        if let realtimeEndpointOverride {
            realtimeEndpoint = realtimeEndpointOverride
        } else {
            realtimeEndpoint = try V2RealtimeEndpoint(host: gatewayHost, port: gatewayPort)
        }
        guard let rawPushEnvironment = bundle.object(forInfoDictionaryKey: "IMV2PushEnvironment") as? String,
              let pushEndpointEnvironment = V2ClientPushEndpointEnvironment(rawValue: rawPushEnvironment)
        else { throw V2AppConfigurationError.invalidPushEnvironment }
        self.pushEndpointEnvironment = pushEndpointEnvironment
        keychainService = (bundle.bundleIdentifier ?? "com.stskcxfz.imapp") + ".v2"
    }

    /// 在账号服务基础地址下拼出指定路径的端点。
    ///
    /// - Parameter path: 相对路径。
    /// - Returns: 完整端点地址。
    func endpoint(_ path: String) -> URL {
        accountBaseURL.appending(path: path)
    }

    /// 媒体边缘端点。
    ///
    /// 在本地 V2 组合中它与账号服务共用同一 HTTPS 源；
    /// 生产环境仍保留独立的 `/v2/media` 授权边界与部署监听。
    var mediaEdgeEndpoint: URL {
        endpoint("v2/media")
    }

    /// 推送端点地址。
    var pushEndpoint: URL {
        endpoint("v2/push-endpoint")
    }
}

/// 应用配置错误。
enum V2AppConfigurationError: Error, Equatable {
    /// 账号基础地址缺失或不是合法 HTTPS 地址。
    case invalidAccountBaseURL
    /// 实时网关地址或端口缺失、非法。
    case invalidRealtimeEndpoint
    /// 推送环境取值缺失或未知。
    case invalidPushEnvironment
    case invalidMessageSendTransportMode
}
