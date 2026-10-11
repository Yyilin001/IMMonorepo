import Foundation
import IMV2Core
import NIOCore
import NIOPosix
import IMV2ServerApplication
@testable import IMV2ServerGateway

/// 使用独立 NIO EventLoop 的本地 Channel 夹具，避免在异步测试线程之间共享 EmbeddedEventLoop。
final class V2GatewayForegroundChannelFixture: @unchecked Sendable {
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel: any Channel
    let writer: V2NIOGatewayForegroundWriter
    private let listener: any Channel
    private let client: any Channel

    init(record: @escaping @Sendable (Data) -> Void) async throws {
        let accepted = Self.group.next().makePromise(of: (any Channel).self)
        listener = try await ServerBootstrap(group: Self.group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(Recorder(record: record)).map {
                    accepted.succeed(channel)
                }
            }.bind(host: "127.0.0.1", port: 0).get()
        do {
            client = try await ClientBootstrap(group: Self.group)
                .connect(to: listener.localAddress!).get()
            channel = try await accepted.futureResult.get()
            writer = V2NIOGatewayForegroundWriter(channel: channel, scheduler: .init(), maximumDrainFrames: 1)
        } catch {
            try? await listener.close().get()
            throw error
        }
    }

    /// 测试断言前等待本轮已提交的 Channel 工作完成。
    func drain() {
        for _ in 0..<100 {
            try! channel.eventLoop.submit {}.wait()
            if !writer.hasPendingFrames { return }
        }
        preconditionFailure("foreground fixture failed to drain")
    }

    func writeAuthor(_ write: V2AuthorPresentationWrite,
                     record: @escaping @Sendable () -> Void) async -> Bool {
        (try? await channel.eventLoop.submit { [writer] in
            guard !writer.hasPendingFrames else { return false }
            return write.enqueueIfCurrent(record)
        }.get()) ?? false
    }

    func finish() {
        writer.finish()
        _ = channel.close()
        _ = client.close()
        _ = listener.close()
    }

    deinit { finish() }

    private final class Recorder: ChannelOutboundHandler, @unchecked Sendable {
        typealias OutboundIn = ByteBuffer
        private let record: @Sendable (Data) -> Void
        init(record: @escaping @Sendable (Data) -> Void) { self.record = record }
        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            record(Data(unwrapOutboundIn(data).readableBytesView))
            promise?.succeed(())
        }
    }
}

/// Concrete wire limits for connection-only fixtures. Socket tests supply their exact negotiated limits.
let v2FixtureForegroundFrameLimits: V2FrameLimits = {
    do {
        return try .init(maximumPayloadBytes: 4 * 1_024 * 1_024,
            acceptedVersions: IMV2ProtocolVersion.supportedVersions.union([0]))
    } catch {
        preconditionFailure("Invalid fixed gateway fixture limits")
    }
}()
