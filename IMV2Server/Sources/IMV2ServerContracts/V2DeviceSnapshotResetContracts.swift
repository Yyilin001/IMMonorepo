import Foundation
import IMV2Core

/// 一次运维授权的重置请求。
///
/// 操作 UUID 同时是不可变产物标识，因此请求重试会收敛到同一次持久化构建，
/// 不会产生多份互不相同的快照产物。
public struct V2DeviceSnapshotResetCommand: Sendable {
    /// 本次重置的幂等操作标识。
    public let operationID: UUID
    /// 目标用户。
    public let userID: UserID
    /// 目标设备。
    public let deviceID: DeviceID

    /// 保存重置请求。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识。
    ///   - userID: 目标用户。
    ///   - deviceID: 目标设备。
    public init(operationID: UUID, userID: UserID, deviceID: DeviceID) {
        self.operationID = operationID
        self.userID = userID
        self.deviceID = deviceID
    }
}

/// 设备快照重置的构建状态。
public enum V2DeviceSnapshotResetBuildState: String, Codable, Equatable, Sendable {
    /// 产物仍在构建中。
    case preparing
    /// 产物已可被设备拉取。
    case ready
}

/// 设备快照重置结果。
public struct V2DeviceSnapshotResetResult: Equatable, Sendable {
    /// 重置后的同步代次。
    public let generation: UInt64
    /// 产物当前构建状态。
    public let state: V2DeviceSnapshotResetBuildState
    /// 本次调用是否命中既有结果。
    public let wasIdempotent: Bool

    /// 保存重置结果。
    ///
    /// - Parameters:
    ///   - generation: 同步代次。
    ///   - state: 构建状态。
    ///   - wasIdempotent: 是否命中既有结果。
    public init(generation: UInt64, state: V2DeviceSnapshotResetBuildState, wasIdempotent: Bool) {
        self.generation = generation; self.state = state; self.wasIdempotent = wasIdempotent
    }
}

/// 设备快照重置错误。
public enum V2DeviceSnapshotResetError: Error, Equatable, Sendable {
    /// 目标设备当前不可用。
    case deviceUnavailable
    /// 该设备已有待处理的重置。
    case resetAlreadyPending
    /// 持久化状态与预期结构不符。
    case malformedPersistence
    /// 依赖当前不可用。
    case unavailable
}

/// 设备快照重置的暂存能力。
public protocol V2DeviceSnapshotResetting: Sendable {
    /// 暂存一次设备快照重置。
    ///
    /// - Parameter command: 重置请求。
    /// - Returns: 重置结果。
    /// - Throws: 设备不可用、已有待处理重置或持久化失败时抛出。
    func stage(_ command: V2DeviceSnapshotResetCommand) async throws -> V2DeviceSnapshotResetResult
}

/// 设备可用性检查能力。
///
/// 设备凭据属于控制面权威，绝不能从用户投影分片推断；独立的用户分片库刻意不复制
/// `auth_devices`，因此该检查必须走控制面。
public protocol V2DeviceAvailabilityChecking: Sendable {
    /// 判断指定设备当前是否可用。
    ///
    /// - Parameters:
    ///   - userID: 设备归属用户。
    ///   - deviceID: 目标设备。
    /// - Returns: 设备未吊销且会话有效时为 `true`。
    /// - Throws: 存储不可用时抛出。
    func isAvailable(userID: UserID, deviceID: DeviceID) async throws -> Bool
}
