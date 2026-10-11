import Foundation
import IMV2Core
import Testing
import SwiftProtobuf
@testable import IMV2ClientKit

struct V2MessageSendWireCodecTests {
    private func command() throws -> V2MessageSendOperationCommand {
        let text = "e\u{301} 👋 @alice link"
        let entity = try V2MessageEntity(offsetUTF16: 0, lengthUTF16: 2, kind: .bold)
        let link = try V2MessageEntity(offsetUTF16: 13, lengthUTF16: 4, kind: .link, linkURL: URL(string: "https://example.com/a?b=1")!)
        let payload = try V2SendMessageCommand(
            roomID: RoomID("room-1"), senderUserID: UserID("user-1"), clientMessageID: ClientMessageID("client-1"),
            text: text, media: [.init(mediaID: try MediaID("media-1"))],
            mentions: [.user(try UserID("alice")), .everyone], entities: [entity, link],
            replyTo: .init(messageID: try MessageID("reply-1")), limits: .init(maxUTF8Bytes: 1_048_576)
        )
        return try .init(command: payload, firstSubmissionDeadlineMilliseconds: 1_800_000_000_000)
    }

    @Test func commandAndRecoveryPreserveDomainIdentityAndFingerprints() throws {
        let value = try command()
        let wire = try V2MessageSendOperationWireCodec.encode(command: value)
        let decoded = try V2MessageSendOperationWireCodec.decode(command: wire)
        let fromJSON = try JSONDecoder().decode(V2MessageSendOperationCommand.self, from: JSONEncoder().encode(value))
        #expect(decoded == fromJSON)
        #expect(try decoded.identity == value.identity)
        #expect(try decoded.fingerprint == value.fingerprint)
        #expect(decoded.command.fingerprint == value.command.fingerprint)
        let recovery = try V2MessageSendOperationRecoveryRequest(identity: value.identity, fingerprint: value.fingerprint,
            domainFingerprint: value.command.fingerprint)
        #expect(try V2MessageSendOperationWireCodec.decode(recovery: V2MessageSendOperationWireCodec.encode(recovery: recovery)) == recovery)
        var mutated = wire
        mutated.domainFingerprint[0] ^= 1
        #expect(throws: V2MessageSendOperationWireCodecError.fingerprintMismatch) {
            _ = try V2MessageSendOperationWireCodec.decode(command: mutated)
        }
    }

    @Test func everyResultBranchRoundTrips() throws {
        let value = try command()
        let identity = try value.identity
        let fingerprint = try value.fingerprint
        let accepted = try V2MessageSendOperationReceipt(identity: identity, fingerprint: fingerprint,
            outcome: .accepted(.init(messageID: MessageID("message-1"), roomSequence: 9)), resolvedAtMilliseconds: 1_800_000_000_001)
        let rejected = try V2MessageSendOperationReceipt(identity: identity, fingerprint: fingerprint,
            outcome: .rejected(.directPolicyDenied), resolvedAtMilliseconds: 1_800_000_000_002)
        let hint = try V2MessageOperationRetryHint(identity: identity, fingerprint: fingerprint, reason: .rateLimited, retryAfterMilliseconds: 7_000)
        let results: [V2MessageSendOperationRecoveryResult] = [.receipt(accepted), .receipt(rejected), .deferred(hint), .unresolved, .fingerprintConflict]
        for result in results {
            #expect(try V2MessageSendOperationWireCodec.decode(result: V2MessageSendOperationWireCodec.encode(result: result)) == result)
        }
        // The retired closed field cannot be decoded as a terminal send result.
        var retired = V2MessageSendOperationWireCodec.encode(result: .receipt(accepted))
        retired.receipt.outcome = nil
        var bytes = try retired.receipt.serializedData()
        bytes.append(contentsOf: [0x30, 0x01]) // field 6, boolean true
        retired.receipt = try IMV2MessageSendOperationReceipt(serializedBytes: bytes)
        #expect(throws: V2MessageSendOperationWireCodecError.invalidField) {
            _ = try V2MessageSendOperationWireCodec.decode(result: retired)
        }
        var invalid = IMV2MessageSendOperationResult()
        invalid.unresolved = false
        #expect(throws: V2MessageSendOperationWireCodecError.invalidField) {
            _ = try V2MessageSendOperationWireCodec.decode(result: invalid)
        }
    }
}
