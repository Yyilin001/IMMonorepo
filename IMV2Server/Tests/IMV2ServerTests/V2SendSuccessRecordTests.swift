@testable import IMV2ServerInfrastructure
import Foundation
import IMV2Core
import Testing

struct V2SendSuccessRecordTests {
    private func command(deadline: UInt64 = 1_750_000_060_000) throws -> V2MessageSendOperationCommand {
        try .init(command: .init(roomID: .init(uuid: UUID()), senderUserID: .init(uuid: UUID()),
            clientMessageID: .init(uuid: UUID()), text: "accepted", limits: .init(maxUTF8Bytes: 64)),
            firstSubmissionDeadlineMilliseconds: deadline)
    }

    @Test("Operation recovery requires the original fingerprint and resolution time", arguments: [0, 1, 2])
    func missingMetadataIsRejected(missing: Int) throws {
        let command = try command(), domain = try command.command.fingerprint
        let row = V2SendSuccessRow(messageID: UUID(), roomSequence: 1,
            domainFingerprint: domain.digest, fingerprintVersion: Int16(domain.version),
            operationFingerprint: missing == 1 ? try command.fingerprint.digest : nil,
            resolvedAt: missing == 2 ? 1_750_000_000_123 : nil)
        #expect(throws: V2MessageOperationValidationError.invalidReceipt) {
            try row.result(identity: command.identity, fingerprint: command.fingerprint, domain: domain)
        }
    }

    @Test("Operation recovery preserves the committed time and rejects a changed deadline")
    func exactCommittedMetadata() throws {
        let command = try command(), domain = try command.command.fingerprint
        let row = V2SendSuccessRow(messageID: UUID(), roomSequence: 7,
            domainFingerprint: domain.digest, fingerprintVersion: Int16(domain.version),
            operationFingerprint: try command.fingerprint.digest, resolvedAt: 1_750_000_000_123)
        let result = try row.result(identity: command.identity, fingerprint: command.fingerprint, domain: domain)
        guard case .receipt(let receipt) = result else { Issue.record("Expected committed receipt"); return }
        #expect(receipt.resolvedAtMilliseconds == 1_750_000_000_123)
        let changed = try V2MessageSendOperationCommand(command: command.command,
            firstSubmissionDeadlineMilliseconds: command.firstSubmissionDeadlineMilliseconds + 1)
        #expect(try row.result(identity: changed.identity, fingerprint: changed.fingerprint, domain: domain) == .fingerprintConflict)
    }
}
