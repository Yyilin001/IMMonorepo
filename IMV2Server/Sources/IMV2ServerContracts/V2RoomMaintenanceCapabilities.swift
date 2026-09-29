import Foundation
import IMV2ActorContracts
import IMV2Core

/// Window mode releases readers after their grace window; permanent mode
/// includes all historical readers when choosing the trim floor.
public enum V2RoomLogRetentionMode: String, Equatable, Sendable {
    case window
    case permanent
}

package protocol V2RoomMaintenancePersisting: Sendable {
    func execute(_ command: V2RoomMaintenanceCommand,
                 token: V2RoomActivationToken, now: Date) async throws -> V2RoomMaintenanceResult
}

public enum V2RoomMaintenanceError: Error, Equatable, Sendable {
    case unexpectedResult
}

public protocol V2RoomMaintenanceScanning: Sendable {
    func retentionCandidates(limit: Int) async throws -> [RoomID]
    func bookkeepingCandidates(limit: Int) async throws -> [RoomID]
}

public protocol V2RoomMaintenanceInvoking: Sendable {
    func invoke(_ command: V2RoomMaintenanceCommand,
                deadline: ContinuousClock.Instant) async throws -> V2RoomMaintenanceResult
}

public struct V2RoomActorMaintenanceReport: Equatable, Sendable {
    public let scannedRooms: Int
    public let advancedFloors: Int
    public let deletedEvents: Int
    public let deletedReviewJobs: Int
    public let deletedOperationRows: Int

    public init(scannedRooms: Int, advancedFloors: Int = 0, deletedEvents: Int = 0,
                deletedReviewJobs: Int = 0, deletedOperationRows: Int = 0) {
        self.scannedRooms = scannedRooms
        self.advancedFloors = advancedFloors
        self.deletedEvents = deletedEvents
        self.deletedReviewJobs = deletedReviewJobs
        self.deletedOperationRows = deletedOperationRows
    }
}
