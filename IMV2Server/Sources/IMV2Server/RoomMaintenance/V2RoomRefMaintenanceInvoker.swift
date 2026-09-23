import IMV2ActorContracts
import IMV2ActorRuntime

/// Worker scans supply hints; every mutation obtains a fresh logical room turn
/// with the service's explicitly configured maintenance permission.
public struct V2RoomRefMaintenanceInvoker: V2RoomMaintenanceInvoking {
    private let directory: V2RoomDirectory

    public init(directory: V2RoomDirectory) { self.directory = directory }

    public func invoke(_ command: V2RoomMaintenanceCommand,
                       deadline: ContinuousClock.Instant) async throws -> V2RoomMaintenanceResult {
        let response = try await directory.room(command.roomID).call(.maintenance(command),
            principal: .service, deadline: deadline)
        guard case .maintenance(let result) = response else { throw V2RoomCallFailure.outcomeUnknown }
        return result
    }
}
