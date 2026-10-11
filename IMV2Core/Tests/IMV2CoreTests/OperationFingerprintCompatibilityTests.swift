import Foundation
import Testing
@testable import IMV2Core

struct OperationFingerprintCompatibilityTests {
    @Test("Streaming canonical bytes match an independent Python SHA-256 vector")
    func canonicalVector() throws {
        let fields: [V2OperationFingerprintField] = [
            .init("a", .absent), .init("b", .text("消息 e\u{301} 🌍")),
            .init("c", .unsigned(UInt64.max)), .init("d", .signed(Int64.min)),
            .init("e", .bytes(Data([0, 255, 16]))), .init("f", .flag(true)),
            .init("g", .orderedText(["", "é", "e\u{301}"]))
        ]
        let value = try V2OperationFingerprint(kind: .sendMessage, fields: fields.reversed())
        #expect(value.digest.map { String(format: "%02x", $0) }.joined() == "9dac9ff8941db9b2c3896ba5b5b28f40097b6ecb8f4eaf1e4528dab402d833f4")
        #expect(throws: V2OperationFingerprintError.duplicateField) {
            try V2OperationFingerprint(kind: .sendMessage, fields: fields + [fields[0]])
        }
    }

    @Test("Send cache matches the generic schema and stays outside the Codable contract")
    func immutableSendCache() throws {
        let domain = try V2SendMessageCommand(roomID: .init(uuid: UUID()),
            senderUserID: .init(uuid: UUID()), clientMessageID: .init(uuid: UUID()),
            text: "消息 e\u{301} 🌍", limits: .init(maxUTF8Bytes: 128))
        let send = try V2MessageSendOperationCommand(command: domain, firstSubmissionDeadlineMilliseconds: 1000)
        let generic = try V2OperationFingerprint(kind: .sendMessage, fields: [
            .init("identity", .text(send.identity.storageKey)),
            .init("domainFingerprintVersion", .unsigned(UInt64(domain.fingerprint.version))),
            .init("domainFingerprint", .bytes(domain.fingerprint.digest)),
            .init("firstSubmissionDeadline", .unsigned(1000))
        ])
        #expect(try send.fingerprint == generic)
        let json = try JSONEncoder().encode(send)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(object.keys) == ["command", "firstSubmissionDeadlineMilliseconds"])
        #expect(try JSONDecoder().decode(V2MessageSendOperationCommand.self, from: json) == send)
        #expect(send.estimatedRetainedBytes >= domain.text.utf8.count)
        let largerDomain = try V2SendMessageCommand(roomID: domain.roomID, senderUserID: domain.senderUserID,
            clientMessageID: domain.clientMessageID, text: domain.text + String(repeating: "x", count: 1000),
            limits: .init(maxUTF8Bytes: 2048))
        let larger = try V2MessageSendOperationCommand(command: largerDomain, firstSubmissionDeadlineMilliseconds: 1000)
        #expect(larger.estimatedRetainedBytes - send.estimatedRetainedBytes == 2000)
    }
}
