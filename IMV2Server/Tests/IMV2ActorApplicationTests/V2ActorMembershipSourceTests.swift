import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import Testing
@testable import IMV2ActorApplication

@Suite("Live committed membership source")
struct V2ActorMembershipSourceTests {
    private actor Control {
        var record: V2ActorServiceMembershipRecord
        var unavailable = false
        var entered = false
        var held: CheckedContinuation<Void, Never>?
        var hold = false
        var installed: [UInt64] = []
        var suspensions = 0
        init(_ record: V2ActorServiceMembershipRecord) { self.record = record }
        func load() async throws -> V2ActorServiceMembershipRecord {
            entered = true
            if hold { await withCheckedContinuation { held = $0 } }
            if unavailable { throw V2RoomActorApplicationError.invalidRole }
            return record
        }
        func configure(_ record: V2ActorServiceMembershipRecord, unavailable: Bool = false, hold: Bool = false) {
            self.record = record; self.unavailable = unavailable; self.hold = hold
        }
        func install(_ record: V2ActorServiceMembershipRecord) { installed.append(record.revision) }
        func suspend() { suspensions += 1 }
        func release() { held?.resume(); held = nil }
    }
    private func record(_ revision: UInt64) throws -> V2ActorServiceMembershipRecord {
        try .init(revision: revision, current: ["a"], peers: [.init(nodeID: "a", serviceID: "a", address: "a.test", port: 7337)])
    }
    @Test func refreshCatchesUpAndSuspendsUntilSuccessfulRead() async throws {
        let control = Control(try record(1))
        let source = V2ActorMembershipSource(load: { try await control.load() },
            install: { await control.install($0) }, suspend: { await control.suspend() })
        try await source.refresh()
        await control.configure(try record(9), unavailable: true)
        await #expect(throws: (any Error).self) { try await source.refresh() }
        await #expect(throws: (any Error).self) { try await source.refresh() }
        #expect(await control.suspensions == 1)
        #expect(await control.installed == [1])
        await control.configure(try record(9))
        try await source.refresh()
        #expect(await control.installed == [1, 9])
        #expect(await source.stop(deadline: .now + .seconds(1)))
    }
    @Test func shutdownWaitsForActualReadAndDiscardsLateResult() async throws {
        let control = Control(try record(1))
        await control.configure(try record(1), hold: true)
        let source = V2ActorMembershipSource(load: { try await control.load() },
            install: { await control.install($0) }, suspend: { await control.suspend() })
        try await source.start()
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await control.entered), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await control.entered)
        #expect(await source.stop(deadline: .now) == false)
        await control.release()
        #expect(await source.stop(deadline: .now + .seconds(2)))
        #expect(await control.installed.isEmpty)
    }
}
