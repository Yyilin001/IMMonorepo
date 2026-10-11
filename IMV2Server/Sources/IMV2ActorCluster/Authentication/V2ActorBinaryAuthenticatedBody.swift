import Foundation
import IMV2ActorContracts
import IMV2Core

/// Closed authenticated envelopes only. Business payloads retain their Codable
/// representation; signature verification must precede this decoder.
protocol V2ActorBinaryAuthenticatedBody: Codable {
    func binaryAuthenticatedBody() throws -> Data
    static func decodeBinaryAuthenticatedBody(_ bytes: Data) throws -> Self
}

enum V2ActorAuthenticatedBodyFraming {
    static let magic: [UInt8] = [73, 77, 86, 65] // IMVA
    static func recognizes(_ bytes: Data) -> Bool { bytes.starts(with: magic) }
}

private struct BodyWriter {
    var bytes: Data
    init(kind: UInt8) {
        bytes = Data()
        bytes.reserveCapacity(256)
        bytes.append(contentsOf: V2ActorAuthenticatedBodyFraming.magic)
        bytes.append(1)
        bytes.append(kind)
    }
    mutating func integer(_ value: UInt64) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }
    mutating func identifier(_ value: consuming String) throws {
        var value = consume value
        try value.withUTF8 { utf8 in
            guard (1...128).contains(utf8.count) else { throw V2ActorAuthenticationError.invalidRequest }
            bytes.append(UInt8(utf8.count)); bytes.append(contentsOf: utf8)
        }
    }
    mutating func uuid(_ value: UUID) {
        var tuple = value.uuid
        withUnsafeBytes(of: &tuple) { bytes.append(contentsOf: $0) }
    }
    mutating func host(_ value: V2ActorHostIdentity) throws {
        try identifier(value.hostID.rawValue); uuid(value.incarnationID)
    }
    mutating func payload<T: Encodable>(_ value: T) throws {
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= 16_777_216 else { throw V2ActorAuthenticationError.oversized }
        integer(UInt64(encoded.count)); bytes.append(encoded)
    }
}

private struct BodyReader {
    let bytes: Data
    var offset = 6
    init(_ bytes: Data, kind: UInt8) throws {
        guard bytes.count >= 6, bytes.count <= 16_777_216,
              V2ActorAuthenticatedBodyFraming.recognizes(bytes) else {
            throw V2ActorAuthenticationError.invalidRequest
        }
        self.bytes = bytes
        try bytes.bytes.withUnsafeBytes { raw in
            guard raw[4] == 1 else { throw V2ActorAuthenticationError.unsupportedVersion }
            guard raw[5] == kind else { throw V2ActorAuthenticationError.invalidRequest }
        }
    }
    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw V2ActorAuthenticationError.invalidRequest }
        defer { offset += 1 }
        return bytes.bytes.withUnsafeBytes { $0[offset] }
    }
    mutating func integer() throws -> UInt64 {
        guard bytes.count - offset >= 8 else { throw V2ActorAuthenticationError.invalidRequest }
        defer { offset += 8 }
        return bytes.bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
    mutating func identifier() throws -> String {
        let size = Int(try byte())
        guard (1...128).contains(size), size <= bytes.count - offset else {
            throw V2ActorAuthenticationError.invalidRequest
        }
        defer { offset += size }
        return try bytes.bytes.withUnsafeBytes { raw in
            guard let value = String(bytes: raw[offset..<(offset + size)], encoding: .utf8) else {
                throw V2ActorAuthenticationError.invalidRequest
            }
            return value
        }
    }
    mutating func uuid() throws -> UUID {
        guard bytes.count - offset >= 16 else { throw V2ActorAuthenticationError.invalidRequest }
        defer { offset += 16 }
        return bytes.bytes.withUnsafeBytes {
            UUID(uuid: $0.loadUnaligned(fromByteOffset: offset, as: uuid_t.self))
        }
    }
    mutating func host() throws -> V2ActorHostIdentity {
        try .init(hostID: .init(identifier()), incarnationID: uuid())
    }
    mutating func payload<T: Decodable>(_ type: T.Type) throws -> T {
        let size = try integer()
        guard size <= UInt64(bytes.count - offset) else { throw V2ActorAuthenticationError.invalidRequest }
        guard Int(size) == bytes.count - offset else { throw V2ActorAuthenticationError.invalidRequest }
        // JSONDecoder requires Data. Borrow the validated payload only during
        // its synchronous decode; no temporary payload allocation or escaping view.
        let result = try bytes.bytes.withUnsafeBytes { raw in
            let payload = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: raw.baseAddress!.advanced(by: offset)),
                count: Int(size), deallocator: .none)
            return try JSONDecoder().decode(type, from: payload)
        }
        offset = bytes.count
        return result
    }
    mutating func version() throws -> Int {
        guard let value = Int(exactly: Int64(bitPattern: try integer())) else {
            throw V2ActorAuthenticationError.invalidRequest
        }
        return value
    }
}

extension V2ActorAuthenticatedCall: V2ActorBinaryAuthenticatedBody {
    func binaryAuthenticatedBody() throws -> Data {
        var writer = BodyWriter(kind: 1)
        writer.integer(UInt64(bitPattern: Int64(version)))
        try writer.identifier(serviceID.rawValue); writer.uuid(callerIncarnation)
        try writer.host(recipient); writer.uuid(sessionID); writer.integer(sequence)
        writer.uuid(attemptID); writer.uuid(traceID); writer.integer(UInt64(bitPattern: remainingBudget.rawValue))
        switch principal {
        case .service: writer.bytes.append(0)
        case .user(let user): writer.bytes.append(1); try writer.identifier(user.rawValue)
        }
        try writer.payload(request)
        return writer.bytes
    }
    static func decodeBinaryAuthenticatedBody(_ bytes: Data) throws -> Self {
        var reader = try BodyReader(bytes, kind: 1)
        let version = try reader.version(), service = try V2ActorServiceID(reader.identifier())
        let caller = try reader.uuid(), recipient = try reader.host(), session = try reader.uuid()
        let sequence = try reader.integer(), attempt = try reader.uuid(), trace = try reader.uuid()
        let budget = try V2ActorMilliseconds(Int64(bitPattern: reader.integer()))
        let principal: V2ActorCallPrincipal
        switch try reader.byte() {
        case 0: principal = .service
        case 1: principal = .user(try UserID(reader.identifier()))
        default: throw V2ActorAuthenticationError.invalidRequest
        }
        return try .init(version: version, serviceID: service, callerIncarnation: caller, recipient: recipient,
            sessionID: session, sequence: sequence, attemptID: attempt, traceID: trace, remainingBudget: budget,
            principal: principal, request: reader.payload(V2ActorRPCRequest.self))
    }
}

extension V2ActorAuthenticatedReply: V2ActorBinaryAuthenticatedBody {
    func binaryAuthenticatedBody() throws -> Data {
        var writer = BodyWriter(kind: 2)
        writer.integer(UInt64(bitPattern: Int64(version))); try writer.host(host)
        writer.uuid(sessionID); writer.integer(sequence); writer.uuid(attemptID)
        try writer.payload(response)
        return writer.bytes
    }
    static func decodeBinaryAuthenticatedBody(_ bytes: Data) throws -> Self {
        var reader = try BodyReader(bytes, kind: 2)
        return try .init(version: reader.version(), host: reader.host(), sessionID: reader.uuid(),
            sequence: reader.integer(), attemptID: reader.uuid(), response: reader.payload(V2ActorRPCResponse.self))
    }
}
