import Foundation
import IMV2Core

/// 推送提供方标识。
///
/// 取值刻意保持很窄：新增提供方是需要评审的服务端改动，而不是由客户端自由传入的字符串。
public enum V2PushEndpointProvider: String, Codable, Equatable, Sendable {
    /// Apple 推送通知服务。
    case apns
}

/// 推送端点所属的运行环境。
public enum V2PushEndpointEnvironment: String, Codable, Equatable, Sendable {
    /// 开发环境（沙盒推送地址）。
    case development
    /// 生产环境。
    case production
}

/// 推送端点注册请求。
///
/// 注册必须以将接收唤醒的那台具体设备身份完成认证。提供方令牌是不透明值，
/// 绝不适合写入日志、指标、事件载荷或用户同步记录。
public struct V2PushDeviceEndpointRegistration: Equatable, Sendable {
    /// 推送提供方。
    public let provider: V2PushEndpointProvider
    /// 运行环境。
    public let environment: V2PushEndpointEnvironment
    /// 提供方令牌，已去除首尾空白。
    public let token: String

    /// 校验并保存注册请求。
    ///
    /// - Parameters:
    ///   - provider: 推送提供方。
    ///   - environment: 运行环境。
    ///   - token: 提供方令牌，去除首尾空白后需非空、不超过 4096 字节且不含空白与控制字符。
    /// - Throws: 令牌不满足上述约束时抛出
    ///   ``V2PushDeviceEndpointError/invalidRegistration``。
    public init(provider: V2PushEndpointProvider, environment: V2PushEndpointEnvironment, token: String) throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 4_096,
              normalized.unicodeScalars.allSatisfy({
                  !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
              })
        else { throw V2PushDeviceEndpointError.invalidRegistration }
        self.provider = provider
        self.environment = environment
        self.token = normalized
    }
}

/// 已注册的推送端点。
///
/// 明文令牌只存在于加密持久化边界与已配置的提供方适配器之间。
/// 代次用于避免延迟到达的提供方拒绝把同一设备更新的端点注册停用。
public struct V2PushDeviceEndpoint: Equatable, Sendable {
    /// 目标设备。
    public let deviceID: DeviceID
    /// 推送提供方。
    public let provider: V2PushEndpointProvider
    /// 运行环境。
    public let environment: V2PushEndpointEnvironment
    /// 提供方令牌明文，仅在内存与配置好的适配器之间传递。
    public let token: String
    /// 本次注册的代次，用于栅栏掉延迟到达的停用操作。
    public let generation: UUID

    /// 保存已注册端点。
    ///
    /// - Parameters:
    ///   - deviceID: 目标设备。
    ///   - provider: 推送提供方。
    ///   - environment: 运行环境。
    ///   - token: 提供方令牌明文。
    ///   - generation: 本次注册代次。
    public init(deviceID: DeviceID, provider: V2PushEndpointProvider, environment: V2PushEndpointEnvironment, token: String, generation: UUID) {
        self.deviceID = deviceID
        self.provider = provider
        self.environment = environment
        self.token = token
        self.generation = generation
    }
}

/// 推送端点错误。
public enum V2PushDeviceEndpointError: Error, Equatable, Sendable {
    /// 注册参数不合法。
    case invalidRegistration
    /// 目标设备当前不可用。
    case deviceUnavailable
    /// 依赖或密钥材料不可用。
    case unavailable
    /// 持久化记录缺失或无法解密。
    case malformedPersistence
    /// 需要携带意图版本才能执行该操作。
    case intentVersionRequired
    /// 意图版本已过期。
    case staleIntent
    /// 意图与当前状态冲突。
    case intentConflict
}

/// 推送端点的持久化能力。
public protocol V2PushDeviceEndpointStore: Sendable {
    /// 注册或更新设备的推送端点。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起注册的用户。
    ///   - deviceID: 目标设备。
    ///   - endpoint: 端点注册内容。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 设备不可用、意图冲突或持久化失败时抛出。
    func register(
        actorUserID: UserID,
        deviceID: DeviceID,
        endpoint: V2PushDeviceEndpointRegistration,
        now: Date
    ) async throws
    func endpoint(for deviceID: DeviceID) async throws -> V2PushDeviceEndpoint?
    func disable(_ endpoint: V2PushDeviceEndpoint, now: Date) async throws
    func disableOwnedEndpoint(
        actorUserID: UserID,
        deviceID: DeviceID,
        now: Date
    ) async throws
}

public extension V2PushDeviceEndpointStore {
    /// 删除某设备自有端点的兼容实现。
    ///
    /// 面向不具备原子身份感知更新的存储：先读取端点再停用它。
    /// PostgreSQL 实现会覆盖该方法，避免为用户主动删除而读取并解密提供方材料。
    ///
    /// - Parameters:
    ///   - deviceID: 目标设备。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 读取或停用失败时抛出。
    func disableOwnedEndpoint(
        actorUserID _: UserID,
        deviceID: DeviceID,
        now: Date
    ) async throws {
        if let endpoint = try await endpoint(for: deviceID) {
            try await disable(endpoint, now: now)
        }
    }
}

public enum V2PushEndpointIntent: Sendable {
    case enabled(V2PushDeviceEndpointRegistration)
    case disabled
}

/// 版本化 HTTP 契约所需的条件写能力。
///
/// 任期与修订本身不包含提供方令牌，也不授予任何认证权限。
public protocol V2PushEndpointIntentStoring: Sendable {
    func intentEpoch(actorUserID: UserID, deviceID: DeviceID) async throws -> UInt64
    func claimIntentSession(actorUserID: UserID, deviceID: DeviceID, claim: V2PushIntentSessionClaim, now: Date) async throws -> UInt64
    func publishIntent(actorUserID: UserID, deviceID: DeviceID, version: V2PushIntentVersion, intent: V2PushEndpointIntent, now: Date) async throws
}
