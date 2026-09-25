/// 有界的进程内观测数据。不导出房间、宿主或操作标识；
/// 各组件样本也不构成事务一致的快照。
public struct V2RoomRuntimeMetricsSnapshot: Equatable, Sendable {
    public let host: V2RoomActivationHostSnapshot?
    public let commands: V2RoomCommandBudgetSnapshot?
    public let cachedLocations: Int
    public let pendingResolutions: Int
    public let activeResolutions: Int
    public let resolutionWaiters: Int

    public init(host: V2RoomActivationHostSnapshot?, commands: V2RoomCommandBudgetSnapshot?,
                cachedLocations: Int, pendingResolutions: Int,
                activeResolutions: Int, resolutionWaiters: Int) {
        self.host = host
        self.commands = commands
        self.cachedLocations = cachedLocations
        self.pendingResolutions = pendingResolutions
        self.activeResolutions = activeResolutions
        self.resolutionWaiters = resolutionWaiters
    }
}

public protocol V2RoomRuntimeMetricsReading: Sendable {
    func roomRuntimeMetricsSnapshot() async -> V2RoomRuntimeMetricsSnapshot
}
