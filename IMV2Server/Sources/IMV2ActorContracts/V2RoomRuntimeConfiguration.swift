/// 有界调度配置。默认值只是工程起始上限，并不代表生产容量承诺；
/// 运维人员可在测量后下调。
public struct V2RoomRuntimeConfiguration: Equatable, Sendable {
    public let maximumActiveRooms: Int
    public let maximumConcurrentRestores: Int
    public let maximumActivationWaitersPerRoom: Int
    public let maximumPendingActivations: Int
    public let maximumActivationWaitersPerHost: Int
    public let maximumConcurrentResolutions: Int
    public let maximumCachedLocations: Int
    public let maximumQueuedCommandsPerRoom: Int
    public let maximumQueuedBytesPerRoom: Int
    public let maximumQueuedCommandsPerHost: Int
    public let maximumQueuedBytesPerHost: Int
    public let maximumRequestBytes: Int
    public let maximumCommandsPerTurn: Int
    public let maximumBytesPerTurn: Int
    public let maximumConcurrentReservations: Int
    public let maximumResolveAttempts: Int
    public let leaseDuration: V2ActorMilliseconds
    public let renewalInterval: V2ActorMilliseconds
    public let renewalSafetyMargin: V2ActorMilliseconds
    public let transactionTimeout: V2ActorMilliseconds
    public let callTimeout: V2ActorMilliseconds
    public let batchWait: V2ActorMilliseconds
    public let idleTimeout: V2ActorMilliseconds
    public let drainTimeout: V2ActorMilliseconds
    public let reservationTimeout: V2ActorMilliseconds

    public init(
        maximumActiveRooms: Int = 10_000,
        maximumConcurrentRestores: Int = 32,
        maximumActivationWaitersPerRoom: Int = 256,
        maximumPendingActivations: Int = 1_024,
        maximumActivationWaitersPerHost: Int = 4_096,
        maximumConcurrentResolutions: Int = 128,
        maximumCachedLocations: Int = 20_000,
        maximumQueuedCommandsPerRoom: Int = 256,
        maximumQueuedBytesPerRoom: Int = 4 * 1_024 * 1_024,
        maximumQueuedCommandsPerHost: Int = 32_768,
        maximumQueuedBytesPerHost: Int = 128 * 1_024 * 1_024,
        maximumRequestBytes: Int = 1_024 * 1_024,
        maximumCommandsPerTurn: Int = 64,
        maximumBytesPerTurn: Int = 4 * 1_024 * 1_024,
        maximumConcurrentReservations: Int = 128,
        maximumResolveAttempts: Int = 3,
        leaseDurationMilliseconds: Int64 = 30_000,
        renewalIntervalMilliseconds: Int64 = 5_000,
        renewalSafetyMarginMilliseconds: Int64 = 2_000,
        transactionTimeoutMilliseconds: Int64 = 10_000,
        callTimeoutMilliseconds: Int64 = 30_000,
        batchWaitMilliseconds: Int64 = 2,
        idleTimeoutMilliseconds: Int64 = 300_000,
        drainTimeoutMilliseconds: Int64 = 60_000,
        reservationTimeoutMilliseconds: Int64 = 15_000
    ) throws {
        let limits = [
            ("maximumActiveRooms", maximumActiveRooms),
            ("maximumConcurrentRestores", maximumConcurrentRestores),
            ("maximumActivationWaitersPerRoom", maximumActivationWaitersPerRoom),
            ("maximumPendingActivations", maximumPendingActivations),
            ("maximumActivationWaitersPerHost", maximumActivationWaitersPerHost),
            ("maximumConcurrentResolutions", maximumConcurrentResolutions),
            ("maximumCachedLocations", maximumCachedLocations),
            ("maximumQueuedCommandsPerRoom", maximumQueuedCommandsPerRoom),
            ("maximumQueuedBytesPerRoom", maximumQueuedBytesPerRoom),
            ("maximumQueuedCommandsPerHost", maximumQueuedCommandsPerHost),
            ("maximumQueuedBytesPerHost", maximumQueuedBytesPerHost),
            ("maximumRequestBytes", maximumRequestBytes),
            ("maximumCommandsPerTurn", maximumCommandsPerTurn),
            ("maximumBytesPerTurn", maximumBytesPerTurn),
            ("maximumConcurrentReservations", maximumConcurrentReservations),
            ("maximumResolveAttempts", maximumResolveAttempts),
        ]
        for (name, value) in limits where value <= 0 {
            throw V2ActorContractError.invalidConfiguration(name)
        }
        guard maximumConcurrentRestores <= maximumActiveRooms,
              maximumConcurrentRestores <= maximumPendingActivations,
              maximumPendingActivations <= maximumActivationWaitersPerHost,
              maximumActivationWaitersPerRoom <= maximumActivationWaitersPerHost,
              maximumConcurrentResolutions <= maximumActivationWaitersPerHost,
              maximumQueuedCommandsPerRoom <= maximumQueuedCommandsPerHost,
              maximumQueuedBytesPerRoom <= maximumQueuedBytesPerHost,
              maximumRequestBytes <= maximumQueuedBytesPerRoom,
              maximumRequestBytes <= maximumBytesPerTurn,
              maximumCommandsPerTurn <= maximumQueuedCommandsPerRoom,
              maximumBytesPerTurn <= maximumQueuedBytesPerRoom,
              maximumConcurrentReservations <= maximumActiveRooms,
              maximumResolveAttempts <= 16
        else { throw V2ActorContractError.invalidConfiguration("capacityRelationships") }

        let lease = try V2ActorMilliseconds(leaseDurationMilliseconds)
        let renewal = try V2ActorMilliseconds(renewalIntervalMilliseconds)
        let margin = try V2ActorMilliseconds(renewalSafetyMarginMilliseconds)
        let transaction = try V2ActorMilliseconds(transactionTimeoutMilliseconds)
        let call = try V2ActorMilliseconds(callTimeoutMilliseconds)
        let batch = try V2ActorMilliseconds(batchWaitMilliseconds)
        let idle = try V2ActorMilliseconds(idleTimeoutMilliseconds)
        let drain = try V2ActorMilliseconds(drainTimeoutMilliseconds)
        let reservation = try V2ActorMilliseconds(reservationTimeoutMilliseconds)
        guard renewal.rawValue + margin.rawValue < lease.rawValue,
              transaction.rawValue + margin.rawValue < lease.rawValue,
              batch < transaction, transaction <= call,
              transaction <= reservation, reservation <= call, call <= drain
        else { throw V2ActorContractError.invalidConfiguration("timeRelationships") }

        self.maximumActiveRooms = maximumActiveRooms
        self.maximumConcurrentRestores = maximumConcurrentRestores
        self.maximumActivationWaitersPerRoom = maximumActivationWaitersPerRoom
        self.maximumPendingActivations = maximumPendingActivations
        self.maximumActivationWaitersPerHost = maximumActivationWaitersPerHost
        self.maximumConcurrentResolutions = maximumConcurrentResolutions
        self.maximumCachedLocations = maximumCachedLocations
        self.maximumQueuedCommandsPerRoom = maximumQueuedCommandsPerRoom
        self.maximumQueuedBytesPerRoom = maximumQueuedBytesPerRoom
        self.maximumQueuedCommandsPerHost = maximumQueuedCommandsPerHost
        self.maximumQueuedBytesPerHost = maximumQueuedBytesPerHost
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumCommandsPerTurn = maximumCommandsPerTurn
        self.maximumBytesPerTurn = maximumBytesPerTurn
        self.maximumConcurrentReservations = maximumConcurrentReservations
        self.maximumResolveAttempts = maximumResolveAttempts
        self.leaseDuration = lease
        self.renewalInterval = renewal
        self.renewalSafetyMargin = margin
        self.transactionTimeout = transaction
        self.callTimeout = call
        self.batchWait = batch
        self.idleTimeout = idle
        self.drainTimeout = drain
        self.reservationTimeout = reservation
    }
}
