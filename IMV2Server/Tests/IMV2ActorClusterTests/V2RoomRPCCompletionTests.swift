import Foundation
import Testing
import IMV2ActorContracts
@testable import IMV2ActorCluster

@Suite("Independent RPC completion and node budgets")
struct V2RoomRPCCompletionTests {
    enum Failure: Error { case cancelled }
    @Test("cancellation before continuation installation is delivered and late physical success cannot replace it")
    func cancellationBeforeInstallation() async {
        let completion = V2RoomRPCCompletion<Int>()
        #expect(completion.cancelCaller(with: Failure.cancelled))
        completion.finishPhysical(with: .success(42))
        await #expect(throws: Failure.self) {
            try await withCheckedThrowingContinuation { continuation in completion.install(continuation) }
        }
        #expect(!completion.cancelCaller(with: Failure.cancelled))
    }
    @Test("racing timeout and physical return complete the caller exactly once")
    func racingCompletion() async {
        for _ in 0..<500 {
            let completion = V2RoomRPCCompletion<Int>()
            let caller = Task {
                try await withCheckedThrowingContinuation { continuation in completion.install(continuation) }
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { completion.finishPhysical(with: .success(42)) }
                group.addTask { _ = completion.cancelCaller(with: Failure.cancelled) }
            }
            switch await caller.result {
            case .success(let value): #expect(value == 42)
            case .failure(let error): #expect(error is Failure)
            }
        }
    }
    @Test("physical work, not caller cancellation, owns shared node capacity")
    func physicalPermitLifetime() throws {
        let configuration = try V2RoomRuntimeConfiguration(
            maximumConcurrentRestores: 1, maximumActivationWaitersPerRoom: 1,
            maximumPendingActivations: 1, maximumActivationWaitersPerHost: 1,
            maximumConcurrentResolutions: 1)
        let budget = V2RoomClusterBudget(configuration: configuration, maximumSessions: 2)
        let permit = try budget.acquire(.transport)
        let completion = V2RoomRPCCompletion<Int>()
        #expect(completion.cancelCaller(with: Failure.cancelled))
        #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) { try budget.acquire(.transport) }
        completion.finishPhysical(with: .success(42))
        permit.release(); permit.release()
        let nextPeerPermit = try budget.acquire(.transport)
        nextPeerPermit.release()
    }
    @Test("expired sessions on idle peers no longer consume the node session budget")
    func expiredSession() throws {
        let budget = V2RoomClusterBudget(configuration: try .init(), maximumSessions: 1)
        let expired = try budget.acquire(.session, expiresAt: .now - .seconds(1))
        let nextPeer = try budget.acquire(.session, expiresAt: .now + .seconds(10))
        expired.release()
        #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) { try budget.acquire(.session) }
        nextPeer.release()
        try budget.acquire(.session).release()
    }
}
