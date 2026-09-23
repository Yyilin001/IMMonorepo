import NIOCore
import NIOEmbedded
@testable import DistributedCluster
import XCTest

final class BoundedFramingTests: XCTestCase {
    func testSettingRejectsNonFiniteOrUnrepresentableLimits() throws {
        XCTAssertEqual(ClusterInboundFrameLimit.default.bytes, 16 * 1024 * 1024)
        XCTAssertThrowsError(try ClusterInboundFrameLimit(bytes: 0))
        XCTAssertThrowsError(try ClusterInboundFrameLimit(bytes: -1))
        XCTAssertThrowsError(try ClusterInboundFrameLimit(bytes: Int(Int32.max) + 1))
        XCTAssertEqual(try ClusterInboundFrameLimit(bytes: 8).bytes, 8)
    }

    func testBothPipelinesRejectOversizedDeclaredLengthBeforeBody() throws {
        for handlers in [
            ClusterTransportFraming.accepting(limit: try .init(bytes: 8)),
            ClusterTransportFraming.initiating(limit: try .init(bytes: 8)),
        ] {
            let channel = EmbeddedChannel()
            let errors = FrameErrorCapture()
            for (_, handler) in handlers { try channel.pipeline.addHandler(handler).wait() }
            try channel.pipeline.addHandler(errors).wait()
            try channel.connect(to: SocketAddress(unixDomainSocketPath: "/bounded-framing-test")).wait()

            XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(bytes: [0, 0])))
            XCTAssertTrue(channel.isActive)
            XCTAssertTrue(errors.errors.isEmpty)
            _ = try? channel.writeInbound(ByteBuffer(bytes: [0, 9]))
            XCTAssertEqual(errors.errors.count, 1)
            XCTAssertEqual(errors.errors.first as? ClusterInboundFrameError,
                .declaredLengthExceedsLimit(declared: 9, maximum: 8))
            XCTAssertFalse(channel.isActive, "the channel must close on the header alone")
            _ = try? channel.finish()
        }
    }

    func testExactBoundaryFragmentationAndMultipleFramesInBothPipelines() throws {
        for handlers in [
            ClusterTransportFraming.accepting(limit: try .init(bytes: 8)),
            ClusterTransportFraming.initiating(limit: try .init(bytes: 8)),
        ] {
            let channel = EmbeddedChannel()
            let errors = FrameErrorCapture()
            for (_, handler) in handlers { try channel.pipeline.addHandler(handler).wait() }
            try channel.pipeline.addHandler(errors).wait()
            try channel.connect(to: SocketAddress(unixDomainSocketPath: "/bounded-framing-test")).wait()

            XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(bytes: [0, 0, 0])))
            XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(bytes: [8, 97, 98, 99])))
            XCTAssertNil(try channel.readInbound(as: ByteBuffer.self))
            XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(bytes: [100, 101, 102, 103, 104])))
            XCTAssertEqual(try nextString(channel), "abcdefgh")

            var twoFrames = ByteBuffer()
            twoFrames.writeInteger(UInt32(1), endianness: .big)
            twoFrames.writeString("x")
            twoFrames.writeInteger(UInt32(2), endianness: .big)
            twoFrames.writeString("yz")
            XCTAssertNoThrow(try channel.writeInbound(twoFrames))
            XCTAssertEqual(try nextString(channel), "x")
            XCTAssertEqual(try nextString(channel), "yz")
            XCTAssertTrue(errors.errors.isEmpty)
            XCTAssertTrue(channel.isActive)
            _ = try channel.finish()
        }
    }

    private func nextString(_ channel: EmbeddedChannel) throws -> String? {
        guard let frame = try channel.readInbound(as: ByteBuffer.self) else { return nil }
        return frame.getString(at: frame.readerIndex, length: frame.readableBytes)
    }
}

private final class FrameErrorCapture: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    var errors: [any Error] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.fireChannelRead(data) }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { errors.append(error) }
}
