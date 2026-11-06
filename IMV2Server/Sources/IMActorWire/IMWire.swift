import Foundation
import NIOCore

/// A closed wire contract. No arbitrary Codable values or Swift type names cross the transport.
public protocol IMWireValue: Sendable {
    static var wireTypeID: UInt32 { get }
    /// Exact encoded bytes, computed without allocating an encoded buffer.
    var wireByteCount: Int { get }
    func encodeWire(into buffer: inout ByteBuffer) throws
    static func decodeWire(from buffer: inout ByteBuffer) throws -> Self
}

public enum IMActorError: UInt16, Error, Sendable, Equatable {
    case malformed = 1, incompatibleProtocol, unknownMethod, unknownActor, staleIncarnation
    case overloaded, deadlineExceeded, cancelled, connectionLost, shuttingDown, remoteFailure
    case forbidden, invalidConfiguration, registrationComplete
}

public enum IMTrafficClass: UInt8, Sendable, CaseIterable { case control = 1, rpc = 2, bulk = 3 }

public struct IMEndpoint: Hashable, Codable, Sendable, Comparable {
    public let host: String
    public let port: Int
    public init(host: String, port: Int) { self.host = host; self.port = port }
    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.host, lhs.port) < (rhs.host, rhs.port) }
}

/// The endpoint is a routing hint, not part of physical identity.
public struct IMNode: Codable, Sendable, Hashable, Comparable {
    public let id: String
    public let incarnationID: UUID
    public let endpoint: IMEndpoint
    public init(id: String, incarnationID: UUID = UUID(), endpoint: IMEndpoint) {
        self.id = id; self.incarnationID = incarnationID; self.endpoint = endpoint
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.incarnationID == rhs.incarnationID }
    public func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(incarnationID) }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhs.incarnationID.uuidString < rhs.incarnationID.uuidString
    }
}

public struct IMActorID: Hashable, Codable, Sendable, Comparable {
    public let node: IMNode
    public let localID: UInt64
    public init(node: IMNode, localID: UInt64) { self.node = node; self.localID = localID }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.node == rhs.node ? lhs.localID < rhs.localID : lhs.node < rhs.node
    }
}

public extension ByteBuffer {
    mutating func imRead<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        guard let value: T = readInteger() else { throw IMActorError.malformed }; return value
    }
    mutating func imReadBytes(maximum: Int) throws -> ByteBuffer {
        let count = Int(try imRead(UInt32.self))
        guard count <= maximum, let value = readSlice(length: count) else { throw IMActorError.malformed }
        return value
    }
    mutating func imWriteBytes(_ bytes: ByteBuffer, maximum: Int) throws {
        guard bytes.readableBytes <= maximum, bytes.readableBytes <= Int(UInt32.max) else { throw IMActorError.overloaded }
        writeInteger(UInt32(bytes.readableBytes)); writeImmutableBuffer(bytes)
    }
    mutating func imReadString(maximum: Int = 1024) throws -> String {
        let bytes = try imReadBytes(maximum: maximum)
        guard let text = String(bytes: bytes.readableBytesView, encoding: .utf8) else { throw IMActorError.malformed }
        return text
    }
    mutating func imWriteString(_ text: String, maximum: Int = 1024) throws {
        let bytes = text.utf8
        guard bytes.count <= maximum else { throw IMActorError.overloaded }
        writeInteger(UInt32(bytes.count)); writeBytes(bytes)
    }
    func imRequireEnd() throws { guard readableBytes == 0 else { throw IMActorError.malformed } }
}

extension UUID: IMWireValue {
    public var wireByteCount: Int { 16 }
    public static var wireTypeID: UInt32 { 1 }
    public func encodeWire(into buffer: inout ByteBuffer) throws {
        var value = uuid; _ = withUnsafeBytes(of: &value) { buffer.writeBytes($0) }
    }
    public static func decodeWire(from buffer: inout ByteBuffer) throws -> UUID {
        guard let bytes = buffer.readBytes(length: 16) else { throw IMActorError.malformed }
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
extension Int: IMWireValue {
    public var wireByteCount: Int { 8 }
    public static var wireTypeID: UInt32 { 2 }
    public func encodeWire(into buffer: inout ByteBuffer) throws { buffer.writeInteger(Int64(self)) }
    public static func decodeWire(from buffer: inout ByteBuffer) throws -> Int {
        guard let value = Int(exactly: try buffer.imRead(Int64.self)) else { throw IMActorError.malformed }; return value
    }
}
extension UInt64: IMWireValue {
    public var wireByteCount: Int { 8 }
    public static var wireTypeID: UInt32 { 7 }
    public func encodeWire(into buffer: inout ByteBuffer) throws { buffer.writeInteger(self) }
    public static func decodeWire(from buffer: inout ByteBuffer) throws -> Self { try buffer.imRead() }
}
extension Bool: IMWireValue {
    public var wireByteCount: Int { 1 }
    public static var wireTypeID: UInt32 { 8 }
    public func encodeWire(into buffer: inout ByteBuffer) throws { buffer.writeInteger(UInt8(self ? 1 : 0)) }
    public static func decodeWire(from buffer: inout ByteBuffer) throws -> Self {
        let value = try buffer.imRead(UInt8.self)
        guard value < 2 else { throw IMActorError.malformed }; return value == 1
    }
}
extension String: IMWireValue {
    public var wireByteCount: Int { 4 + utf8.count }
    public static var wireTypeID: UInt32 { 3 }
    public func encodeWire(into buffer: inout ByteBuffer) throws { try buffer.imWriteString(self, maximum: 1_048_576) }
    public static func decodeWire(from buffer: inout ByteBuffer) throws -> String { try buffer.imReadString(maximum: 1_048_576) }
}
extension Data: IMWireValue {
    public var wireByteCount: Int { 4 + count }
    public static var wireTypeID: UInt32 { 4 }
    public func encodeWire(into buffer: inout ByteBuffer) throws {
        guard count <= 16_777_216 else { throw IMActorError.overloaded }
        buffer.writeInteger(UInt32(count)); buffer.writeBytes(self)
    }
    public static func decodeWire(from buffer: inout ByteBuffer) throws -> Data {
        let bytes = try buffer.imReadBytes(maximum: 16_777_216); return Data(bytes.readableBytesView)
    }
}
extension IMNode: IMWireValue {
    public var wireByteCount: Int { 4 + id.utf8.count + 16 + 4 + endpoint.host.utf8.count + 2 }
    public static var wireTypeID: UInt32 { 5 }
    public func encodeWire(into buffer: inout ByteBuffer) throws {
        try buffer.imWriteString(id, maximum: 256); try incarnationID.encodeWire(into: &buffer)
        try buffer.imWriteString(endpoint.host, maximum: 253)
        guard (1...65535).contains(endpoint.port) else { throw IMActorError.invalidConfiguration }
        buffer.writeInteger(UInt16(endpoint.port))
    }
    public static func decodeWire(from buffer: inout ByteBuffer) throws -> Self {
        let id = try buffer.imReadString(maximum: 256), incarnation = try UUID.decodeWire(from: &buffer)
        let host = try buffer.imReadString(maximum: 253), port = Int(try buffer.imRead(UInt16.self))
        guard !id.isEmpty, !host.isEmpty, port > 0 else { throw IMActorError.malformed }
        return .init(id: id, incarnationID: incarnation, endpoint: .init(host: host, port: port))
    }
}
extension IMActorID: IMWireValue {
    public var wireByteCount: Int { node.wireByteCount + 8 }
    public static var wireTypeID: UInt32 { 6 }
    public func encodeWire(into buffer: inout ByteBuffer) throws {
        try node.encodeWire(into: &buffer); buffer.writeInteger(localID)
    }
    public static func decodeWire(from buffer: inout ByteBuffer) throws -> Self {
        let node = try IMNode.decodeWire(from: &buffer), id = try buffer.imRead(UInt64.self)
        guard id > 0 else { throw IMActorError.malformed }; return .init(node: node, localID: id)
    }
}

public enum IMFrameKind: UInt8, Sendable {
    case hello = 1, request, response, failure, cancel, credit, ping, pong, drain, retired, lookup
}

public struct IMFrame: Sendable {
    public static let version: UInt16 = 1
    public static let headerBytes = 32
    public var kind: IMFrameKind
    public var callID: UInt64
    public var actorID: UInt64
    public var methodID: UInt32
    public var budgetMilliseconds: UInt32
    public var body: ByteBuffer
    public init(kind: IMFrameKind, callID: UInt64 = 0, actorID: UInt64 = 0, methodID: UInt32 = 0,
                budgetMilliseconds: UInt32 = 0, body: ByteBuffer = ByteBuffer()) {
        self.kind = kind; self.callID = callID; self.actorID = actorID; self.methodID = methodID
        self.budgetMilliseconds = budgetMilliseconds; self.body = body
    }
    public func encode(maximumBytes: Int) throws -> ByteBuffer {
        let size = Self.headerBytes + body.readableBytes
        guard size <= maximumBytes, size <= Int(UInt32.max) else { throw IMActorError.overloaded }
        var buffer = ByteBuffer(); buffer.reserveCapacity(size + 4)
        buffer.writeInteger(UInt32(size)); buffer.writeInteger(UInt32(0x494D4152)) // IMAR
        buffer.writeInteger(Self.version); buffer.writeInteger(kind.rawValue); buffer.writeInteger(UInt8(0))
        buffer.writeInteger(callID); buffer.writeInteger(actorID); buffer.writeInteger(methodID)
        buffer.writeInteger(budgetMilliseconds); buffer.writeImmutableBuffer(body)
        return buffer
    }
    public static func decode(_ bytes: ByteBuffer) throws -> Self {
        var buffer = bytes
        guard try buffer.imRead(UInt32.self) == 0x494D4152,
              try buffer.imRead(UInt16.self) == version,
              let kind = IMFrameKind(rawValue: try buffer.imRead(UInt8.self)),
              try buffer.imRead(UInt8.self) == 0 else { throw IMActorError.incompatibleProtocol }
        let callID = try buffer.imRead(UInt64.self), actorID = try buffer.imRead(UInt64.self)
        let methodID = try buffer.imRead(UInt32.self), budget = try buffer.imRead(UInt32.self)
        return .init(kind: kind, callID: callID, actorID: actorID, methodID: methodID,
                     budgetMilliseconds: budget, body: buffer)
    }
}

public struct IMFrameDecoder: ByteToMessageDecoder {
    public typealias InboundOut = IMFrame
    public let maximumBytes: Int
    public init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
    public mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let length: UInt32 = buffer.getInteger(at: buffer.readerIndex) else { return .needMoreData }
        guard Int(length) >= IMFrame.headerBytes, Int(length) <= maximumBytes else { throw IMActorError.malformed }
        guard buffer.readableBytes >= Int(length) + 4 else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        guard let bytes = buffer.readSlice(length: Int(length)) else { throw IMActorError.malformed }
        context.fireChannelRead(wrapInboundOut(try IMFrame.decode(bytes))); return .continue
    }
}
