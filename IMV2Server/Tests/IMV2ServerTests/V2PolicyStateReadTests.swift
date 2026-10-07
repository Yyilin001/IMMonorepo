import Foundation
import IMV2ActorContracts
import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import Testing

@Suite("policy state reads without logical admission")
struct V2PolicyStateReadTests {
    @Test("warm memory does not invoke cold loading")
    func warmRead() async throws {
        let result = try await v2ReadPolicyState(callerDeadline: .now + .seconds(1),
            cachedOperation: { 7 }, operation: { Issue.record("Unexpected cold load"); return 0 })
        #expect(result == 7)
    }
    @Test("a memory miss loads state")
    func coldRead() async throws {
        #expect(try await v2ReadPolicyState(callerDeadline: .now + .seconds(1),
            cachedOperation: { nil as Int? }, operation: { 9 }) == 9)
    }
    @Test("expired callers cannot start state loading")
    func expiredRead() async throws {
        await #expect(throws: V2RoomCallFailure.notAccepted(.deadlineExceeded)) {
            try await v2ReadPolicyState(callerDeadline: .now - .milliseconds(1),
                operation: { Issue.record("Expired request loaded state"); return 0 })
        }
    }
    @Test("busy owners remain a retryable pre-write overload")
    func busyRead() async throws {
        await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
            try await v2ReadPolicyState(callerDeadline: .now + .seconds(1),
                operation: { () throws -> Int in throw V2PolicyAuthorizationLifecycleError.busy })
        }
    }
}
