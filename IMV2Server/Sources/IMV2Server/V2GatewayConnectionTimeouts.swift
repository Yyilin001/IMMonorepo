import NIOCore

/// 网关连接超时配置，在构造 NIO 定时器前完成一次校验。
///
/// 毫秒配置必须能在有符号纳秒范围内精确表示，因此上限为 `Int64.max / 1_000_000`；
/// 使用该上限可避免换算时溢出，同时不损失配置精度。
struct V2GatewayConnectionTimeouts: Sendable {
    /// 毫秒配置可取的最大值，即 `Int64.max` 纳秒内可容纳的完整毫秒数。
    static let maximumMilliseconds = Int(Int64.max / 1_000_000)
    /// 认证阶段的等待上限。
    let authentication: TimeAmount
    /// 连接空闲超时。
    let idle: TimeAmount

    /// 校验毫秒配置并转换为 NIO 时间量。
    ///
    /// - Parameters:
    ///   - authenticationMilliseconds: 认证阶段等待毫秒数，需落在 `1...maximumMilliseconds`。
    ///   - idleMilliseconds: 空闲超时毫秒数，需落在 `1...maximumMilliseconds`。
    /// - Throws: 任一取值越界时抛出 ``V2TLSGatewayServerError/invalidConfiguration``；
    ///   不会用裁剪或默认值掩盖非法配置。
    init(authenticationMilliseconds: Int, idleMilliseconds: Int) throws {
        let supported = 1...Self.maximumMilliseconds
        guard supported.contains(authenticationMilliseconds), supported.contains(idleMilliseconds) else {
            throw V2TLSGatewayServerError.invalidConfiguration
        }
        authentication = .milliseconds(Int64(authenticationMilliseconds))
        idle = .milliseconds(Int64(idleMilliseconds))
    }
}
