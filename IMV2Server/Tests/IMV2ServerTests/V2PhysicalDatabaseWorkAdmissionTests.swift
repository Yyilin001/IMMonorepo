import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
import Testing

@Suite("independent physical database work admission")
struct V2PhysicalDatabaseWorkAdmissionTests {
    @Test("a saturated physical owner cannot consume a peer database's permits and aliases share one budget",
        arguments: [V2DatabaseWorkClass.foregroundWrite, .sync])
    func physicalIsolationAndMetricIdentity(workClass: V2DatabaseWorkClass) async throws {
        let policy = V2DatabaseWorkAdmissionPolicy(maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1, maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 2, maximumInteractiveReadQueued: 2,
            maximumSyncQueued: 2, timeout: .seconds(5))
        let primary = V2DatabaseWorkAdmissionController(policy: policy)
        let registry = V2PhysicalDatabaseWorkAdmissions(primaryKey: "control", primary: primary,
            keys: ["control", "owner", "owner"], policy: policy)
        let first = try #require(registry.controller(for: "control"))
        let second = try #require(registry.controller(for: "owner"))
        #expect(first === primary)
        #expect(first !== second)
        #expect(registry.controller(for: "owner") === second)
        #expect(registry.controller(for: "unknown") == nil)
        #expect(registry.controllers.count == 2)
        // Writes borrow idle read capacity; preparation uses its sync budget.
        let capacity = workClass == .foregroundWrite ? 2 : 1
        for _ in 0..<capacity { #expect(await first.acquire(workClass) == .admitted) }
        let queued = Task { await first.acquire(workClass) }
        do {
            let deadline = ContinuousClock.now + .seconds(2)
            while await first.snapshot().queued != 1 {
                guard ContinuousClock.now < deadline else { throw Failure.timeout }
                await Task.yield()
            }
            #expect(await second.acquire(workClass) == .admitted)
            #expect(await first.snapshot().queued == 1)
            let metrics = V2DatabaseWorkAdmissionMetricsGroup(registry.controllers + [primary, second])
            let pressure = await metrics.snapshot()
            #expect(pressure.value(for: workClass).inFlight == capacity + 1)
            #expect(pressure.value(for: workClass).queued == 1)
            #expect(pressure.value(for: workClass).admittedRequests == UInt64(capacity + 1))
            await second.release(workClass)
            #expect(await first.snapshot().queued == 1)
            await first.release(workClass)
            #expect(await queued.value == .admitted)
            for _ in 0..<capacity { await first.release(workClass) }
            let drained = await metrics.snapshot()
            #expect(drained.foregroundInFlight == 0 && drained.syncInFlight == 0 && drained.queued == 0)
            #expect(drained.value(for: workClass).admittedRequests == UInt64(capacity + 2))
            #expect(drained.value(for: workClass).queueWait.samples == 1)
        } catch {
            queued.cancel()
            let result = await queued.value
            if result == .admitted { await first.release(workClass) }
            while await first.snapshot().value(for: workClass).inFlight > 0 { await first.release(workClass) }
            while await second.snapshot().value(for: workClass).inFlight > 0 { await second.release(workClass) }
            throw error
        }
    }

    private enum Failure: Error { case timeout }
}
