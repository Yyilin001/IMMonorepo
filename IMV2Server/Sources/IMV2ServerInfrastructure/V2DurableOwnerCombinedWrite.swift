import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication
import Foundation

/// Protocol envelopes are derived from the same reduced message outcomes
/// before SQL dispatch. Only minimal completion columns are persisted.
struct V2DurableOwnerCombinedWrite: Sendable {
    let commands: [Int: V2MessageSendOperationCommand]
    let resolvedAtMilliseconds: UInt64

    func receipts(for appends: [PreparedDirectRoomLogAppend]) throws -> [V2DurableSendBatchPermanentReceipt] {
        try appends.map { try receipt(for: $0) }
    }

    func receipt(for append: PreparedDirectRoomLogAppend) throws -> V2DurableSendBatchPermanentReceipt {
        guard let command = commands[append.originalIndex],
              command.command == append.request.command,
              let accepted = append.commit.outcome.acceptanceReceipt else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        let receipt = try V2MessageSendOperationReceipt(identity: command.identity, fingerprint: command.fingerprint,
            outcome: .accepted(.init(messageID: accepted.messageID, roomSequence: accepted.roomSequence)),
            resolvedAtMilliseconds: resolvedAtMilliseconds)
        return .init(receipt: receipt, domainFingerprint: command.command.fingerprint)
    }
}
