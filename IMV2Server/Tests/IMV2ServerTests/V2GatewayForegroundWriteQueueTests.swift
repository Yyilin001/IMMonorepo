@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import NIOCore
import NIOEmbedded
import Testing
@testable import IMV2ServerGateway

@Suite("V2 gateway foreground write queue")
struct V2GatewayForegroundWriteQueueTests {
    @Test("preserves every admitted live frame in FIFO drain order")
    func preservesFIFOAcrossBoundedDrains() throws {
        var queue = V2GatewayForegroundWriteQueue(
            maximumQueuedBytes: 64,
            maximumQueuedFrames: 8
        )
        for value in 1...5 {
            #expect(queue.append(ByteBuffer(bytes: [UInt8(value)])) == .queued)
        }

        let firstCandidate = queue.popBatch(maximumFrames: 2, maximumBytes: 64)
        let secondCandidate = queue.popBatch(maximumFrames: 2, maximumBytes: 64)
        let thirdCandidate = queue.popBatch(maximumFrames: 2, maximumBytes: 64)
        let first = try #require(firstCandidate)
        let second = try #require(secondCandidate)
        let third = try #require(thirdCandidate)

        #expect(first.frames == [ByteBuffer(bytes: [1]), ByteBuffer(bytes: [2])])
        #expect(second.frames == [ByteBuffer(bytes: [3]), ByteBuffer(bytes: [4])])
        #expect(third.frames == [ByteBuffer(bytes: [5])])
        #expect(queue.isEmpty)
        #expect(queue.queuedBytes == 0)
    }

    @Test("retains an ordered prefix plus the newest recovery waterline on overflow")
    func overflowRetainsPrefixAndLatestRecoveryFrame() throws {
        var queue = V2GatewayForegroundWriteQueue(
            maximumQueuedBytes: 64,
            maximumQueuedFrames: 2
        )
        #expect(queue.append(ByteBuffer(bytes: [1])) == .queued)
        #expect(queue.append(ByteBuffer(bytes: [2])) == .queued)
        #expect(queue.append(ByteBuffer(bytes: [3])) == .recoveryQueued)
        #expect(queue.append(ByteBuffer(bytes: [4])) == .recoveryReplaced)
        #expect(queue.count == 3)

        var drained: [ByteBuffer] = []
        while let batch = queue.popBatch(maximumFrames: 1, maximumBytes: 64) {
            drained.append(contentsOf: batch.frames)
        }
        #expect(drained == [
            ByteBuffer(bytes: [1]), ByteBuffer(bytes: [2]), ByteBuffer(bytes: [4]),
        ])
        #expect(queue.isEmpty)
    }

    @Test("respects the byte budget while allowing one oversized protocol frame to progress")
    func drainUsesByteBudgetWithoutDeadlock() throws {
        var queue = V2GatewayForegroundWriteQueue(
            maximumQueuedBytes: 16,
            maximumQueuedFrames: 8
        )
        #expect(queue.append(ByteBuffer(bytes: Data(repeating: 1, count: 6))) == .queued)
        #expect(queue.append(ByteBuffer(bytes: Data(repeating: 2, count: 6))) == .queued)
        let firstCandidate = queue.popBatch(maximumFrames: 8, maximumBytes: 8)
        let first = try #require(firstCandidate)
        #expect(first.frames.count == 1)
        #expect(first.bytes == 6)

        let secondCandidate = queue.popBatch(maximumFrames: 8, maximumBytes: 8)
        let second = try #require(secondCandidate)
        #expect(second.frames.count == 1)
        #expect(second.bytes == 6)

        var oversized = V2GatewayForegroundWriteQueue(
            maximumQueuedBytes: 4,
            maximumQueuedFrames: 1
        )
        #expect(oversized.append(ByteBuffer(bytes: Data(repeating: 3, count: 9))) == .recoveryQueued)
        let recoveryCandidate = oversized.popBatch(maximumFrames: 1, maximumBytes: 4)
        let recovery = try #require(recoveryCandidate)
        #expect(recovery.bytes == 9)
        #expect(oversized.isEmpty)
    }

    @Test("one scheduled writer turn coalesces several complete protocol frames")
    func writerCoalescesFramesIntoOneNIOWrite() throws {
        let channel = EmbeddedChannel()
        _ = try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
        let writer = V2NIOGatewayForegroundWriter(
            channel: channel,
            scheduler: .init(),
            maximumQueuedBytes: 64,
            maximumQueuedFrames: 8,
            maximumDrainBytes: 64,
            maximumDrainFrames: 8
        )
        writer.submit(ByteBuffer(bytes: [1, 2]))
        writer.submit(ByteBuffer(bytes: [3, 4]))
        writer.submit(ByteBuffer(bytes: [5]))

        channel.embeddedEventLoop.run()
        let outputCandidate = try channel.readOutbound(as: ByteBuffer.self)
        let output = try #require(outputCandidate)
        #expect(Array(output.readableBytesView) == [1, 2, 3, 4, 5])
        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)
        #expect(try channel.finish().isClean)
    }

    @Test("one-frame drain preserves prepared ByteBuffer storage across the channel write")
    func writerReusesPreparedSingleFrameStorage() throws {
        let channel = EmbeddedChannel()
        _ = try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
        let writer = V2NIOGatewayForegroundWriter(
            channel: channel,
            scheduler: .init(),
            maximumQueuedBytes: 64,
            maximumQueuedFrames: 8,
            maximumDrainBytes: 64,
            maximumDrainFrames: 8
        )
        var prepared = ByteBuffer(bytes: [1, 2, 3, 4])
        let preparedAddress = prepared.withUnsafeReadableBytes {
            UInt(bitPattern: $0.baseAddress)
        }
        writer.submit(prepared)
        // Mutating this independent value must detach and must not alter the
        // already-enqueued immutable frame.
        prepared.setInteger(UInt8(9), at: prepared.readerIndex)

        channel.embeddedEventLoop.run()
        let outputCandidate = try channel.readOutbound(as: ByteBuffer.self)
        let output = try #require(outputCandidate)
        let outputAddress = output.withUnsafeReadableBytes {
            UInt(bitPattern: $0.baseAddress)
        }
        #expect(Array(output.readableBytesView) == [1, 2, 3, 4])
        #expect(outputAddress == preparedAddress)
        #expect(try channel.finish().isClean)
    }

    @Test("one group batch schedules all writers sharing an event-loop lane")
    func groupBatchSchedulesWritersByLane() throws {
        let scheduler = V2NIOForegroundWriteScheduler()
        let eventLoop = EmbeddedEventLoop()
        let firstChannel = EmbeddedChannel(loop: eventLoop)
        let secondChannel = EmbeddedChannel(loop: eventLoop)
        _ = try firstChannel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
        _ = try secondChannel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 2))
        let firstWriter = V2NIOGatewayForegroundWriter(
            channel: firstChannel,
            scheduler: scheduler
        )
        let secondWriter = V2NIOGatewayForegroundWriter(
            channel: secondChannel,
            scheduler: scheduler
        )

        V2NIOGatewayForegroundWriter.submitBatch([
            .init(writer: firstWriter, bytes: ByteBuffer(bytes: [1, 2])),
            .init(writer: secondWriter, bytes: ByteBuffer(bytes: [3, 4])),
        ])
        eventLoop.run()

        let firstCandidate = try firstChannel.readOutbound(as: ByteBuffer.self)
        let secondCandidate = try secondChannel.readOutbound(as: ByteBuffer.self)
        let first = try #require(firstCandidate)
        let second = try #require(secondCandidate)
        #expect(Array(first.readableBytesView) == [1, 2])
        #expect(Array(second.readableBytesView) == [3, 4])
        #expect(try firstChannel.finish().isClean)
        #expect(try secondChannel.finish().isClean)
    }

    @Test("a non-writable channel retains its FIFO until writability resumes")
    func writerRetainsFramesAcrossNonWritableInterval() throws {
        let channel = EmbeddedChannel()
        _ = try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
        channel.isWritable = false
        let writer = V2NIOGatewayForegroundWriter(
            channel: channel,
            scheduler: .init(),
            maximumQueuedBytes: 64,
            maximumQueuedFrames: 8,
            maximumDrainBytes: 64,
            maximumDrainFrames: 8
        )
        writer.submit(ByteBuffer(bytes: [7]))
        writer.submit(ByteBuffer(bytes: [8]))
        channel.embeddedEventLoop.run()
        #expect(writer.hasPendingFrames)
        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)

        channel.isWritable = true
        writer.resumeAfterWritabilityChange()
        channel.embeddedEventLoop.run()
        let outputCandidate = try channel.readOutbound(as: ByteBuffer.self)
        let output = try #require(outputCandidate)
        #expect(Array(output.readableBytesView) == [7, 8])
        #expect(!writer.hasPendingFrames)
        #expect(try channel.finish().isClean)
    }

    @Test("non-writable writer drains its prefix and latest recovery frame after resuming")
    func writerDrainsLatestRecoveryAfterWritabilityResumes() throws {
        let channel = EmbeddedChannel()
        _ = try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
        channel.isWritable = false
        let writer = V2NIOGatewayForegroundWriter(
            channel: channel,
            scheduler: .init(),
            maximumQueuedBytes: 2,
            maximumQueuedFrames: 2,
            maximumDrainBytes: 2,
            maximumDrainFrames: 2
        )
        for value in 1...4 { writer.submit(ByteBuffer(bytes: [UInt8(value)])) }
        channel.embeddedEventLoop.run()
        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)

        channel.isWritable = true
        writer.resumeAfterWritabilityChange()
        channel.embeddedEventLoop.run()
        var drained: [UInt8] = []
        while let buffer = try channel.readOutbound(as: ByteBuffer.self) {
            drained.append(contentsOf: buffer.readableBytesView)
        }
        #expect(drained == [1, 2, 4])
        #expect(try channel.finish().isClean)
    }
}
