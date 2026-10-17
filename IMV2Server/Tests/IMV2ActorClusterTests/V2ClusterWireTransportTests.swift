import Distributed
@testable import DistributedCluster
import Foundation
import Logging
import NIOCore
import NIOEmbedded
import SwiftProtobuf
import Testing

@Suite("Cluster wire flush ownership", .serialized, .timeLimit(.minutes(1)))
struct V2ClusterWireTransportTests {
    @Test func coalescesReadyFramesAndFlushesAnIsolatedCompletion() async throws {
        var settings = ClusterSystemSettings(name: "wire-test", host: "127.0.0.1", port: Int.random(in: 30000...44999))
        settings.threadPoolSize = 1; settings.downingStrategy = .none; settings.onDownAction = .none
        let system = await ClusterSystem("wire-test", settings: settings)
        do {
            let actor = WireProbe(actorSystem: system)
            let envelope = Wire.Envelope(recipient: actor.id, payload: .nioByteBuffer(ByteBuffer(bytes: [1, 2, 3])),
                manifest: .init(serializerID: ._ProtobufRepresentable, hint: "test"))
            let counter = FlushCounter()
            let handler = WireEnvelopeHandler(serialization: system.serialization, log: Logger(label: "test"))
            let channel = EmbeddedChannel(handlers: [counter, handler])
            try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
            // An upstream flush preceding asynchronous serialization must not
            // consume the later encoded frame's eventual flush.
            channel.pipeline.flush()
            for _ in 0..<5 { channel.pipeline.write(NIOAny(envelope), promise: nil) }
            #expect(counter.flushes == 0)
            channel.embeddedEventLoop.run()
            #expect(counter.flushes == 1)
            for _ in 0..<5 { #expect(try channel.readOutbound(as: ByteBuffer.self) != nil) }
            channel.pipeline.write(NIOAny(envelope), promise: nil)
            channel.embeddedEventLoop.run()
            #expect(counter.flushes == 2)
            #expect(try channel.readOutbound(as: ByteBuffer.self) != nil)
            // Frame budget flushes without waiting for the scheduled turn.
            for _ in 0..<33 { channel.pipeline.write(NIOAny(envelope), promise: nil) }
            #expect(counter.flushes == 3)
            channel.embeddedEventLoop.run()
            #expect(counter.flushes == 4)
            for _ in 0..<33 { #expect(try channel.readOutbound(as: ByteBuffer.self) != nil) }
            let large = Wire.Envelope(recipient: actor.id,
                payload: .nioByteBuffer(ByteBuffer(bytes: Array(repeating: UInt8(7), count: 65536))),
                manifest: envelope.manifest)
            channel.pipeline.write(NIOAny(large), promise: nil)
            #expect(counter.flushes == 5)
            #expect(try channel.readOutbound(as: ByteBuffer.self) != nil)
            channel.pipeline.write(NIOAny(envelope), promise: nil)
            // Close drains accepted bytes and the later scheduled callback is inert.
            try await channel.close()
            #expect(counter.flushes == 6)
            #expect(try channel.readOutbound(as: ByteBuffer.self) != nil)
            channel.embeddedEventLoop.run()
            #expect(counter.flushes == 6)
            #expect(try channel.finish(acceptAlreadyClosed: true).isClean)
            try await system.shutdown().wait()
        } catch { try? await system.shutdown().wait(); throw error }
    }
    @Test func directEnvelopeCodecMatchesGeneratedPBAndRetainsPayloadStorage() async throws {
        var settings = ClusterSystemSettings(name: "wire-codec", host: "127.0.0.1", port: Int.random(in: 30000...44999))
        settings.threadPoolSize = 1; settings.downingStrategy = .none; settings.onDownAction = .none
        let system = await ClusterSystem("wire-codec", settings: settings)
        do {
            let actor = WireProbe(actorSystem: system), context = system.serialization.context
            for length in [0, 1, 127, 128, 65536] {
                let payload = ByteBuffer(bytes: Array(repeating: UInt8(7), count: length))
                let envelope = Wire.Envelope(recipient: actor.id, payload: .nioByteBuffer(payload),
                    manifest: .init(serializerID: ._ProtobufRepresentable, hint: "opaque"))
                let bytes = try WireEnvelopeCodec.encode(envelope, context: context, allocator: .init())
                let expected: [UInt8] = try envelope.toProto(context: context).serializedBytes()
                #expect(Array(bytes.readableBytesView) == expected)
                // Decode an envelope with a nonzero reader index.
                var source = ByteBuffer(bytes: [9, 9, 9]); source.writeImmutableBuffer(bytes)
                source.moveReaderIndex(forwardBy: 3)
                let decoded = try WireEnvelopeCodec.decode(source, context: context)
                #expect(decoded.recipient == envelope.recipient)
                #expect(decoded.manifest == envelope.manifest)
                guard case .nioByteBuffer(let retained) = decoded.payload else {
                    Issue.record("payload copied into Data"); continue
                }
                #expect(retained == payload)
                if length > 0 {
                    source.withUnsafeReadableBytes { original in
                        retained.withUnsafeReadableBytes { body in
                            let start = UInt(bitPattern: original.baseAddress!), address = UInt(bitPattern: body.baseAddress!)
                            #expect(address >= start && address + UInt(body.count) <= start + UInt(original.count))
                        }
                    }
                }
                // Unknown varint/group fields, duplicate merged metadata, and
                // last-one-wins bytes retain ordinary protobuf semantics.
                var extended = bytes
                extended.writeBytes([0xa0, 0x06, 1, 0xab, 0x06, 8, 1, 0xac, 0x06, 0x12, 0, 0x1a, 1, 99])
                let merged = try WireEnvelopeCodec.decode(extended, context: context)
                #expect(merged.payload.readData() == Data([99]))
                #expect(merged.manifest == envelope.manifest)
            }
            for bad: [UInt8] in [[], [0], [10, 127], [0x80], [0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,2], [0x2b,0x34]] {
                #expect(throws: (any Error).self) { try WireEnvelopeCodec.decode(ByteBuffer(bytes: bad), context: context) }
            }
            try await system.shutdown().wait()
        } catch { try? await system.shutdown().wait(); throw error }
    }

}
private distributed actor WireProbe {
    typealias ActorSystem = ClusterSystem
}
private final class FlushCounter: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    var flushes = 0
    func flush(context: ChannelHandlerContext) { flushes += 1; context.flush() }
}
