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
        let entry = policyEntry()
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

    @Test("Invalid accepted outcome leaves the policy cache unchanged")
    func invalidAcceptedOutcomeDoesNotPublishCache() async throws {
        let policy = V2DirectSendPolicyCache()
        let fast = V2DirectRoomLogFastAppendCache()
        let key = V2DirectSendPolicyCache.Key(roomID: UUID(), senderID: UUID())
        let command = try makeCommand(key: key)
        let accepted = V2AcceptedMessageDraft(
            messageID: .init(uuid: UUID()), roomID: command.roomID,
            roomSequence: 1, senderUserID: command.senderUserID,
            clientMessageID: command.clientMessageID, text: command.text,
            createdAt: Date(timeIntervalSince1970: 10_000_000_000_000)
        ).materialized(mediaPresentations: [])
        let effects = makeEffects(policy: policy, fast: fast)

        await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
            try await effects.finalize(command: command, cacheKey: key,
                commit: .init(outcome: .accepted(accepted),
                              directPolicyCacheUpdate: policyEntry()))
        }
        #expect(await policy.value(for: key) == nil)
    }

    @Test("Invalid batch ordering leaves the policy cache unchanged")
    func invalidBatchOrderingDoesNotPublishCache() async throws {
        let policy = V2DirectSendPolicyCache()
        let fast = V2DirectRoomLogFastAppendCache()
        let key = V2DirectSendPolicyCache.Key(roomID: UUID(), senderID: UUID())
        let command = try makeCommand(key: key)
        let request = V2RoomWriteRequest(command: command,
            capacityProfile: try .init(id: "standard", limits: .init(
                maxEligibleMembers: 2, maxCommandsPerWindow: 2, retryAfterSeconds: 1)),
            identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())),
            now: Date())
        let commit = RoomWriteCommit(outcome: .rateLimited(retryAfterSeconds: 1),
            directPolicyCacheUpdate: policyEntry())
        let effects = makeEffects(policy: policy, fast: fast)

        await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
            try await effects.finalize(requests: [request, request], committed: [
                .init(originalIndex: 0, cacheKey: key, commit: commit),
                .init(originalIndex: 0, cacheKey: key, commit: commit)
            ])
        }
        #expect(await policy.value(for: key) == nil)
    }

    private func makeCommand(key: V2DirectSendPolicyCache.Key) throws -> V2SendMessageCommand {
        try .init(roomID: .init(uuid: key.roomID), senderUserID: .init(uuid: key.senderID),
                  clientMessageID: .init(uuid: UUID()), text: "message",
                  limits: .init(maxUTF8Bytes: 64))
    }

    private func makeEffects(
        policy: V2DirectSendPolicyCache, fast: V2DirectRoomLogFastAppendCache
    ) -> V2RoomWriteCommitEffects {
        .init(ownership: .store, directSendPolicyCache: policy,
              directRoomLogFastAppendCache: fast,
              shardAdmissionCommandCreditPool: nil, roomAdmissionCommandCreditPool: nil,
              appendStageMetrics: nil)
    }

    private func policyEntry() -> V2DirectSendPolicyCache.Entry {
        .init(recipientID: UUID(), directPairRevision: 1, senderPolicyRevision: 1,
              recipientPolicyRevision: 1, senderProfileVisibleToRecipient: true,
              senderCanSend: true, senderIsActive: true, recipientIsActive: true,
              blocked: false, isFriend: true, senderHasReplied: false,
              recipientHasReplied: false, allowsStrangers: true,
              senderAccountKind: nil, senderAccountStatus: nil, senderAllowsServiceMessages: nil,
              recipientAccountKind: nil, recipientAccountStatus: nil,
              recipientAllowsCustomerMessages: nil)
    }
}
