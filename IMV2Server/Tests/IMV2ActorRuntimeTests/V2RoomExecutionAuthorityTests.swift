import Foundation
import Synchronization
import IMV2ActorContracts
import Testing

@testable import IMV2ActorRuntime

@Suite("Local room execution authority")
struct V2RoomExecutionAuthorityTests {
    @Test("process drain cuts off unscanned rooms without revoking an already owned turn")
    func processDrainCutsOffEveryRoom() throws {
        let qualification = V2ActorServiceQualification.standalone()
        let proof = try #require(qualification.snapshot())
        let admission = V2RoomHostAdmission()
        admission.open()
        let authority = V2RoomExecutionAuthority(
            admission: { true },
            qualification: qualification, generation: proof.generation, hostAdmission: admission)
        authority.setPhase(.ready)
        try authority.admit()
        admission.close()
        // Local phase intentionally remains ready until the Host reaches this room.
        #expect(throws: V2RoomCallFailure.notAccepted(.retired)) { try authority.admit() }
        #expect(authority.deadline() != nil)
        #expect(authority.inFlight == 1)
        authority.finish()
    }

    @Test("placement withdrawal rejects admission and dispatch before a Host callback")
    func withdrawalIsSynchronous() throws {
        let qualification = V2ActorServiceQualification.standalone()
        let proof = try #require(qualification.snapshot())
        let current = Mutex(true)
        let authority = V2RoomExecutionAuthority(
            admission: { current.withLock { $0 } },
            qualification: qualification, generation: proof.generation)
        authority.setPhase(.ready)
        try authority.admit()
        current.withLock { $0 = false }
        #expect(authority.deadline() == nil)
        #expect(throws: V2RoomCallFailure.notAccepted(.authorityLost)) { try authority.admit() }
        #expect(authority.inFlight == 1)
        authority.finish()
        #expect(authority.inFlight == 0)
    }

    @Test("drain closes admission while preserving a safe owned turn and its pin")
    func drainKeepsOwnedExecution() throws {
        let qualification = V2ActorServiceQualification.standalone()
        let proof = try #require(qualification.snapshot())
        let authority = V2RoomExecutionAuthority(
            admission: { true },
            qualification: qualification, generation: proof.generation)
        authority.setPhase(.ready)
        try authority.admit()
        authority.setPhase(.draining)
        #expect(throws: V2RoomCallFailure.notAccepted(.retired)) { try authority.admit() }
        #expect(authority.deadline() != nil)
        #expect(authority.inFlight == 1)
        authority.setPhase(.uncertain)
        #expect(authority.deadline() == nil)
        #expect(authority.inFlight == 1)
        authority.finish()
        #expect(authority.inFlight == 0)
    }
}
