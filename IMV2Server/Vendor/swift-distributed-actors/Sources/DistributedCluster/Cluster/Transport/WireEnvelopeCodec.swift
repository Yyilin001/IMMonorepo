// SPDX-License-Identifier: Apache-2.0
import NIO
import SwiftProtobuf

/// The existing Envelope protobuf wire format, with its opaque payload kept in
/// NIO storage. Routing metadata still uses the generated protobuf validators.
/// No business type, manifest registration, or invocation semantics change.
internal enum WireEnvelopeCodec {
    enum Failure: Error { case malformed }

    static func encode(_ envelope: Wire.Envelope, context: Serialization.Context,
                       allocator: ByteBufferAllocator) throws -> ByteBuffer {
        let recipient: [UInt8] = try envelope.recipient.toProto(context: context).serializedBytes()
        var manifest = _ProtoManifest()
        manifest.serializerID = envelope.manifest.serializerID.value
        if let hint = envelope.manifest.hint { manifest.hint = hint }
        let metadata: [UInt8] = try manifest.serializedBytes()
        var out = allocator.buffer(capacity: recipient.count + metadata.count + envelope.payload.count + 32)
        field(1, bytes: recipient, into: &out)
        field(2, bytes: metadata, into: &out)
        if envelope.payload.count > 0 {
            out.writeInteger(UInt8(26)); varint(UInt64(envelope.payload.count), into: &out)
            switch envelope.payload {
            case .data(let data): out.writeBytes(data)
            case .nioByteBuffer(let bytes): out.writeImmutableBuffer(bytes)
            case ._PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE:
                throw Failure.malformed
            }
        }
        return out
    }

    static func decode(_ source: ByteBuffer, context: Serialization.Context) throws -> Wire.Envelope {
        var input = source
        var recipient = _ProtoActorID(), manifest = _ProtoManifest()
        var hasRecipient = false, hasManifest = false
        var payload = source.getSlice(at: source.readerIndex, length: 0)!
        while input.readableBytes > 0 {
            let tag = try readVarint(&input)
            let field = tag >> 3, wire = tag & 7
            guard field > 0, field <= 0x1fff_ffff else { throw Failure.malformed }
            switch field {
            case 1, 2, 3:
                guard wire == 2 else { throw Failure.malformed }
                let bytes = try slice(&input)
                switch field {
                case 1:
                    try bytes.withUnsafeReadableBytes { try recipient.merge(serializedBytes: $0) }
                    hasRecipient = true
                case 2:
                    try bytes.withUnsafeReadableBytes { try manifest.merge(serializedBytes: $0) }
                    hasManifest = true
                default: payload = bytes // Protobuf singular bytes use last-one-wins.
                }
            default: try skip(tag, from: &input, depth: 0)
            }
        }
        guard hasRecipient else { throw WireEnvelopeError.emptyRecipient }
        guard hasManifest else { throw WireEnvelopeError.missingManifest }
        return try .init(recipient: ActorID(fromProto: recipient, context: context),
                         payload: .nioByteBuffer(payload), manifest: Serialization.Manifest(fromProto: manifest))
    }

    private static func field(_ number: UInt8, bytes: [UInt8], into out: inout ByteBuffer) {
        out.writeInteger((number << 3) | 2)
        varint(UInt64(bytes.count), into: &out)
        out.writeBytes(bytes)
    }
    private static func varint(_ value: UInt64, into out: inout ByteBuffer) {
        var value = value
        while value > 127 { out.writeInteger(UInt8(value & 127) | 128); value >>= 7 }
        out.writeInteger(UInt8(value))
    }
    private static func readVarint(_ input: inout ByteBuffer) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard let byte = input.readInteger(as: UInt8.self), shift != 63 || byte <= 1 else { throw Failure.malformed }
            value |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return value }
        }
        throw Failure.malformed
    }
    private static func slice(_ input: inout ByteBuffer) throws -> ByteBuffer {
        let count = try readVarint(&input)
        guard count <= UInt64(input.readableBytes), let bytes = input.readSlice(length: Int(count)) else { throw Failure.malformed }
        return bytes
    }
    private static func skip(_ tag: UInt64, from input: inout ByteBuffer, depth: Int) throws {
        guard tag >> 3 > 0, tag >> 3 <= 0x1fff_ffff else { throw Failure.malformed }
        switch tag & 7 {
        case 0: _ = try readVarint(&input)
        case 1: guard input.readSlice(length: 8) != nil else { throw Failure.malformed }
        case 2: _ = try slice(&input)
        case 3:
            guard depth < 100 else { throw Failure.malformed }
            while true {
                let next = try readVarint(&input)
                if next & 7 == 4 {
                    guard next >> 3 == tag >> 3 else { throw Failure.malformed }
                    break
                }
                try skip(next, from: &input, depth: depth + 1)
            }
        case 5: guard input.readSlice(length: 4) != nil else { throw Failure.malformed }
        default: throw Failure.malformed
        }
    }
}
