import Foundation
import SwiftProtobuf

/// Internal server wire boundary. Values retain scalar types, full 64-bit
/// integers and raw bytes. This codec is never used for local dispatch.
package protocol V2ActorProtobufMessage {
    func protobufBytes() throws -> Data
    static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self
}

public enum V2ActorProtobuf {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        if let direct = value as? any V2ActorProtobufMessage { return try direct.protobufBytes() }
        return try encodeValue(value)
    }
    package static func encodeValue<T: Encodable>(_ value: T) throws -> Data {
        let node = PBNode()
        try PBEncoder(node: node, codingPath: []).encode(value)
        return try node.wireBytes()
    }
    package static func message<T: Encodable>(_ value: T) throws -> Im_Actor_V1_Value {
        let node = PBNode()
        try PBEncoder(node: node, codingPath: []).encode(value)
        return try node.message(depth: 0)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from bytes: Data) throws -> T {
        try decode(type, from: bytes.bytes)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from bytes: borrowing RawSpan) throws -> T {
        guard bytes.byteCount > 0, bytes.byteCount <= 16_777_216 else { throw PBError.invalid }
        if let direct = type as? any V2ActorProtobufMessage.Type,
           let result = try direct.fromProtobufBytes(bytes) as? T { return result }
        return try decodeValue(type, from: bytes)
    }
    package static func decodeValue<T: Decodable>(_ type: T.Type, from bytes: Data) throws -> T {
        try decodeValue(type, from: bytes.bytes)
    }
    package static func decodeValue<T: Decodable>(_ type: T.Type, from bytes: borrowing RawSpan) throws -> T {
        guard bytes.byteCount > 0, bytes.byteCount <= 16_777_216 else { throw PBError.invalid }
        return try model(type, from: Im_Actor_V1_Value(serializedBytes: copy bytes))
    }
    package static func model<T: Decodable>(_ type: T.Type, from value: Im_Actor_V1_Value) throws -> T {
        try validate(value, depth: 0)
        return try PBDecoder(value: value, codingPath: []).decode(type)
    }
    private static func validate(_ value: Im_Actor_V1_Value, depth: Int) throws {
        guard depth < 64, let kind = value.kind, value.unknownFields.data.isEmpty else { throw PBError.invalid }
        switch kind {
        case .objectValue(let object):
            var names = Set<String>()
            for field in object.fields {
                guard field.hasValue, field.unknownFields.data.isEmpty,
                      names.insert(field.name).inserted else { throw PBError.invalid }
                try validate(field.value, depth: depth + 1)
            }
            guard object.unknownFields.data.isEmpty else { throw PBError.invalid }
        case .arrayValue(let array):
            guard array.unknownFields.data.isEmpty else { throw PBError.invalid }
            for item in array.values { try validate(item, depth: depth + 1) }
        case .nullValue(let isNull): guard isNull else { throw PBError.invalid }
        case .doubleValue(let number): guard number.isFinite else { throw PBError.invalid }
        default: break
        }
    }
}

private enum PBError: Error { case invalid }
private final class PBObject {
    var fields: [String: PBNode] = [:]
    var ordered: [(String, PBNode)] = []
}
private final class PBArray { var values: [PBNode] = [] }
private final class PBNode {
    enum Storage {
        case unset, scalar(Im_Actor_V1_Value.OneOf_Kind)
        case object(PBObject), array(PBArray)
    }
    var storage: Storage = .unset
    var wireLength = 0
    var contentLength = 0
    func field(_ key: String) -> PBNode {
        if case .unset = storage { storage = .object(PBObject()) }
        guard case .object(let object) = storage else { preconditionFailure("incompatible Codable containers") }
        if let node = object.fields[key] { return node }
        let node = PBNode(); object.fields[key] = node; return node
    }
    func append() -> PBNode {
        if case .unset = storage { storage = .array(PBArray()) }
        guard case .array(let array) = storage else { preconditionFailure("incompatible Codable containers") }
        let node = PBNode(); array.values.append(node); return node
    }
    var count: Int { if case .array(let array) = storage { array.values.count } else { 0 } }
    func message(depth: Int) throws -> Im_Actor_V1_Value {
        guard depth < 64 else { throw PBError.invalid }
        var result = Im_Actor_V1_Value()
        switch storage {
        case .unset: throw PBError.invalid
        case .scalar(let kind): result.kind = kind
        case .object(let container):
            let fields = container.fields
            var object = Im_Actor_V1_Object()
            object.fields = try fields.keys.sorted().map { name in
                var field = Im_Actor_V1_Field(); field.name = name
                field.value = try fields[name]!.message(depth: depth + 1); return field
            }
            result.objectValue = object
        case .array(let container):
            let values = container.values
            var array = Im_Actor_V1_Array()
            array.values = try values.map { try $0.message(depth: depth + 1) }
            result.arrayValue = array
        }
        return result
    }
}
private struct PBKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(_ index: Int) { stringValue = "\(index)"; intValue = index }
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { self.init(intValue) }
}
private struct PBEncoder: Encoder {
    let node: PBNode
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func encode<T: Encodable>(_ value: T) throws {
        guard codingPath.count < 64 else { throw PBError.invalid }
        if let data = value as? Data { node.storage = .scalar(.bytesValue(data)) }
        else if let date = value as? Date {
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw PBError.invalid }
            node.storage = .scalar(.doubleValue(date.timeIntervalSinceReferenceDate))
        } else if let uuid = value as? UUID {
            var tuple = uuid.uuid
            node.storage = .scalar(.bytesValue(withUnsafeBytes(of: &tuple) { Data($0) }))
        } else { try value.encode(to: self) }
    }
    func container<Key: CodingKey>(keyedBy: Key.Type) -> KeyedEncodingContainer<Key> {
        if case .unset = node.storage { node.storage = .object(PBObject()) }
        return KeyedEncodingContainer(PBKeyedEncoder<Key>(encoder: self))
    }
    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        if case .unset = node.storage { node.storage = .array(PBArray()) }
        return PBArrayEncoder(encoder: self)
    }
    func singleValueContainer() -> any SingleValueEncodingContainer { PBSingleEncoder(encoder: self) }
    func child(_ key: any CodingKey) -> PBEncoder { .init(node: node.field(key.stringValue), codingPath: codingPath + [key]) }
    func next() -> PBEncoder { .init(node: node.append(), codingPath: codingPath + [PBKey(node.count - 1)]) }
}
private struct PBKeyedEncoder<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: PBEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }
    mutating func encodeNil(forKey key: Key) throws { encoder.child(key).node.storage = .scalar(.nullValue(true)) }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try encoder.child(key).encode(value) }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> { encoder.child(key).container(keyedBy: keyedBy) }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer { encoder.child(key).unkeyedContainer() }
    mutating func superEncoder() -> any Encoder { encoder.child(PBKey(stringValue: "super")!) }
    mutating func superEncoder(forKey key: Key) -> any Encoder { encoder.child(key) }
}
private struct PBArrayEncoder: UnkeyedEncodingContainer {
    let encoder: PBEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }
    var count: Int { encoder.node.count }
    mutating func encodeNil() throws { encoder.next().node.storage = .scalar(.nullValue(true)) }
    mutating func encode<T: Encodable>(_ value: T) throws { try encoder.next().encode(value) }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> { encoder.next().container(keyedBy: keyedBy) }
    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { encoder.next().unkeyedContainer() }
    mutating func superEncoder() -> any Encoder { encoder.next() }
}
private struct PBSingleEncoder: SingleValueEncodingContainer {
    let encoder: PBEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }
    func encodeNil() throws { encoder.node.storage = .scalar(.nullValue(true)) }
    func encode<T: Encodable>(_ value: T) throws { try encoder.encode(value) }
    func encode(_ value: Bool) throws { encoder.node.storage = .scalar(.boolValue(value)) }
    func encode(_ value: String) throws { encoder.node.storage = .scalar(.stringValue(value)) }
    func encode(_ value: Double) throws { guard value.isFinite else { throw PBError.invalid }; encoder.node.storage = .scalar(.doubleValue(value)) }
    func encode(_ value: Float) throws { guard value.isFinite else { throw PBError.invalid }; encoder.node.storage = .scalar(.doubleValue(Double(value))) }
    func encode(_ value: Int) throws { encoder.node.storage = .scalar(.signedValue(Int64(value))) }
    func encode(_ value: Int8) throws { encoder.node.storage = .scalar(.signedValue(Int64(value))) }
    func encode(_ value: Int16) throws { encoder.node.storage = .scalar(.signedValue(Int64(value))) }
    func encode(_ value: Int32) throws { encoder.node.storage = .scalar(.signedValue(Int64(value))) }
    func encode(_ value: Int64) throws { encoder.node.storage = .scalar(.signedValue(Int64(value))) }
    func encode(_ value: UInt) throws { encoder.node.storage = .scalar(.unsignedValue(UInt64(value))) }
    func encode(_ value: UInt8) throws { encoder.node.storage = .scalar(.unsignedValue(UInt64(value))) }
    func encode(_ value: UInt16) throws { encoder.node.storage = .scalar(.unsignedValue(UInt64(value))) }
    func encode(_ value: UInt32) throws { encoder.node.storage = .scalar(.unsignedValue(UInt64(value))) }
    func encode(_ value: UInt64) throws { encoder.node.storage = .scalar(.unsignedValue(UInt64(value))) }
}
private struct PBDecoder: Swift.Decoder {
    let value: Im_Actor_V1_Value
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == Data.self {
            guard case .bytesValue(let data)? = value.kind else { throw mismatch(type) }
            return data as! T
        }
        if type == UUID.self {
            guard case .bytesValue(let data)? = value.kind, data.count == 16 else { throw mismatch(type) }
            return data.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) } as! T
        }
        if type == Date.self {
            guard case .doubleValue(let number)? = value.kind else { throw mismatch(type) }
            return Date(timeIntervalSinceReferenceDate: number) as! T
        }
        return try T(from: self)
    }
    func mismatch(_ type: Any.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Invalid Protobuf scalar/container"))
    }
    func container<Key: CodingKey>(keyedBy: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .objectValue(let object)? = value.kind else { throw mismatch([String: Any].self) }
        return KeyedDecodingContainer(PBKeyedDecoder<Key>(decoder: self, fields: Dictionary(uniqueKeysWithValues: object.fields.map { ($0.name, $0.value) })))
    }
    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .arrayValue(let array)? = value.kind else { throw mismatch([Any].self) }
        return PBArrayDecoder(decoder: self, values: array.values)
    }
    func singleValueContainer() throws -> any SingleValueDecodingContainer { PBSingleDecoder(decoder: self) }
    func child(_ value: Im_Actor_V1_Value, key: any CodingKey) -> PBDecoder { .init(value: value, codingPath: codingPath + [key]) }
}
private struct PBKeyedDecoder<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: PBDecoder
    let fields: [String: Im_Actor_V1_Value]
    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [Key] { fields.keys.compactMap(Key.init(stringValue:)) }
    func contains(_ key: Key) -> Bool { fields[key.stringValue] != nil }
    func child(_ key: any CodingKey) throws -> PBDecoder {
        guard let value = fields[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Missing Protobuf field"))
        }
        return decoder.child(value, key: key)
    }
    func decodeNil(forKey key: Key) throws -> Bool { try child(key).singleValueContainer().decodeNil() }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try child(key).decode(type) }
    func nestedContainer<NestedKey: CodingKey>(keyedBy: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> { try child(key).container(keyedBy: keyedBy) }
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer { try child(key).unkeyedContainer() }
    func superDecoder() throws -> any Swift.Decoder { try child(PBKey(stringValue: "super")!) }
    func superDecoder(forKey key: Key) throws -> any Swift.Decoder { try child(key) }
}
private struct PBArrayDecoder: UnkeyedDecodingContainer {
    let decoder: PBDecoder
    let values: [Im_Actor_V1_Value]
    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { values.count }
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex == values.count }
    mutating func next() throws -> PBDecoder {
        guard !isAtEnd else { throw DecodingError.valueNotFound(Any.self, .init(codingPath: codingPath, debugDescription: "Protobuf array exhausted")) }
        defer { currentIndex += 1 }
        return decoder.child(values[currentIndex], key: PBKey(currentIndex))
    }
    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { throw PBError.invalid }
        if case .nullValue? = values[currentIndex].kind { currentIndex += 1; return true }
        return false
    }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try next().decode(type) }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> { try next().container(keyedBy: keyedBy) }
    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer { try next().unkeyedContainer() }
    mutating func superDecoder() throws -> any Swift.Decoder { try next() }
}
private struct PBSingleDecoder: SingleValueDecodingContainer {
    let decoder: PBDecoder
    var codingPath: [any CodingKey] { decoder.codingPath }
    func decodeNil() -> Bool { if case .nullValue? = decoder.value.kind { true } else { false } }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(type) }
    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .boolValue(let value)? = decoder.value.kind else { throw decoder.mismatch(type) }; return value
    }
    func decode(_ type: String.Type) throws -> String {
        guard case .stringValue(let value)? = decoder.value.kind else { throw decoder.mismatch(type) }; return value
    }
    func decode(_ type: Double.Type) throws -> Double {
        guard case .doubleValue(let value)? = decoder.value.kind else { throw decoder.mismatch(type) }; return value
    }
    func decode(_ type: Float.Type) throws -> Float {
        let value = Float(try decode(Double.self)); guard value.isFinite else { throw decoder.mismatch(type) }; return value
    }
    func decode(_ type: Int.Type) throws -> Int {
        guard case .signedValue(let value)? = decoder.value.kind, let result = Int(exactly: value) else { throw decoder.mismatch(type) }; return result
    }
    func decode(_ type: Int8.Type) throws -> Int8 {
        guard case .signedValue(let value)? = decoder.value.kind, let result = Int8(exactly: value) else { throw decoder.mismatch(type) }; return result
    }
    func decode(_ type: Int16.Type) throws -> Int16 {
        guard case .signedValue(let value)? = decoder.value.kind, let result = Int16(exactly: value) else { throw decoder.mismatch(type) }; return result
    }
    func decode(_ type: Int32.Type) throws -> Int32 {
        guard case .signedValue(let value)? = decoder.value.kind, let result = Int32(exactly: value) else { throw decoder.mismatch(type) }; return result
    }
    func decode(_ type: Int64.Type) throws -> Int64 {
        guard case .signedValue(let value)? = decoder.value.kind, let result = Int64(exactly: value) else { throw decoder.mismatch(type) }; return result
    }
    func decode(_ type: UInt.Type) throws -> UInt {
        guard case .unsignedValue(let value)? = decoder.value.kind, let result = UInt(exactly: value) else { throw decoder.mismatch(type) }; return result
    }
    func decode(_ type: UInt8.Type) throws -> UInt8 {
        guard case .unsignedValue(let value)? = decoder.value.kind, let result = UInt8(exactly: value) else { throw decoder.mismatch(type) }; return result
    }
    func decode(_ type: UInt16.Type) throws -> UInt16 {
        guard case .unsignedValue(let value)? = decoder.value.kind, let result = UInt16(exactly: value) else { throw decoder.mismatch(type) }; return result
    }
    func decode(_ type: UInt32.Type) throws -> UInt32 {
        guard case .unsignedValue(let value)? = decoder.value.kind, let result = UInt32(exactly: value) else { throw decoder.mismatch(type) }; return result
    }
    func decode(_ type: UInt64.Type) throws -> UInt64 {
        guard case .unsignedValue(let value)? = decoder.value.kind, let result = UInt64(exactly: value) else { throw decoder.mismatch(type) }; return result
    }
}

// Standard Value/Object/Array Protobuf encoding with cached node lengths. The
// generated decoder remains the independent parser. Nested Message.serializedData
// otherwise recomputes subtree lengths at every level of this Codable bridge.
private struct PBWriter {
    var bytes: Data
    init(capacity: Int) { bytes = Data(); bytes.reserveCapacity(capacity) }
    static func length(_ value: UInt64) -> Int {
        var value = value, count = 1
        while value >= 128 { count += 1; value >>= 7 }
        return count
    }
    static func delimited(_ size: Int) -> Int { 1 + length(UInt64(size)) + size }
    mutating func integer(_ value: UInt64) {
        var value = value
        while value >= 128 { bytes.append(UInt8(truncatingIfNeeded: value) | 128); value >>= 7 }
        bytes.append(UInt8(value))
    }
    mutating func header(_ tag: UInt8, size: Int) { bytes.append(tag); integer(UInt64(size)) }
    mutating func string(_ value: String, tag: UInt8) {
        header(tag, size: value.utf8.count); bytes.append(contentsOf: value.utf8)
    }
}
private extension PBNode {
    func wireBytes() throws -> Data {
        let size = try prepareLength(depth: 0)
        var writer = PBWriter(capacity: size)
        write(to: &writer)
        precondition(writer.bytes.count == size)
        return writer.bytes
    }
    func prepareLength(depth: Int) throws -> Int {
        guard depth < 64 else { throw PBError.invalid }
        contentLength = 0
        switch storage {
        case .unset: throw PBError.invalid
        case .scalar(let kind):
            switch kind {
            case .nullValue, .boolValue: wireLength = 2
            case .signedValue(let value): wireLength = 1 + PBWriter.length(zigzag(value))
            case .unsignedValue(let value): wireLength = 1 + PBWriter.length(value)
            case .doubleValue: wireLength = 9
            case .stringValue(let value): wireLength = PBWriter.delimited(value.utf8.count)
            case .bytesValue(let value): wireLength = PBWriter.delimited(value.count)
            case .objectValue, .arrayValue: throw PBError.invalid
            }
        case .object(let object):
            object.ordered = object.fields.keys.sorted().map { ($0, object.fields[$0]!) }
            for (name, child) in object.ordered {
                let childLength = try child.prepareLength(depth: depth + 1)
                let fieldLength = (name.isEmpty ? 0 : PBWriter.delimited(name.utf8.count)) + PBWriter.delimited(childLength)
                contentLength += PBWriter.delimited(fieldLength)
            }
            wireLength = PBWriter.delimited(contentLength)
        case .array(let array):
            for child in array.values { contentLength += PBWriter.delimited(try child.prepareLength(depth: depth + 1)) }
            wireLength = PBWriter.delimited(contentLength)
        }
        return wireLength
    }
    func zigzag(_ value: Int64) -> UInt64 { (UInt64(bitPattern: value) << 1) ^ UInt64(bitPattern: value >> 63) }
    func write(to writer: inout PBWriter) {
        switch storage {
        case .unset: preconditionFailure("Unprepared PB node")
        case .scalar(let kind):
            switch kind {
            case .nullValue: writer.bytes.append(contentsOf: [8, 1])
            case .boolValue(let value): writer.bytes.append(contentsOf: [16, value ? 1 : 0])
            case .signedValue(let value): writer.bytes.append(24); writer.integer(zigzag(value))
            case .unsignedValue(let value): writer.bytes.append(32); writer.integer(value)
            case .doubleValue(let value):
                writer.bytes.append(41); var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { writer.bytes.append(contentsOf: $0) }
            case .stringValue(let value): writer.string(value, tag: 50)
            case .bytesValue(let value): writer.header(58, size: value.count); writer.bytes.append(value)
            case .objectValue, .arrayValue: preconditionFailure("Non-scalar PB node")
            }
        case .object(let object):
            writer.header(66, size: contentLength)
            for (name, child) in object.ordered {
                let fieldLength = (name.isEmpty ? 0 : PBWriter.delimited(name.utf8.count)) + PBWriter.delimited(child.wireLength)
                writer.header(10, size: fieldLength)
                if !name.isEmpty { writer.string(name, tag: 10) }
                writer.header(18, size: child.wireLength); child.write(to: &writer)
            }
        case .array(let array):
            writer.header(74, size: contentLength)
            for child in array.values { writer.header(10, size: child.wireLength); child.write(to: &writer) }
        }
    }
}
