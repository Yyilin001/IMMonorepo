import Foundation
import HTTPTypes
import IMV2Core
@testable import IMV2ServerHTTP
import Testing
import Vapor

struct V2HTTPOperationResponseTests {
    @Test(arguments: [V2MessageOperationRetryHint.Reason.rateLimited, .admissionUnavailable],
          [UInt64?.none, 1, 1000, 1001])
    func deferredHTTPContract(reason: V2MessageOperationRetryHint.Reason, delay: UInt64?) async throws {
        let command = try V2MessageReactionOperationCommand(command: .init(
            roomID: .init(uuid: UUID()), actorUserID: .init(uuid: UUID()),
            operationID: .init(uuid: UUID()), messageID: .init(uuid: UUID()),
            reaction: "👍", action: .add), expectedReactionRevision: 0,
            firstSubmissionDeadlineMilliseconds: 1000)
        let hint = try V2MessageOperationRetryHint(identity: command.identity,
            fingerprint: command.fingerprint, reason: reason, retryAfterMilliseconds: delay)
        let response = try await v2RespondOperation { V2MessageReactionRecoveryResult.deferred(hint) }
        #expect(response.status == (reason == .rateLimited ? .tooManyRequests : .serviceUnavailable))
        #expect(response.headers[.cacheControl] == "no-store")
        #expect(response.headers[.contentType] == "application/json")
        #expect(response.headers[.retryAfter] == delay.map { String(($0 + 999) / 1000) })
    }

    @Test func cancellationRemainsCancellation() async {
        await #expect(throws: CancellationError.self) {
            try await v2RespondOperation { () -> V2MessageReactionRecoveryResult in
                throw CancellationError()
            }
        }
    }

    @Test func unexpectedFailureIsRetryable() async throws {
        enum Failure: Error { case unavailable }
        do {
            _ = try await v2RespondOperation { () -> V2MessageReactionRecoveryResult in
                throw Failure.unavailable
            }
            Issue.record("存储失败不应返回成功响应")
        } catch let error as Abort {
            #expect(error.status == .serviceUnavailable)
            #expect(error.headers[.cacheControl] == "no-store")
        }
    }
}
