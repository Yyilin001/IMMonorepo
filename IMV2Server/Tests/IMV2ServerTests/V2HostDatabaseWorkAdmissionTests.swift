@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Host database work admission")
struct V2HostDatabaseWorkAdmissionTests {
    private func controller(timeout: Duration = .seconds(2)) -> V2DatabaseWorkAdmissionController {
        .init(policy: .init(maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1, maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 2, maximumInteractiveReadQueued: 2,
            maximumSyncQueued: 1, timeout: timeout))
    }

    @Test("Account-style direct Host call acquires the physical SQL permit")
    func directHostCallIsAdmitted() async throws {
        let admission = controller()
        let counter = HostSQLCounter()
        let value = try await v2WithAdmittedRoomDatabaseWork(admission,
            workClass: .interactiveRead, callerDeadline: .now + .seconds(1)) {
            await counter.record()
            return 42
        }
        #expect(value == 42)
        #expect(await counter.count == 1)
        let snapshot = await admission.snapshot()
        #expect(snapshot.interactiveRead.admittedRequests == 1)
        #expect(snapshot.interactiveRead.inFlight == 0)
    }

    @Test("caller deadline expires in admission queue without invoking SQL")
    func waitingPastCallerDeadlineDoesNotEnterSQL() async throws {
        let admission = controller()
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        #expect(await admission.acquire(.interactiveRead) == .admitted)
        let counter = HostSQLCounter()
        await #expect(throws: V2RoomCallFailure.notAccepted(.deadlineExceeded)) {
            try await v2WithAdmittedRoomDatabaseWork(admission,
                workClass: .interactiveRead, callerDeadline: .now + .milliseconds(25)) {
                await counter.record()
            }
        }
        #expect(await counter.count == 0)
        let snapshot = await admission.snapshot()
        #expect(snapshot.interactiveRead.inFlight == 1)
        #expect(snapshot.interactiveRead.queued == 0)
        await admission.release(.interactiveRead)
        await admission.release(.foregroundWrite)
    }

    @Test("durable preparation settles before owner-write admission")
    func durablePreparationDoesNotHoldOwnerWrite() async throws {
        let preparation = controller(), owner = controller()
        let prepareGate = HostPreparationGate(), executeGate = HostPreparationGate()
        let task = Task {
            try await withAdmittedPreparationAndExecution(
                preparationAdmission: preparation, ownerAdmission: owner,
                deadline: .now + .seconds(10)) {
                await prepareGate.enter()
                return .init {
                    await executeGate.enter()
                    return []
                }
            }
        }
        await prepareGate.waitUntilEntered()
        #expect(await preparation.snapshot().sync.inFlight == 1)
        #expect(await owner.snapshot().foregroundWrite.inFlight == 0)
        await prepareGate.release()
        await executeGate.waitUntilEntered()
        #expect(await preparation.snapshot().sync.inFlight == 0)
        #expect(await owner.snapshot().foregroundWrite.inFlight == 1)
        await executeGate.release()
        #expect(try await task.value.isEmpty)
        #expect(await owner.snapshot().foregroundWrite.inFlight == 0)
    }

    @Test("cancelled preparation retains its permit until actual exit")
    func cancelledPreparationWaitsForActualExit() async throws {
        let preparation = controller(), owner = controller()
        let gate = HostPreparationGate(), executed = HostSQLCounter()
        let task = Task {
            try await withAdmittedPreparationAndExecution(
                preparationAdmission: preparation, ownerAdmission: owner,
                deadline: .now + .seconds(10)) {
                // Models a borrowed database task which cannot finish merely
                // because its caller has been cancelled.
                await gate.enter()
                try Task.checkCancellation()
                return .init {
                    await executed.record()
                    return []
                }
            }
        }
        await gate.waitUntilEntered()
        task.cancel()
        #expect(await preparation.snapshot().sync.inFlight == 1)
        #expect(await owner.snapshot().foregroundWrite.admittedRequests == 0)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await preparation.snapshot().sync.inFlight == 0)
        #expect(await owner.snapshot().foregroundWrite.admittedRequests == 0)
        #expect(await executed.count == 0)
    }

    @Test("shorter admission policy timeout reports overload without SQL")
    func policyTimeoutDoesNotClaimCallerDeadlineExpired() async throws {
        let admission = controller(timeout: .milliseconds(20))
        #expect(await admission.acquire(.foregroundWrite) == .admitted)
        #expect(await admission.acquire(.interactiveRead) == .admitted)
        let counter = HostSQLCounter()
        await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
            try await v2WithAdmittedRoomDatabaseWork(admission,
                workClass: .interactiveRead, callerDeadline: .now + .seconds(1)) {
                await counter.record()
            }
        }
        #expect(await counter.count == 0)
        await admission.release(.interactiveRead)
        await admission.release(.foregroundWrite)
    }
}

private actor HostSQLCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor HostPreparationGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { completion = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        completion?.resume()
        completion = nil
    }
}

// Exercise structured admission cancellation independently of room sending.
/// A room turn keeps ownership throughout both stages. Each admission permit
/// follows its actual structured operation, including cancellation settlement.
private func withAdmittedPreparationAndExecution(
    preparationAdmission: V2DatabaseWorkAdmissionController?,
    ownerAdmission: V2DatabaseWorkAdmissionController?,
    deadline: ContinuousClock.Instant,
    prepare: @Sendable () async throws -> V2PreparedRoomSendOperationBatch
) async throws -> [V2RoomMessagingResult] {
    V2SendPathTrace.current?.mark("prepared_batch_enter")
    let prepared = try await v2WithAdmittedRoomDatabaseWork(preparationAdmission,
        workClass: .sync, callerDeadline: deadline, operation: prepare)
    V2SendPathTrace.current?.mark("prepared_batch_ready")
    return try await v2WithAdmittedRoomDatabaseWork(ownerAdmission,
        workClass: .foregroundWrite, callerDeadline: deadline) {
        try await prepared.execute()
    }
}
