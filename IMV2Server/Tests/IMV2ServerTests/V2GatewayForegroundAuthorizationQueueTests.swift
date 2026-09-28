import Foundation
@testable import IMV2Server
import NIOCore
import NIOEmbedded
import Synchronization
import Testing

@Suite("V2 gateway foreground authorization at write time")
struct V2GatewayForegroundAuthorizationQueueTests {
    @Test("an expired or revoked queued frame is omitted when writability returns", arguments: [false, true])
    func queuedFrameRevokedBeforeDrain(expires: Bool) throws {
        let channel = EmbeddedChannel()
        _ = try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
        channel.isWritable = false
        let clock = Mutex(10)
        let authorization = V2GatewayForegroundAuthorization(sessionIsLive: { clock.withLock { $0 < 11 } })
        let writer = V2NIOGatewayForegroundWriter(channel: channel, scheduler: .init())
        writer.submit(ByteBuffer(bytes: [1]), isAuthorizedToWrite: { authorization.isAuthorizedToWrite() })
        channel.embeddedEventLoop.run()
        if expires { clock.withLock { $0 = 11 } }
        else { authorization.invalidate() }
        channel.isWritable = true
        writer.resumeAfterWritabilityChange()
        channel.embeddedEventLoop.run()

        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)
        #expect(!writer.hasPendingFrames)
        #expect(try channel.finish().isClean)
    }
}
