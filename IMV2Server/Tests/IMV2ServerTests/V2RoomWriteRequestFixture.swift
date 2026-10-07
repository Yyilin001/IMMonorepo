import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerInfrastructure

extension PostgresV2RoomWriteStore {
    /// Test convenience; calls the persistent boundary without a scheduling layer.
    func accept(_ request: V2RoomWriteRequest) async throws -> V2SendMessageOutcome {
        try await accept(command: request.command, capacityProfile: request.capacityProfile,
            identifiers: request.identifiers, now: request.now)
    }
}
