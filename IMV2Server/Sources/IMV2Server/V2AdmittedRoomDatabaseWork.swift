import Foundation
import IMV2ActorContracts

/// Acquires only at the physical SQL boundary. A Gateway or Account caller
/// never holds this permit while waiting for a RoomRef or a room reservation.
func v2WithAdmittedRoomDatabaseWork<Value: Sendable>(
    _ admission: V2DatabaseWorkAdmissionController?,
    workClass: V2DatabaseWorkClass,
    callerDeadline: ContinuousClock.Instant,
    operation: @Sendable () async throws -> Value
) async throws -> Value {
    try Task.checkCancellation()
    guard callerDeadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
    guard let admission else { return try await operation() }
    switch await admission.acquire(workClass, callerDeadline: callerDeadline) {
    case .rejected(.queueFull): throw V2RoomCallFailure.notAccepted(.overloaded)
    case .rejected(.timeout):
        throw V2RoomCallFailure.notAccepted(callerDeadline <= .now ? .deadlineExceeded : .overloaded)
    case .cancelled: throw V2RoomCallFailure.notAccepted(.cancelled)
    case .admitted: break
    }
    do {
        try Task.checkCancellation()
        guard callerDeadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        let value = try await operation()
        await admission.release(workClass)
        return value
    } catch {
        await admission.release(workClass)
        throw error
    }
}
