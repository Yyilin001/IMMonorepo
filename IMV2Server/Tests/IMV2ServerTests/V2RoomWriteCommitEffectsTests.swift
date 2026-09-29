@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

struct V2RoomWriteCommitEffectsTests {
    @Test("Only the transaction owner publishes acceptance cache effects", arguments: [false, true])
    func provisionalWriteDoesNotPublishCache(borrowed: Bool) async throws {
        let policy = V2DirectSendPolicyCache()
        let fast = V2DirectRoomLogFastAppendCache()
        let key = V2DirectSendPolicyCache.Key(roomID: UUID(), senderID: UUID())
        let entry = V2DirectSendPolicyCache.Entry(
            recipientID: UUID(), directPairRevision: 1, senderPolicyRevision: 1,
            recipientPolicyRevision: 1, senderProfileVisibleToRecipient: true,
            senderCanSend: true, senderIsActive: true, recipientIsActive: true,
            blocked: false, isFriend: true, senderHasReplied: false,
            recipientHasReplied: false, allowsStrangers: true,
            senderAccountKind: nil, senderAccountStatus: nil, senderAllowsServiceMessages: nil,
            recipientAccountKind: nil, recipientAccountStatus: nil, recipientAllowsCustomerMessages: nil)
        let command = try V2SendMessageCommand(roomID: .init(uuid: key.roomID),
            senderUserID: .init(uuid: key.senderID), clientMessageID: .init(uuid: UUID()),
            text: "message", limits: .init(maxUTF8Bytes: 64))
        let effects = V2RoomWriteCommitEffects(ownership: borrowed ? .operationReceipt : .store,
            directSendPolicyCache: policy, directRoomLogFastAppendCache: fast,
            shardAdmissionCommandCreditPool: nil, roomAdmissionCommandCreditPool: nil,
            appendStageMetrics: nil)
        let outcome = try await effects.finalize(command: command, cacheKey: key,
            commit: .init(outcome: .rateLimited(retryAfterSeconds: 1), directPolicyCacheUpdate: entry))
        #expect(outcome == .rateLimited(retryAfterSeconds: 1))
        #expect(await policy.value(for: key) == (borrowed ? nil : entry))
    }
}
