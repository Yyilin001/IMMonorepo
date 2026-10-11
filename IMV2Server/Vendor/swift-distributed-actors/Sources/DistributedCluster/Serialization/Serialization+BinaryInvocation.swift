// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIO
import NIOFoundationCompat

/// Versioned invocation framing. Argument bytes retain their original codec.
internal final class BinaryInvocationSerializer: Serializer<InvocationMessage> {
    private let allocator: ByteBufferAllocator
    private static let magic: UInt32 = 0x53414301
    private enum Failure: Error { case invalidFrame }

    init(_ allocator: ByteBufferAllocator) { self.allocator = allocator; super.init() }

    override func serialize(_ message: InvocationMessage) throws -> Serialization.Buffer {
        var buffer = allocator.buffer(capacity: 28 + message.targetIdentifier.utf8.count + message.genericSubstitutions.reduce(0) { $0 + 4 + $1.utf8.count } + message.arguments.reduce(0) { $0 + 4 + $1.count })
        buffer.writeInteger(Self.magic)
        var uuid = message.callID.uuid
        withUnsafeBytes(of: &uuid) { buffer.writeBytes($0) }
        try writeString(message.targetIdentifier, to: &buffer)
        try writeCount(message.genericSubstitutions.count, to: &buffer)
        for type in message.genericSubstitutions { try writeString(type, to: &buffer) }
        try writeCount(message.arguments.count, to: &buffer)
        for argument in message.arguments { try write(argument, to: &buffer) }
        return .nioByteBuffer(buffer)
    }

    override func deserialize(from source: Serialization.Buffer) throws -> InvocationMessage {
        var buffer = source.asByteBuffer(allocator: allocator)
        guard buffer.readInteger(as: UInt32.self) == Self.magic,
              let uuidBytes = buffer.readSlice(length: 16) else { throw Failure.invalidFrame }
        let uuid = uuidBytes.withUnsafeReadableBytes { $0.loadUnaligned(as: uuid_t.self) }
        let target = try readString(from: &buffer)
        let genericCount = try readCount(from: &buffer)
        var types: [String] = []; types.reserveCapacity(genericCount)
        for _ in 0..<genericCount { types.append(try readString(from: &buffer)) }
        let argumentCount = try readCount(from: &buffer)
        var arguments: [Data] = []; arguments.reserveCapacity(argumentCount)
        for _ in 0..<argumentCount { arguments.append(try read(from: &buffer)) }
        guard buffer.readableBytes == 0 else { throw Failure.invalidFrame }
        return InvocationMessage(callID: UUID(uuid: uuid), targetIdentifier: target,
            genericSubstitutions: types, arguments: arguments)
    }

    private func writeCount(_ count: Int, to buffer: inout ByteBuffer) throws {
        guard let value = UInt32(exactly: count) else { throw Failure.invalidFrame }
        buffer.writeInteger(value)
    }
    private func write(_ bytes: Data, to buffer: inout ByteBuffer) throws {
        try writeCount(bytes.count, to: &buffer); buffer.writeBytes(bytes)
    }
    private func readCount(from buffer: inout ByteBuffer) throws -> Int {
        guard let value = buffer.readInteger(as: UInt32.self),
              Int(value) <= buffer.readableBytes / 4 else { throw Failure.invalidFrame }
        return Int(value)
    }
    private func read(from buffer: inout ByteBuffer) throws -> Data {
        guard let length = buffer.readInteger(as: UInt32.self),
              Int(length) <= buffer.readableBytes,
              let bytes = buffer.readData(length: Int(length)) else { throw Failure.invalidFrame }
        return bytes
    }
    private func writeString(_ text: String, to buffer: inout ByteBuffer) throws {
        try writeCount(text.utf8.count, to: &buffer); buffer.writeString(text)
    }
    private func readString(from buffer: inout ByteBuffer) throws -> String {
        guard let length = buffer.readInteger(as: UInt32.self), Int(length) <= buffer.readableBytes,
              let bytes = buffer.readSlice(length: Int(length)),
              let text = bytes.withUnsafeReadableBytes({ String(bytes: $0, encoding: .utf8) }) else { throw Failure.invalidFrame }
        return text
    }
}

/// Success values opt in through their declared codec; errors retain the
/// existing typed error transport. No wire type name selects the return codec.
internal struct BinaryRemoteCallReply: AnyRemoteCallReply {
    let callID: ClusterSystem.CallID
    let value: Data?
    var thrownError: (any Error & Codable)? { nil }
    init(callID: ClusterSystem.CallID, value: Data) { self.callID = callID; self.value = value }
    init<Err: Error & Codable>(callID: ClusterSystem.CallID, error: Err) { self.callID = callID; self.value = nil }
}

internal final class BinaryRemoteCallReplySerializer: Serializer<BinaryRemoteCallReply> {
    private let allocator: ByteBufferAllocator
    private static let magic: UInt32 = 0x53415201
    private static let maximumBytes = 16_777_600
    private enum Failure: Error { case invalidFrame }
    init(_ allocator: ByteBufferAllocator) { self.allocator = allocator; super.init() }
    override func serialize(_ reply: BinaryRemoteCallReply) throws -> Serialization.Buffer {
        guard let bytes = reply.value, bytes.count <= Self.maximumBytes else { throw Failure.invalidFrame }
        var buffer = allocator.buffer(capacity: 24 + bytes.count)
        buffer.writeInteger(Self.magic)
        var id = reply.callID.uuid; withUnsafeBytes(of: &id) { buffer.writeBytes($0) }
        buffer.writeInteger(UInt32(bytes.count)); buffer.writeBytes(bytes)
        return .nioByteBuffer(buffer)
    }
    override func deserialize(from source: Serialization.Buffer) throws -> BinaryRemoteCallReply {
        var buffer = source.asByteBuffer(allocator: allocator)
        guard buffer.readInteger(as: UInt32.self) == Self.magic,
              let bytes = buffer.readSlice(length: 16), let count = buffer.readInteger(as: UInt32.self),
              count <= Self.maximumBytes, Int(count) == buffer.readableBytes,
              let value = buffer.readData(length: Int(count)) else { throw Failure.invalidFrame }
        let id = bytes.withUnsafeReadableBytes { $0.loadUnaligned(as: uuid_t.self) }
        return BinaryRemoteCallReply(callID: UUID(uuid: id), value: value)
    }
}
