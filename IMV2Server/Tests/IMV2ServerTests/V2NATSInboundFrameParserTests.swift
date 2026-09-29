@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 NATS inbound frame parser")
struct V2NATSInboundFrameParserTests {
    @Test("group broker can opt into a larger bounded payload")
    func acceptsConfiguredLargePayload() throws {
        let payload = Data(repeating: 7, count: 24 * 1_024)
        var parser = V2NATSInboundFrameParser(
            invalidMessagePolicy: .closeChannel,
            maximumPayloadBytes: 32 * 1_024
        )

        let outputs = parser.consume(natsMessage(payload))

        #expect(outputs.count == 1)
        guard case .payload(let subject, let decoded) = try #require(outputs.first) else {
            Issue.record("expected one decoded NATS payload")
            return
        }
        #expect(subject == "imv2.test")
        #expect(decoded == payload)
    }

    @Test("the small-protocol default still rejects the same large payload")
    func defaultLimitRemainsNarrow() throws {
        let payload = Data(repeating: 8, count: 24 * 1_024)
        var parser = V2NATSInboundFrameParser(invalidMessagePolicy: .closeChannel)

        let outputs = parser.consume(natsMessage(payload))

        #expect(outputs.count == 1)
        guard case .closeChannel = try #require(outputs.first) else {
            Issue.record("expected the default parser to close")
            return
        }
    }

    @Test("coalesced legal frames are bounded per payload, not per socket read")
    func acceptsCoalescedConfiguredPayloads() {
        let first = Data(repeating: 1, count: 20 * 1_024)
        let second = Data(repeating: 2, count: 20 * 1_024)
        var wire = natsMessage(first)
        wire.append(natsMessage(second))
        var parser = V2NATSInboundFrameParser(
            invalidMessagePolicy: .closeChannel,
            maximumPayloadBytes: 32 * 1_024
        )

        let outputs = parser.consume(wire)

        let decoded = outputs.compactMap { output -> Data? in
            guard case .payload(_, let payload) = output else { return nil }
            return payload
        }
        #expect(decoded == [first, second])
    }

    @Test("the delivered subject is preserved and malformed subjects fail closed")
    func validatesDeliveredSubject() throws {
        let payload = Data([7])
        var replyFrame = Data("MSG imv2.room.a 1 reply.inbox 1\r\n".utf8)
        replyFrame.append(payload)
        replyFrame.append(Data("\r\n".utf8))
        var parser = V2NATSInboundFrameParser(invalidMessagePolicy: .closeChannel)

        guard case .payload(let subject, let decoded) = try #require(
            parser.consume(replyFrame).first
        ) else {
            Issue.record("expected a subject-bound payload")
            return
        }
        #expect(subject == "imv2.room.a")
        #expect(decoded == payload)

        var invalid = V2NATSInboundFrameParser(invalidMessagePolicy: .closeChannel)
        guard case .closeChannel = try #require(
            invalid.consume(Data("MSG imv2.* 1 0\r\n\r\n".utf8)).first
        ) else {
            Issue.record("expected malformed delivered subject to close")
            return
        }
    }

    private func natsMessage(_ payload: Data) -> Data {
        var wire = Data("MSG imv2.test 1 \(payload.count)\r\n".utf8)
        wire.append(payload)
        wire.append(Data("\r\n".utf8))
        return wire
    }
}
