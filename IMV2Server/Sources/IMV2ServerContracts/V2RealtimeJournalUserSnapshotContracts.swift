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

public protocol V2RealtimeJournalPublisherLeaseReading: Sendable {
    /// Read the source database's actual publisher authority, sampling its clock.
    /// Caller deducts the full request duration before deriving a local deadline.
    func currentPublisherLease(partitionID: Int) async throws -> V2RealtimePartitionLease?
}
