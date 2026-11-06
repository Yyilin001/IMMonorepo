import Foundation
import IMActorSystem
import IMV2Core
import NIOCore

// Explicit probe-only wire schemas. JSON remains solely in the signed fixture bodies.
extension ProbeRequest: IMWireValue {
    var wireByteCount: Int { 8 + 4 + roomID.rawValue.utf8.count + text.wireByteCount + 8 }
    static var wireTypeID: UInt32 { 200 }
    func encodeWire(into buffer: inout ByteBuffer) throws {
        try protocolVersion.encodeWire(into: &buffer)
        try buffer.imWriteString(roomID.rawValue, maximum: 128)
        try text.encodeWire(into: &buffer); try delayMilliseconds.encodeWire(into: &buffer)
    }
    static func decodeWire(from buffer: inout ByteBuffer) throws -> Self {
        try .init(protocolVersion: Int.decodeWire(from: &buffer), roomID: RoomID(buffer.imReadString(maximum: 128)),
                  text: String.decodeWire(from: &buffer), delayMilliseconds: Int.decodeWire(from: &buffer))
    }
}
extension ProbeReply: IMWireValue {
    var wireByteCount: Int { 4 + roomID.rawValue.utf8.count + text.wireByteCount + 16 }
    static var wireTypeID: UInt32 { 201 }
    func encodeWire(into buffer: inout ByteBuffer) throws {
        try buffer.imWriteString(roomID.rawValue, maximum: 128)
        try text.encodeWire(into: &buffer); try incarnation.encodeWire(into: &buffer)
    }
    static func decodeWire(from buffer: inout ByteBuffer) throws -> Self {
        try .init(roomID: RoomID(buffer.imReadString(maximum: 128)), text: String.decodeWire(from: &buffer),
                  incarnation: UUID.decodeWire(from: &buffer))
    }
}
extension ProbeDomainError: IMWireValue {
    var wireByteCount: Int { code.wireByteCount }
    static var wireTypeID: UInt32 { 202 }
    func encodeWire(into buffer: inout ByteBuffer) throws { try buffer.imWriteString(code) }
    static func decodeWire(from buffer: inout ByteBuffer) throws -> Self { try .init(code: buffer.imReadString()) }
}
extension SignedRequest: IMWireValue {
    var wireByteCount: Int { body.serviceID.wireByteCount + body.role.wireByteCount + 16 + 16 + 8 + body.method.wireByteCount + body.payload.wireByteCount + signature.wireByteCount }
    static var wireTypeID: UInt32 { 203 }
    func encodeWire(into buffer: inout ByteBuffer) throws {
        try buffer.imWriteString(body.serviceID); try buffer.imWriteString(body.role)
        try body.recipientIncarnation.encodeWire(into: &buffer); try body.attemptID.encodeWire(into: &buffer)
        try body.remainingMilliseconds.encodeWire(into: &buffer); try buffer.imWriteString(body.method)
        try body.payload.encodeWire(into: &buffer); try signature.encodeWire(into: &buffer)
    }
    static func decodeWire(from buffer: inout ByteBuffer) throws -> Self {
        let body = try SignedRequestBody(serviceID: buffer.imReadString(), role: buffer.imReadString(),
            recipientIncarnation: UUID.decodeWire(from: &buffer), attemptID: UUID.decodeWire(from: &buffer),
            remainingMilliseconds: Int.decodeWire(from: &buffer), method: buffer.imReadString(),
            payload: ProbeRequest.decodeWire(from: &buffer))
        return try .init(body: body, signature: Data.decodeWire(from: &buffer))
    }
}
extension SignedReply: IMWireValue {
    var wireByteCount: Int { body.serviceID.wireByteCount + 16 + 16 + 1 + (body.result?.wireByteCount ?? 0) + 1 + (body.errorCode?.wireByteCount ?? 0) + signature.wireByteCount }
    static var wireTypeID: UInt32 { 204 }
    func encodeWire(into buffer: inout ByteBuffer) throws {
        try buffer.imWriteString(body.serviceID); try body.hostIncarnation.encodeWire(into: &buffer)
        try body.attemptID.encodeWire(into: &buffer)
        try (body.result != nil).encodeWire(into: &buffer)
        if let result = body.result { try result.encodeWire(into: &buffer) }
        try (body.errorCode != nil).encodeWire(into: &buffer)
        if let code = body.errorCode { try buffer.imWriteString(code) }
        try signature.encodeWire(into: &buffer)
    }
    static func decodeWire(from buffer: inout ByteBuffer) throws -> Self {
        let service = try buffer.imReadString(), boot = try UUID.decodeWire(from: &buffer), attempt = try UUID.decodeWire(from: &buffer)
        let result = try Bool.decodeWire(from: &buffer) ? ProbeReply.decodeWire(from: &buffer) : nil
        let error = try Bool.decodeWire(from: &buffer) ? buffer.imReadString() : nil
        return try .init(body: .init(serviceID: service, hostIncarnation: boot, attemptID: attempt, result: result, errorCode: error),
                         signature: Data.decodeWire(from: &buffer))
    }
}
