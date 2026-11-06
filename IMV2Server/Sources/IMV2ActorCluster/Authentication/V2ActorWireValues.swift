import Foundation
import NIOCore
import IMActorSystem
import IMV2ActorContracts

/// The authenticated body remains byte-identical; it is never JSON/base64 wrapped.
extension V2ActorSignedPacket: IMWireValue {
    public var wireByteCount: Int { 4 + signerID.rawValue.utf8.count + body.wireByteCount + 1 + signature.count }
    public static var wireTypeID: UInt32 { 100 }
    public func encodeWire(into buffer: inout ByteBuffer) throws {
        guard body.count <= 16_777_216, signature.count <= 64 else { throw V2ActorAuthenticationError.oversized }
        try buffer.imWriteString(signerID.rawValue, maximum: V2ActorServiceID.maximumUTF8Bytes)
        try body.encodeWire(into: &buffer)
        buffer.writeInteger(UInt8(signature.count)); buffer.writeBytes(signature)
    }
    public static func decodeWire(from buffer: inout ByteBuffer) throws -> Self {
        let signerID = try V2ActorServiceID(buffer.imReadString(maximum: V2ActorServiceID.maximumUTF8Bytes))
        let body = try Data.decodeWire(from: &buffer)
        let count = Int(try buffer.imRead(UInt8.self))
        guard count <= 64, let signature = buffer.readBytes(length: count) else { throw IMActorError.malformed }
        return .init(signerID: signerID, body: body, signature: Data(signature))
    }
}

extension V2ActorAuthenticationError: IMWireValue {
    public var wireByteCount: Int { 1 }
    public static var wireTypeID: UInt32 { 101 }
    private static var codes: [Self] {
        [.invalidConfiguration, .oversized, .invalidSignature, .unknownService, .invalidRequest,
         .unsupportedVersion, .wrongRecipient, .forbidden, .sessionExpired, .replay, .overloaded]
    }
    public func encodeWire(into buffer: inout ByteBuffer) throws {
        guard let code = Self.codes.firstIndex(of: self) else { throw IMActorError.remoteFailure }
        buffer.writeInteger(UInt8(code))
    }
    public static func decodeWire(from buffer: inout ByteBuffer) throws -> Self {
        let code = Int(try buffer.imRead(UInt8.self))
        guard code < codes.count else { throw IMActorError.malformed }; return codes[code]
    }
}
