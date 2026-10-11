import Foundation
import IMV2Core
import NIOCore
import NIOFoundationCompat
import SwiftProtobuf

/// Protobuf owns a contiguous NIO allocation with room for the wire header.
/// The protocol's repeating initializer really initializes every requested byte.
struct V2ProtobufOutputBytes: SwiftProtobufContiguousBytes {
    var buffer: ByteBuffer
    var count: Int { buffer.readableBytes - V2Frame.headerLength }
    init(repeating: UInt8, count: Int) {
        buffer = ByteBufferAllocator().buffer(capacity: V2Frame.headerLength + count)
        buffer.writeRepeatingByte(0, count: V2Frame.headerLength)
        buffer.writeRepeatingByte(repeating, count: count)
    }
    init<S: Sequence>(_ sequence: S) where S.Element == UInt8 {
        buffer = ByteBufferAllocator().buffer(capacity: V2Frame.headerLength + sequence.underestimatedCount)
        buffer.writeRepeatingByte(0, count: V2Frame.headerLength)
        buffer.writeBytes(sequence)
    }
    consuming func takeBuffer() -> ByteBuffer { buffer }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try buffer.withUnsafeReadableBytes { try body(UnsafeRawBufferPointer(rebasing: $0.dropFirst(V2Frame.headerLength))) }
    }
    mutating func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try buffer.withUnsafeMutableReadableBytes { try body(UnsafeMutableRawBufferPointer(rebasing: $0.dropFirst(V2Frame.headerLength))) }
    }
}

/// Immutable owned bytes can cross task boundaries and be shared for fanout.
/// Data conversion is confined to the public Data-based transport boundary.
struct V2GatewayOutboundFrame: Sendable {
    let header: V2Frame
    let buffer: ByteBuffer
    var payloadCount: Int { buffer.readableBytes - V2Frame.headerLength }
    init(header: V2Frame, payload: consuming V2ProtobufOutputBytes) {
        self.header = header
        var owned = payload.takeBuffer()
        owned.setInteger(V2Frame.magic, at: 0, endianness: .big)
        owned.setInteger(header.version, at: 2)
        owned.setInteger(header.flags.rawValue, at: 3)
        owned.setInteger(header.command.rawValue, at: 4, endianness: .big)
        owned.setInteger(header.requestID, at: 6, endianness: .big)
        owned.setInteger(UInt32(owned.readableBytes - V2Frame.headerLength), at: 14, endianness: .big)
        buffer = consume owned
    }
    init(_ frame: V2Frame) {
        self.init(header: .init(version: frame.version, flags: frame.flags, command: frame.command,
            requestID: frame.requestID, payload: Data()), payload: V2ProtobufOutputBytes(frame.payload))
    }
    var dataFrame: V2Frame {
        .init(version: header.version, flags: header.flags, command: header.command, requestID: header.requestID,
            payload: buffer.getData(at: buffer.readerIndex + V2Frame.headerLength, length: payloadCount)!)
    }
    func validate(limits: V2FrameLimits) throws {
        try V2FrameCodec.validateForEncoding(header, limits: limits)
        guard payloadCount <= limits.maximumPayloadBytes(for: header.command, version: header.version) else {
            throw V2FrameCodecError.payloadTooLarge(payloadCount)
        }
    }
}
