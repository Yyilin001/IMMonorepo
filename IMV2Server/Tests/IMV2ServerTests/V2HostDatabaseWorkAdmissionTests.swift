import Foundation
import IMV2ActorContracts
@testable import IMV2Server
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
