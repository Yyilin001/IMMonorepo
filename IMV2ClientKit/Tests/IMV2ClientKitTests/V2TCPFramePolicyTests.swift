import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Typed TCP lifecycle policies")
struct V2TCPFramePolicyTests {
    @Test func directionsAndReplayAreExplicit() throws {
        #expect(V2TCPFramePolicy.policy(for: .clientHello(.init())) == .handshake)
        #expect(V2TCPFramePolicy.policy(for: .authenticate(.init())) == .handshake)
        #expect(V2TCPFramePolicy.policy(for: .syncAck(.init())) == .control)
        #expect(V2TCPFramePolicy.policy(for: .snapshotAck(.init())) == .control)
        #expect(V2TCPFramePolicy.policy(for: .setTypingState(.init())) == .ephemeral)
        #expect(V2TCPFramePolicy.policy(for: .syncPull(.init())) == .read)
        #expect(V2TCPFramePolicy.policy(for: .recordReadReceipt(.init())) == .mutation)
        #expect(V2TCPFramePolicy.policy(for: .messageAccepted(.init())) == .serverOnly)
        for policy in [V2TCPFramePolicy.handshake, .control, .ephemeral, .read, .mutation, .serverOnly] {
            #expect(!policy.permitsAutomaticReplay)
        }
        #expect(throws: V2TLSFrameConnectionError.unexpectedResponse) {
            try V2TCPFramePolicy.serverOnly.context(service: "realtime", scoped: nil)
        }
    }
    @Test func domainRecoveryCannotConsumeReservedCapacity() throws {
        let recovery = V2NetworkWorkContext(service: "realtime", priority: .critical, kind: .authentication,
            orderingKey: "room", isRetry: true)
        let domain = try V2TCPFramePolicy.mutation.context(service: "realtime", scoped: recovery)
        #expect(domain.kind == .ordinary)
        #expect(domain.isRetry)
        #expect(domain.orderingKey == "room")
        let control = try V2TCPFramePolicy.control.context(service: "realtime", scoped: recovery)
        #expect(control.kind == .authentication)
        #expect(!control.isRetry)
        #expect(control.orderingKey == nil)
        let typing = try V2TCPFramePolicy.ephemeral.context(service: "realtime", scoped: recovery)
        #expect(typing.kind == .ordinary)
        #expect(!typing.isRetry)
        #expect(typing.orderingKey == nil)
    }
}
