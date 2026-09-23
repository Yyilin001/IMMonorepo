import IMV2Core

public enum V2RoomActivationAcquisition: Equatable, Sendable {
    /// A newly committed epoch. The host still has to restore before ready.
    case acquired(V2RoomActivationLease)
    /// Another valid grant exists, including a grant to this host's incarnation.
    case occupied(V2RoomActivationLease)
}

public enum V2RoomActivationLeaseError: Error, Equatable, Sendable {
    case roomNotFound
    case ownerChanged
    case activationChanged
    case leaseExpired
    case epochExhausted
    /// The database may have committed a new lease, but no token was returned.
    /// Callers must locate the fence again; they cannot claim rollback.
    case outcomeUnknown
}

/// The actual room database is the sole authority for activation placement.
///
/// Implementations acquire the room fence before reading the current database
/// clock. They preserve the epoch counter after release and hold the same fence
/// used by business writes until their own transaction commits.
public protocol V2RoomActivationLeaseStore: Sendable {
    /// Returns only a lease still valid at the database observation time.
    func locate(roomID: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationLease?

    /// Never steals an unexpired lease because discovery or RPC has failed.
    func acquire(
        roomID: RoomID,
        owner: V2RoomDataOwner,
        host: V2ActorHostIdentity,
        duration: V2ActorMilliseconds
    ) async throws -> V2RoomActivationAcquisition

    /// A matching but expired token must acquire a new epoch instead of renew.
    func renew(
        token: V2RoomActivationToken,
        duration: V2ActorMilliseconds
    ) async throws -> V2RoomActivationLease

    /// False means this token no longer owns the lease. Never releases a successor.
    func release(token: V2RoomActivationToken) async throws -> Bool
}

/// Data-owner lookups stay behind the runtime; callers only provide RoomID.
public protocol V2RoomDataOwnerResolving: Sendable {
    func owner(for roomID: RoomID) async throws -> V2RoomDataOwner
}

public enum V2RoomActivationPhase: String, Codable, Sendable {
    case acquiring
    case restoring
    case ready
    case draining
    case uncertain
    case stopped
}
