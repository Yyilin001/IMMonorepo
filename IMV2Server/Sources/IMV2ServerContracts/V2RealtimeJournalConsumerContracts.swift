import Foundation
import IMV2ActorContracts

public struct V2RealtimeJournalDeviceKey: Codable, Hashable, Sendable {
    public let userID: UUID
    public let deviceID: UUID
    public init(userID: UUID, deviceID: UUID) { self.userID = userID; self.deviceID = deviceID }
}
public struct V2RealtimeJournalUserControl: Codable, Equatable, Sendable {
    public let userID: UUID
    public let controlVersion: Int64
    public let membershipDiscoveryVersion: Int64
    public let sessionControlVersion: Int64
    public init(userID: UUID, controlVersion: Int64, membershipDiscoveryVersion: Int64, sessionControlVersion: Int64) {
        self.userID = userID; self.controlVersion = controlVersion
        self.membershipDiscoveryVersion = membershipDiscoveryVersion; self.sessionControlVersion = sessionControlVersion
    }
}
public struct V2RealtimeJournalDeviceControl: Codable, Equatable, Sendable {
    public let userID: UUID
    public let deviceID: UUID
    public let latestChangeVersion: Int64
    public init(userID: UUID, deviceID: UUID, latestChangeVersion: Int64) {
        self.userID = userID; self.deviceID = deviceID; self.latestChangeVersion = latestChangeVersion
    }
}
/// Complete requested users/devices and their control floors share the journal
/// cut's MVCC snapshot. Membership versions signal discovery; they grant nothing.
public struct V2RealtimeJournalUserSnapshot: Codable, Equatable, Sendable {
    public let identity: V2RealtimeJournalSourceIdentity
    public let observedAt: Date
    public let cuts: [V2RealtimeJournalPartitionCut]
    public let requestedUserIDs: [UUID]
    public let requestedDeviceKeys: [V2RealtimeJournalDeviceKey]
    public let users: [V2RealtimeJournalUserControl]
    public let devices: [V2RealtimeJournalDeviceControl]
    public init(identity: V2RealtimeJournalSourceIdentity, observedAt: Date, cuts: [V2RealtimeJournalPartitionCut],
                requestedUserIDs: [UUID], requestedDeviceKeys: [V2RealtimeJournalDeviceKey],
                users: [V2RealtimeJournalUserControl], devices: [V2RealtimeJournalDeviceControl]) {
        self.identity = identity; self.observedAt = observedAt; self.cuts = cuts
        self.requestedUserIDs = requestedUserIDs; self.requestedDeviceKeys = requestedDeviceKeys
        self.users = users; self.devices = devices
    }
}
public protocol V2RealtimeJournalUserSnapshotStore: Sendable {
    func userSnapshot(userIDs: [UUID], deviceIDs: [V2RealtimeJournalDeviceKey], partitionIDs: [Int],
                      minimumPublishedThrough: [Int: Int64]) async throws -> V2RealtimeJournalUserSnapshot
}

public struct V2RealtimeJournalConsumerKey: Codable, Hashable, Sendable {
    public let gateway: V2GatewayRealtimeIdentity
    public let sessionID: UUID
    public let sessionRevision: Int64
    public init(gateway: V2GatewayRealtimeIdentity, sessionID: UUID, sessionRevision: Int64) {
        self.gateway = gateway; self.sessionID = sessionID; self.sessionRevision = sessionRevision
    }
}
/// Coverage expiry comes from the trusted routing observer, never a remote
/// subscription request. The observer must deduct request time conservatively.
public struct V2RealtimeJournalConsumerRegistration: Codable, Equatable, Sendable {
    public let key: V2RealtimeJournalConsumerKey
    public let sessionGeneration: Int64
    public let partitionID: Int
    public let roomIDs: [UUID]
    public let userIDs: [UUID]
    public let routingEpoch: Int64
    public let routingToken: UUID
    public let coverageExpiresAt: Date
    public let initialControlCursor: Int64
    public init(key: V2RealtimeJournalConsumerKey, sessionGeneration: Int64 = 1, partitionID: Int, roomIDs: [UUID], userIDs: [UUID],
                routingEpoch: Int64, routingToken: UUID, coverageExpiresAt: Date, initialControlCursor: Int64 = 0) {
        self.key = key; self.sessionGeneration = sessionGeneration; self.partitionID = partitionID; self.roomIDs = roomIDs; self.userIDs = userIDs
        self.routingEpoch = routingEpoch; self.routingToken = routingToken
        self.coverageExpiresAt = coverageExpiresAt; self.initialControlCursor = initialControlCursor
    }
}
public struct V2RealtimeJournalConsumerBatch: Codable, Equatable, Sendable {
    public let registration: V2RealtimeJournalConsumerRegistration
    public let controlCursor: Int64
    public let offeredThrough: Int64
    public let journal: V2RealtimeJournalBatch
    public let heads: [V2RealtimeRoomHeadChange]
    public init(registration: V2RealtimeJournalConsumerRegistration, controlCursor: Int64, offeredThrough: Int64,
                journal: V2RealtimeJournalBatch, heads: [V2RealtimeRoomHeadChange]) {
        self.registration = registration; self.controlCursor = controlCursor
        self.offeredThrough = offeredThrough; self.journal = journal; self.heads = heads
    }
}
public protocol V2RealtimeJournalConsumerStore: Sendable {
    func pendingConsumerPartitions(partitionIDs: [Int], limit: Int) async throws -> [Int]
    func registerConsumer(lease: V2RealtimePartitionLease, registration: V2RealtimeJournalConsumerRegistration) async throws
    func registeredConsumers(lease: V2RealtimePartitionLease, afterGatewayIncarnation: UUID?, limit: Int) async throws -> [V2RealtimeJournalConsumerRegistration]
    /// Atomically persist recipient responsibility before CAS-clearing source H.
    /// Control data stays in the shared journal; only recipient offer cursors
    /// and latest heads are copied. This commit never waits for network delivery.
    func handoffToConsumers(lease: V2RealtimePartitionLease, throughControlSequence: Int64,
                            heads: [V2RealtimeRoomHeadChange]) async throws
    func consumerBatch(lease: V2RealtimePartitionLease, consumer: V2RealtimeJournalConsumerKey,
                       limit: Int) async throws -> V2RealtimeJournalConsumerBatch
    func acknowledgeConsumer(lease: V2RealtimePartitionLease, consumer: V2RealtimeJournalConsumerKey,
                             expectedControlCursor: Int64, appliedThrough: Int64,
                             heads: [V2RealtimeRoomHeadChange]) async throws -> Bool
    /// Caller has independently observed the exact routing coverage's monotonic
    /// deadline expire. Stored epoch/token/expiry and the DB clock also match;
    /// ordinary polling must not retire consumers solely on wall clock expiry.
    func retireExpiredConsumer(lease: V2RealtimePartitionLease, consumer: V2RealtimeJournalConsumerKey,
                              expectedRoutingEpoch: Int64, expectedRoutingToken: UUID,
                              expectedCoverageExpiresAt: Date) async throws -> Bool
}

public protocol V2RealtimeJournalPublisherLeaseReading: Sendable {
    /// Read the source database's actual publisher authority, sampling its clock.
    /// Caller deducts the full request duration before deriving a local deadline.
    func currentPublisherLease(partitionID: Int) async throws -> V2RealtimePartitionLease?
}
