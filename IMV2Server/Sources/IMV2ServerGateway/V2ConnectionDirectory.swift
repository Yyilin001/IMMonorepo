import Foundation
import IMV2Core
import IMV2ServerContracts

/// The sole local owner of authenticated connection identity and primary
/// indexes. Its containing actor supplies isolation; operations never suspend.
/// Subscription indexes belong to their respective subscription owner instead.
struct V2ConnectionDirectory: Sendable {
    struct Handle: Sendable {
        let connectionID: UUID
        let lifecycle: UInt64
        let identity: V2AuthenticatedConnection
        let stream: V2GatewayByteStream
    }

    private(set) var streamsByDevice: [DeviceID: [UUID: V2GatewayByteStream]] = [:]
    private(set) var streamsByUser: [UserID: [UUID: V2GatewayByteStream]] = [:]
    private(set) var identityByConnection: [UUID: V2AuthenticatedConnection] = [:]
    private(set) var lifecycleByConnection: [UUID: UInt64] = [:]
    private(set) var registrationTimes: [UUID: ContinuousClock.Instant] = [:]
    private(set) var journalInterests = V2GatewayJournalInterestIndex()
    // Actual SQL admission/renewal/removal and compensation ownership. Removal
    // of a connection does not release these slots or allow ID reuse.
    private(set) var connectionOperations: [UUID: Int] = [:]
    // Active identities and retired IDs with actual cleanup still owned.
    private(set) var occupiedConnections = 0
    private var retirementOperations: [UUID: UInt64] = [:]

    /// Reserves all local indexes before database admission. The caller must
    /// end the operation after actual admission AND compensation have settled.
    mutating func reserve(_ stream: V2GatewayByteStream, connectionID: UUID,
        identity: V2AuthenticatedConnection, lifecycle: UInt64,
        maximumConnections: Int, policy: V2AuthenticatedConnectionAdmissionPolicy) -> Bool {
        guard lifecycle > 0, occupiedConnections < maximumConnections,
              identityByConnection[connectionID] == nil, connectionOperations[connectionID] == nil,
              (streamsByDevice[identity.deviceID]?.count ?? 0) < policy.maximumConnectionsPerDevice,
              (streamsByUser[identity.userID]?.count ?? 0) < policy.maximumConnectionsPerUser else { return false }
        beginOperation(connectionID)
        lifecycleByConnection[connectionID] = lifecycle
        registrationTimes[connectionID] = .now
        identityByConnection[connectionID] = identity
        streamsByDevice[identity.deviceID, default: [:]][connectionID] = stream
        streamsByUser[identity.userID, default: [:]][connectionID] = stream
        journalInterests.insert(connection: connectionID, identity: identity, lifecycle: lifecycle)
        return true
    }

    func handle(_ connectionID: UUID) -> Handle? {
        guard let identity = identityByConnection[connectionID],
              let lifecycle = lifecycleByConnection[connectionID],
              let stream = streamsByUser[identity.userID]?[connectionID] else { return nil }
        return .init(connectionID: connectionID, lifecycle: lifecycle, identity: identity, stream: stream)
    }

    /// Exact local removal touches only the connection's user and device
    /// buckets. It deliberately preserves actual operation ownership.
    @discardableResult
    mutating func remove(_ connectionID: UUID, lifecycle: UInt64? = nil) -> Handle? {
        guard let current = handle(connectionID), lifecycle == nil || lifecycle == current.lifecycle else { return nil }
        beginOperation(connectionID)
        identityByConnection.removeValue(forKey: connectionID)
        lifecycleByConnection.removeValue(forKey: connectionID)
        registrationTimes.removeValue(forKey: connectionID)
        journalInterests.remove(connectionID)
        streamsByDevice[current.identity.deviceID]?.removeValue(forKey: connectionID)
        if streamsByDevice[current.identity.deviceID]?.isEmpty == true {
            streamsByDevice.removeValue(forKey: current.identity.deviceID)
        }
        streamsByUser[current.identity.userID]?.removeValue(forKey: connectionID)
        if streamsByUser[current.identity.userID]?.isEmpty == true {
            streamsByUser.removeValue(forKey: current.identity.userID)
        }
        return current
    }

    /// Reserves actual retired-writer ownership before its synchronous handoff.
    mutating func beginRetirementOperation(_ connectionID: UUID, lifecycle: UInt64) {
        precondition(lifecycle > 0 && retirementOperations[connectionID] == nil)
        precondition(identityByConnection[connectionID] == nil && connectionOperations[connectionID] != nil)
        retirementOperations[connectionID] = lifecycle
        beginOperation(connectionID)
    }

    mutating func endRetirementOperation(_ connectionID: UUID, lifecycle: UInt64) {
        precondition(retirementOperations[connectionID] == lifecycle)
        retirementOperations.removeValue(forKey: connectionID)
        endOperation(connectionID)
    }

    mutating func beginOperation(_ connectionID: UUID) {
        if identityByConnection[connectionID] == nil, connectionOperations[connectionID] == nil {
            occupiedConnections += 1
        }
        connectionOperations[connectionID, default: 0] += 1
    }

    mutating func endOperation(_ connectionID: UUID) {
        guard let count = connectionOperations[connectionID], count > 0 else {
            preconditionFailure("connection directory operation ownership")
        }
        if count == 1 {
            connectionOperations.removeValue(forKey: connectionID)
            if identityByConnection[connectionID] == nil { occupiedConnections -= 1 }
        }
        else { connectionOperations[connectionID] = count - 1 }
    }
}
