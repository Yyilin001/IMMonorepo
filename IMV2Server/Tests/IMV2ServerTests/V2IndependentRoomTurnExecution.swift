import Foundation
import IMV2ActorContracts
import IMV2ServerApplication
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure

// Test orchestration only: each handle has its own transaction and failure.
// This deliberately offers no production cross-room batching entry point.
extension PostgresV2MessageSendOperationStore {
    func executeIndependentRoomTurns(_ turns: [V2PreparedMessageSendBatch],
        capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIDFactory,
        now: @escaping @Sendable () -> Date
    ) async throws -> [Result<[V2RoomMessagingResult], any Error>] {
        let rooms = Dictionary(grouping: turns.enumerated().map { ($0.offset, $0.element) },
            by: { $0.1.activationToken.roomID })
        return await withTaskGroup(of: [(Int, Result<[V2RoomMessagingResult], any Error>)].self) { group in
            for roomTurns in rooms.values {
                group.addTask {
                    var values: [(Int, Result<[V2RoomMessagingResult], any Error>)] = []
                    for (index, turn) in roomTurns {
                        do { values.append((index, .success(try await self.executePreparedRoomSend(turn,
                            capacityProfile: capacityProfile, identifiers: identifiers, now: now)))) }
                        catch { values.append((index, .failure(error))) }
                    }
                    return values
                }
            }
            var results: [(Int, Result<[V2RoomMessagingResult], any Error>)] = []
            for await values in group { results += values }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    func executeIndependentRoomTurnsPreborrowing(_ turns: [V2PreparedMessageSendBatch],
        capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIDFactory,
        now: @escaping @Sendable () -> Date, control: V2OwnerBatchBorrowControl
    ) async throws -> [Result<[V2RoomMessagingResult], any Error>] {
        let rooms = Dictionary(grouping: turns.enumerated().map { ($0.offset, $0.element) },
            by: { $0.1.activationToken.roomID })
        return await withTaskGroup(of: [(Int, Result<[V2RoomMessagingResult], any Error>)].self) { group in
            for roomTurns in rooms.values {
                group.addTask {
                    var values: [(Int, Result<[V2RoomMessagingResult], any Error>)] = []
                    for (index, turn) in roomTurns {
                        do { values.append((index, .success(try await self.executePreparedRoomSendPreborrowing(turn,
                            capacityProfile: capacityProfile, identifiers: identifiers, now: now, control: control)))) }
                        catch { values.append((index, .failure(error))) }
                    }
                    return values
                }
            }
            var results: [(Int, Result<[V2RoomMessagingResult], any Error>)] = []
            for await values in group { results += values }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
}
