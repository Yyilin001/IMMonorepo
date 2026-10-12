import Synchronization
import Testing
@testable import IMV2ServerInfrastructure

@Suite("Message connection mode isolation")
struct V2MessageWriteConnectionGateTests {
    private struct Activity { var shared = 0; var exclusive = 0 }
    @Test("exclusive transactions never overlap independent cycles or each other")
    func modeIsolation() async throws {
        let gate = V2MessageWriteConnectionGate(), activity = Mutex(Activity())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let shared = index % 3 != 0
                    try await gate.withAccess(shared: shared) {
                        activity.withLock { state in
                            if shared { #expect(state.exclusive == 0); state.shared += 1 }
                            else { #expect(state.shared == 0 && state.exclusive == 0); state.exclusive += 1 }
                        }
                        await Task.yield()
                        activity.withLock { state in
                            if shared { #expect(state.exclusive == 0); state.shared -= 1 }
                            else { #expect(state.shared == 0 && state.exclusive == 1); state.exclusive -= 1 }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(activity.withLock { $0.shared == 0 && $0.exclusive == 0 })
    }
    @Test("failure releases exclusive mode, allowing a later independent cycle")
    func throwingOperationReleases() async throws {
        enum Failure: Error { case expected }
        let gate = V2MessageWriteConnectionGate()
        do { try await gate.withAccess(shared: false) { throw Failure.expected } }
        catch Failure.expected {}
        #expect(try await gate.withAccess(shared: true) { 42 } == 42)
    }
}
