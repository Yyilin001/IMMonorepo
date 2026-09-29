@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Room transaction outcome and granted authority")
struct V2RoomTransactionAttemptTests {
    private enum Failure: Error, Equatable { case body, transport }

    @Test("only a successfully returned body can have dispatched COMMIT")
    func bodyFailure() async throws {
        let attempt = V2RoomTransactionAttempt()
        do {
            let _: Int = try await attempt.body { throw Failure.body }
            Issue.record("body should fail")
        } catch {
            #expect(attempt.classify(error) as? Failure == .body)
        }
        let neverEntered = V2RoomTransactionAttempt()
        #expect(neverEntered.classify(Failure.transport) as? Failure == .transport)
    }

    @Test("lost COMMIT response and cancellation after body success remain unknown")
    func commitFailure() async throws {
        let attempt = V2RoomTransactionAttempt()
        let result = try await attempt.body { 7 }
        #expect(result == 7)
        #expect(attempt.classify(Failure.transport) is V2RoomTransactionOutcomeUnknown)
        #expect(attempt.classify(CancellationError()) is V2RoomTransactionOutcomeUnknown)
        // A subsequent retry owns a fresh journal; a prior successful body
        // cannot turn its early pool/admission failure into an unknown write.
        #expect(V2RoomTransactionAttempt().classify(Failure.body) as? Failure == .body)
    }

    @Test("scope rejects duplicate epochs, ungranted rooms and cross-shard batches")
    func scopeAuthority() throws {
        let token = try makeToken()
        let scope = try V2RoomActivationWriteScope(tokens: [token])
        #expect(try scope.token(for: token.roomID.uuidValue!) == token)
        #expect(throws: V2RoomActivationLeaseError.activationChanged) {
            try scope.token(for: UUID())
        }
        #expect(throws: V2RoomActivationLeaseError.activationChanged) {
            try V2RoomActivationWriteScope(tokens: [token, token])
        }
        let other = try makeToken(shard: "other")
        #expect(throws: V2RoomActivationLeaseError.activationChanged) {
            try V2RoomActivationWriteScope(tokens: [token, other])
        }
        #expect(throws: V2RoomActivationLeaseError.activationChanged) {
            try V2RoomActivationWriteScope(tokens: [])
        }
    }

    private func makeToken(shard: String = "owner") throws -> V2RoomActivationToken {
        .init(roomID: .init(uuid: UUID()), owner: try .init(shardID: shard, epoch: 0),
              activationEpoch: try .init(1),
              host: .init(hostID: try .init("host"), incarnationID: UUID()))
    }
}
