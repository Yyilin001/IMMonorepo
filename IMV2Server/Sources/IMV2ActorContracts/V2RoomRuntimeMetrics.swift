public struct V2RoomActivationHostSnapshot: Equatable, Sendable {
    public let accepting: Bool
    public let activeRooms: Int
    public let pendingRooms: Int
    public let activationWaiters: Int
    public let restoringRooms: Int
    public let retiringRooms: Int

    package init(accepting: Bool, activeRooms: Int, pendingRooms: Int, activationWaiters: Int, restoringRooms: Int, retiringRooms: Int) {
        self.accepting = accepting
        self.activeRooms = activeRooms
        self.pendingRooms = pendingRooms
        self.activationWaiters = activationWaiters
        self.restoringRooms = restoringRooms
        self.retiringRooms = retiringRooms
    }
}

public struct V2RoomCommandBudgetSnapshot: Equatable, Sendable {
    public let commandCount: Int
    public let byteCount: Int
    public let roomCount: Int
    public let reservationCount: Int
    public let peakCommandCount: Int
    public let peakByteCount: Int

    package init(commandCount: Int, byteCount: Int, roomCount: Int, reservationCount: Int, peakCommandCount: Int, peakByteCount: Int) {
        self.commandCount = commandCount
        self.byteCount = byteCount
        self.roomCount = roomCount
        self.reservationCount = reservationCount
        self.peakCommandCount = peakCommandCount
        self.peakByteCount = peakByteCount
    }
}

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
