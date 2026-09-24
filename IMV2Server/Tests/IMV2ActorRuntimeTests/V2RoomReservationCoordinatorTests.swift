import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing
@testable import IMV2ActorRuntime

@Suite("Pair reservations retain atomicity without waiting cycles")
struct V2RoomReservationCoordinatorTests {
    @Test("canonical ordering and source equal to target")
    func canonicalAndDeduplicated() async throws {
        let fixture = try Fixture()
        let both = try await fixture.coordinator.withReservations(
            source: fixture.rooms[1], target: fixture.rooms[0], deadline: .now + .seconds(3)
        ) { .committed($0.map(\.token.roomID)) }
        #expect(both == fixture.rooms)
        let one = try await fixture.coordinator.withReservations(
            source: fixture.rooms[0], target: fixture.rooms[0], deadline: .now + .seconds(3)
        ) { .committed($0.count) }
        #expect(one == 1)
        #expect(await fixture.budget.snapshot().commandCount == 0)
    }

    @Test("opposing pairs wait in the same order and progress after the first SQL finishes")
    func oppositeDirection() async throws {
        let fixture = try Fixture()
        let gate = Gate()
        let first = Task {
            try await fixture.coordinator.withReservations(
                source: fixture.rooms[0], target: fixture.rooms[1], deadline: .now + .seconds(3)
            ) { _ in
                await gate.hold()
                return .committed(1)
            }
        }
        await gate.waitUntilHeld()
        let second = Task {
            try await fixture.coordinator.withReservations(
                source: fixture.rooms[1], target: fixture.rooms[0], deadline: .now + .seconds(3)
            ) { _ in .committed(2) }
        }
        let firstLane = try #require(fixture.lanes[fixture.rooms[0]])
        let phaseDeadline = ContinuousClock.now + .seconds(2)
        while await firstLane.snapshot().queuedCount != 1 {
            guard ContinuousClock.now < phaseDeadline else { throw Failure.phaseNotReached }
            await Task.yield()
        }
        #expect(await fixture.coordinator.activePairCount() == 2)
        await gate.release()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
        #expect(await fixture.budget.snapshot().commandCount == 0)
    }

    @Test("failed second acquisition and ambiguous mark acknowledgement do not dispatch SQL")
    func beforeDispatchFailure() async throws {
        for failMark in [false, true] {
            let fixture = try Fixture(failSecondAcquire: !failMark, failSecondMark: failMark)
            do {
                let _: Int = try await fixture.coordinator.withReservations(
                    source: fixture.rooms[0], target: fixture.rooms[1], deadline: .now + .seconds(3)
                ) { _ in
                    Issue.record("SQL executed before all reservation acknowledgements")
                    return .committed(1)
                }
                Issue.record("failed reservation unexpectedly succeeded")
            } catch {
                #expect(error as? V2RoomCallFailure == .notAccepted(.unavailable))
            }
            #expect(await fixture.budget.snapshot().commandCount == 0)
            for lane in fixture.lanes.values { #expect(await lane.snapshot().phase == .ready) }
        }
    }

    @Test("unknown shared SQL completion retires every participating room")
    func sharedUnknown() async throws {
        let fixture = try Fixture()
        do {
            let _: Int = try await fixture.coordinator.withReservations(
                source: fixture.rooms[0], target: fixture.rooms[1], deadline: .now + .seconds(3)
            ) { _ in .outcomeUnknown }
            Issue.record("unknown SQL unexpectedly succeeded")
        } catch { #expect(error as? V2RoomCallFailure == .outcomeUnknown) }
        #expect(await fixture.budget.snapshot().reservationCount == 2)
        for lane in fixture.lanes.values {
            #expect(await lane.snapshot().phase == .uncertain)
            #expect(await lane.completeRetirement())
        }
        #expect(await fixture.budget.snapshot().commandCount == 0)
    }

    @Test("lost completion notification keeps a holder closed without erasing committed result")
    func lostNotification() async throws {
        let fixture = try Fixture(dropSecondFinish: true)
        let value = try await fixture.coordinator.withReservations(
            source: fixture.rooms[0], target: fixture.rooms[1], deadline: .now + .seconds(3)
        ) { _ in .committed(42) }
        #expect(value == 42)
        let first = try #require(fixture.lanes[fixture.rooms[0]])
        let second = try #require(fixture.lanes[fixture.rooms[1]])
        #expect(!(await first.snapshot().hasReservation))
        #expect(await second.snapshot().hasReservation)
        await second.loseLease()
        #expect(await second.completeRetirement())
        #expect(await fixture.budget.snapshot().commandCount == 0)
    }

    @Test("a coordinator cannot be entered while an ordinary room turn is held")
    func noNestedRoomTurn() async throws {
        let fixture = try Fixture()
        do {
            let _: Int = try await V2RoomTurnScope.$roomID.withValue(fixture.rooms[0]) {
                try await fixture.coordinator.withReservations(
                    source: fixture.rooms[0], target: fixture.rooms[1], deadline: .now + .seconds(3)
                ) { _ in .committed(1) }
            }
            Issue.record("nested coordinator unexpectedly succeeded")
        } catch { #expect(error as? V2RoomCallFailure == .notAccepted(.invalidRequest)) }
        #expect(await fixture.budget.snapshot().commandCount == 0)
    }

    private enum Failure: Error { case phaseNotReached, acknowledgementLost }

    private struct Fixture: Sendable {
        let rooms: [RoomID]
        let budget: V2RoomCommandBudget
        let lanes: [RoomID: V2RoomTurnLane<Int, Int>]
        let coordinator: V2RoomReservationCoordinator

        init(failSecondAcquire: Bool = false, failSecondMark: Bool = false, dropSecondFinish: Bool = false) throws {
            let config = try V2RoomRuntimeConfiguration()
            let rooms = [RoomID(uuid: UUID()), RoomID(uuid: UUID())].sorted()
            let budget = V2RoomCommandBudget(configuration: config)
            var lanes: [RoomID: V2RoomTurnLane<Int, Int>] = [:]
            for room in rooms {
                lanes[room] = V2RoomTurnLane(
                    token: .init(roomID: room, owner: try .init(shardID: "same-owner", epoch: 0),
                                 activationEpoch: try .init(1),
                                 host: .init(hostID: V2ActorHostID(uuid: UUID()), incarnationID: UUID())),
                    configuration: config, budget: budget, classify: { _ in .barrier },
                    execute: { .committed($0.items.map(\.request)) }, onUncertain: { _ in }
                )
            }
            self.rooms = rooms
            self.budget = budget
            self.lanes = lanes
            let immutableLanes = lanes
            self.coordinator = .init(operations: .init(
                reserve: { room, request, deadline in
                    if failSecondAcquire, room == rooms[1] { throw Failure.acknowledgementLost }
                    guard let lane = immutableLanes[room] else { throw Failure.phaseNotReached }
                    return try await lane.reserve(requestID: request, deadline: deadline)
                },
                markDispatched: { grant, _ in
                    guard let lane = immutableLanes[grant.token.roomID] else { throw Failure.phaseNotReached }
                    try await lane.markReservationDispatched(grant)
                    if failSecondMark, grant.token.roomID == rooms[1] { throw Failure.acknowledgementLost }
                },
                abort: { grant, _ in await immutableLanes[grant.token.roomID]?.abortReservation(grant) ?? false },
                finish: { grant, completion, _ in
                    if dropSecondFinish, grant.token.roomID == rooms[1] { return false }
                    return await immutableLanes[grant.token.roomID]?.finishReservation(grant, completion: completion) ?? false
                }
            ), configuration: config)
        }
    }

    private actor Gate {
        private var held: CheckedContinuation<Void, Never>?
        private var observer: CheckedContinuation<Void, Never>?
        func hold() async {
            await withCheckedContinuation { continuation in
                held = continuation
                observer?.resume()
                observer = nil
            }
        }
        func waitUntilHeld() async {
            if held != nil { return }
            await withCheckedContinuation { observer = $0 }
        }
        func release() {
            let continuation = held
            held = nil
            continuation?.resume()
        }
    }
}
