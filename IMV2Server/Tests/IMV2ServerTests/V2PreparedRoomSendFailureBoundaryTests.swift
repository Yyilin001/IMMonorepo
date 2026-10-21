import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Testing

@Suite("Message preparation failures do not imply an uncertain business write")
struct V2PreparedRoomSendFailureBoundaryTests {
    private struct TransportUnavailable: Error {}

    @Test("preparation failure releases the turn and lets the same room accept its successor")
    func preparationFailureKeepsRoomReady() async throws {
        let configuration = try V2RoomRuntimeConfiguration()
        let budget = V2RoomCommandBudget(configuration: configuration)
        let lane = V2RoomTurnLane<Int, Int>(
            token: .init(roomID: RoomID(uuid: UUID()), owner: try .init(shardID: "test", epoch: 0),
                activationEpoch: try .init(1),
                host: .init(hostID: V2ActorHostID(uuid: UUID()), incarnationID: UUID())),
            configuration: configuration, budget: budget, classify: { _ in .barrier },
            execute: { turn in
                do {
                    _ = try await v2ExecutePreparedRoomSendOperationBatch {
                        if turn.items.first?.request == 0 { throw TransportUnavailable() }
                        return .init { [] }
                    }
                    return .committed(turn.items.map(\.request))
                } catch { return v2RoomDomainCompletion(error) }
            },
            onUncertain: { _ in Issue.record("preparation failure must not retire the room") })
        await #expect(throws: V2RoomCallFailure.rolledBack(.unavailable)) {
            try await lane.submit(request: 0, deadline: .now + .seconds(5))
        }
        #expect(await lane.snapshot().phase == .ready)
        #expect(await lane.snapshot().unresolvedCount == 0)
        #expect(budget.snapshot().commandCount == 0)
        #expect(try await lane.submit(request: 1, deadline: .now + .seconds(5)) == 1)
        #expect(await lane.snapshot().phase == .ready)
        #expect(budget.snapshot().commandCount == 0)
    }

    @Test("transport failure before an execution capability exists is not accepted")
    func preparationTransportFailure() async throws {
        await #expect(throws: V2RoomCallFailure.notAccepted(.unavailable)) {
            _ = try await v2ExecutePreparedRoomSendOperationBatch {
                throw TransportUnavailable()
            }
        }
    }

    @Test("cancelled preparation has no uncertain message write")
    func preparationCancellation() async throws {
        await #expect(throws: V2RoomCallFailure.notAccepted(.cancelled)) {
            _ = try await v2ExecutePreparedRoomSendOperationBatch {
                throw CancellationError()
            }
        }
    }

    @Test("uncertainty from a preparation dependency is not message commit uncertainty")
    func preparationDependencyUncertainty() async throws {
        await #expect(throws: V2RoomCallFailure.notAccepted(.unavailable)) {
            _ = try await v2ExecutePreparedRoomSendOperationBatch {
                throw V2RoomCallFailure.outcomeUnknown
            }
        }
    }

    @Test("a proven stale activation remains stale")
    func preparationAuthorityFailure() async throws {
        await #expect(throws: V2RoomCallFailure.notAccepted(.staleActivation)) {
            _ = try await v2ExecutePreparedRoomSendOperationBatch {
                throw V2RoomCallFailure.notAccepted(.staleActivation)
            }
        }
    }

    @Test("uncertain execution retains the transaction recovery path")
    func executionUncertainty() async throws {
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
            _ = try await v2ExecutePreparedRoomSendOperationBatch {
                .init { throw V2RoomCallFailure.outcomeUnknown }
            }
        }
    }

    @Test("an unclassified error after execution begins remains unknown to the host")
    func executionTransportFailure() async throws {
        do {
            _ = try await v2ExecutePreparedRoomSendOperationBatch {
                .init { throw TransportUnavailable() }
            }
            Issue.record("execution should have failed")
        } catch {
            let completion: V2RoomTransactionCompletion<[V2RoomMessagingResult]> = v2RoomDomainCompletion(error)
            guard case .outcomeUnknown = completion else {
                Issue.record("an execution failure cannot be reclassified as pre-write rejection")
                return
            }
        }
    }
}
