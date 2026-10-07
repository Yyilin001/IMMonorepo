import Foundation

/// 单条连接允许同时占用的请求关联数量上限。
public struct V2ConnectionLimits: Equatable, Sendable {
    /// 认证及业务请求共同受此并发槽位上限约束；必须为正。
    public let maximumInFlightRequests: Int
    /// 验证并发请求容量。
    ///
    /// - Parameter maximumInFlightRequests: 大于零的最大在途请求数。
    /// - Throws: 非正值抛出 invalidLimits。
    public init(maximumInFlightRequests: Int) throws {
        guard maximumInFlightRequests > 0 else { throw V2ConnectionStateError.invalidLimits }
        self.maximumInFlightRequests = maximumInFlightRequests
    }
}

/// 可信认证层交给连接状态机的用户、设备及能力身份。
///
/// 构造器只保存值，不验证 token，也不检查 capabilityProfile 是否属于允许集合。
public struct V2AuthenticatedConnection: Equatable, Sendable {
    /// 认证层确认的账号身份，不应由未认证请求的 sender 字段直接提供。
    public let userID: UserID
    /// 当前连接已认证的设备身份。
    public let deviceID: DeviceID
    /// 认证前协商的能力 profile，领域处理器据此选择设备可解释的同步表示。
    public let capabilityProfile: String
    /// Device control cut read atomically with credential authentication.
    /// Later control snapshots compare versions instead of rereading credentials.
    public let credentialControlVersion: Int64
    /// 组合认证层已确认的连接身份。
    ///
    /// - Parameters:
    ///   - userID: 账号身份。
    ///   - deviceID: 该会话设备身份。
    ///   - capabilityProfile: 已协商并由调用者验证的能力 profile。
    public init(userID: UserID, deviceID: DeviceID, capabilityProfile: String, credentialControlVersion: Int64 = 0) {
        self.userID = userID
        self.deviceID = deviceID
        self.capabilityProfile = capabilityProfile
        self.credentialControlVersion = credentialControlVersion
    }
}

/// 一条连接从 TLS 建立到协议协商、认证与终止的互斥状态。
public enum V2ConnectionPhase: Equatable, Sendable {
    /// TLS 已建立，尚未接受 ClientHello。
    case tlsConnected
    /// 已选定双方共同支持的最高版本，等待 Authenticate。
    case versionNegotiated(UInt8)
    /// 认证处理中，携带所选版本和已保留的认证请求 ID。
    case awaitingAuthentication(UInt8, requestID: UInt64)
    /// 认证完成，可按所选版本接收后续业务请求。
    case authenticated(UInt8, V2AuthenticatedConnection)
    /// 设备已撤销，正在由外层关闭传输，不再接受新业务。
    case closing
    /// 本连接状态已终止，所有在途请求关联已清除。
    case closed
}

/// 连接阶段、版本、请求身份或容量不符合状态机约束。
public enum V2ConnectionStateError: Error, Equatable, Sendable {
    case invalidLimits, unexpectedCommand, bootstrapVersionMustBeZero, unsupportedVersion
    case requestIDMustBeNonZero, duplicateRequestID, tooManyInFlightRequests, responseWasNotInFlight
}

/// 传输无关的单连接生命周期与请求 ID 栅栏。
///
/// 本值不持有 socket、不解析凭据、也不执行业务授权。可变状态应由连接 actor 或
/// 其他明确串行边界独占；Sendable 允许传递值，不意味着共享可变访问自动安全。
public struct V2ConnectionStateMachine: Sendable {
    /// 当前互斥阶段，只能通过状态机操作改变。
    public private(set) var phase: V2ConnectionPhase = .tlsConnected
    /// 尚未完成响应的请求身份集合，认证请求也占用其中一个槽位。
    public private(set) var inFlightRequestIDs: Set<UInt64> = []
    private let limits: V2ConnectionLimits

    /// 创建处于 tlsConnected 阶段且无在途请求的状态机。
    public init(limits: V2ConnectionLimits) { self.limits = limits }

    /// 验证初始 Hello，并选择双方共同支持的最高版本。
    ///
    /// - Parameters:
    ///   - frame: 必须为版本零、非零 requestID 的 clientHello。
    ///   - clientSupportedVersions: 从 Hello 解析并交由上层校验的客户端版本集合。
    ///   - serverSupportedVersions: 服务端启用的版本集合。
    /// - Returns: 双方版本交集中的最大值。
    /// - Throws: 非初始阶段、非法 bootstrap 帧、零请求 ID 或无共同版本。
    ///
    /// 此方法不为 Hello 保留在途槽位；成功后进入 versionNegotiated。
    public mutating func receiveClientHello(_ frame: V2Frame, clientSupportedVersions: Set<UInt8>, serverSupportedVersions: Set<UInt8>) throws -> UInt8 {
        guard phase == .tlsConnected else { throw V2ConnectionStateError.unexpectedCommand }
        guard frame.command == .clientHello, frame.version == 0 else { throw V2ConnectionStateError.bootstrapVersionMustBeZero }
        guard frame.requestID != 0 else { throw V2ConnectionStateError.requestIDMustBeNonZero }
        guard let selected = clientSupportedVersions.intersection(serverSupportedVersions).max() else { throw V2ConnectionStateError.unsupportedVersion }
        phase = .versionNegotiated(selected)
        return selected
    }

    /// 保留认证请求 ID 并进入等待认证结果阶段。
    ///
    /// - Parameter frame: 使用已协商版本的 authenticate 帧。
    /// - Throws: 阶段／命令／版本不符，或请求 ID、并发槽位检查失败。
    ///
    /// 凭据验证由外部执行，成功后再调用 completeAuthentication。
    public mutating func receiveAuthenticate(_ frame: V2Frame) throws {
        guard case .versionNegotiated(let version) = phase, frame.command == .authenticate, frame.version == version else { throw V2ConnectionStateError.unexpectedCommand }
        try reserve(frame.requestID)
        phase = .awaitingAuthentication(version, requestID: frame.requestID)
    }

    /// 提交可信认证结果，释放认证槽位并进入 authenticated 阶段。
    ///
    /// - Parameter identity: 外部认证器已验证的账号、设备及能力身份。
    /// - Throws: 当前不是 awaitingAuthentication 时抛出 unexpectedCommand。
    public mutating func completeAuthentication(_ identity: V2AuthenticatedConnection) throws {
        guard case .awaitingAuthentication(let version, let requestID) = phase else { throw V2ConnectionStateError.unexpectedCommand }
        inFlightRequestIDs.remove(requestID)
        phase = .authenticated(version, identity)
    }

    /// 为已认证阶段的后续请求保留关联槽位。
    ///
    /// - Parameter frame: 使用协商版本、不是 Hello 或 Authenticate 的请求帧。
    /// - Throws: 状态／版本不符，零 ID、重复 ID 或在途容量耗尽。
    ///
    /// 该检查不提供命令白名单或业务授权；未知命令仍需由协议处理器拒绝。
    public mutating func receiveAuthenticatedRequest(_ frame: V2Frame) throws {
        guard case .authenticated(let version, _) = phase, frame.version == version,
              frame.command != .clientHello, frame.command != .authenticate else { throw V2ConnectionStateError.unexpectedCommand }
        try reserve(frame.requestID)
    }

    /// 响应完成后释放对应请求关联。
    ///
    /// - Parameter requestID: 必须仍在在途集合中的请求 ID。
    /// - Throws: 关联不存在时抛出 responseWasNotInFlight，不能重复释放。
    ///
    /// 响应是否已实际写入 socket 由调用层决定；此方法只推进内存状态。
    public mutating func completeResponse(requestID: UInt64) throws {
        guard inFlightRequestIDs.remove(requestID) != nil else { throw V2ConnectionStateError.responseWasNotInFlight }
    }

    /// 清空在途请求并进入 closing；外层负责通知、取消工作和真正关闭 socket。
    public mutating func revokeDevice() { inFlightRequestIDs.removeAll(); phase = .closing }
    /// 清空在途请求并进入 closed；可重复调用，不执行网络资源操作。
    public mutating func close() { inFlightRequestIDs.removeAll(); phase = .closed }

    /// 按非零、未占用、容量未耗尽的顺序验证请求 ID，全部通过后才插入集合。
    private mutating func reserve(_ requestID: UInt64) throws {
        guard requestID != 0 else { throw V2ConnectionStateError.requestIDMustBeNonZero }
        guard !inFlightRequestIDs.contains(requestID) else { throw V2ConnectionStateError.duplicateRequestID }
        guard inFlightRequestIDs.count < limits.maximumInFlightRequests else { throw V2ConnectionStateError.tooManyInFlightRequests }
        inFlightRequestIDs.insert(requestID)
    }
}
