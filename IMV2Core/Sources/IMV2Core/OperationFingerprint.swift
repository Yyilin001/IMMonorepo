import Crypto
import Foundation

public enum V2OperationFingerprintError: Error, Equatable, Sendable {
    case invalidStoredFingerprint, duplicateField, emptyFieldName
}

/// Digest of an explicit semantic schema, excluding transport credentials and attempts.
public struct V2OperationFingerprint: Equatable, Codable, Sendable {
    public static let currentVersion: UInt16 = 1
    public let version: UInt16
    public let digest: Data
    public init(version: UInt16, digest: Data) throws {
        guard version == Self.currentVersion, digest.count == 32 else {
            throw V2OperationFingerprintError.invalidStoredFingerprint
        }
        self.version = version; self.digest = digest
    }
    public init(kind: V2OperationKind, fields: [V2OperationFingerprintField]) throws {
        guard fields.allSatisfy({ !$0.name.isEmpty }) else { throw V2OperationFingerprintError.emptyFieldName }
        guard Set(fields.map(\.name)).count == fields.count else { throw V2OperationFingerprintError.duplicateField }
        var encoder = OperationFingerprintEncoder(kind: kind)
        for field in fields.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }) {
            encoder.string(field.name)
            switch field.value {
            case .absent: encoder.tag(0)
            case .text(let text): encoder.tag(1); encoder.string(text)
            case .unsigned(let value): encoder.tag(2); encoder.integer(value)
            case .signed(let value): encoder.tag(3); encoder.integer(UInt64(bitPattern: value))
            case .bytes(let value): encoder.tag(4); encoder.data(value)
            case .flag(let flag): encoder.tag(5); encoder.tag(flag ? 1 : 0)
            case .orderedText(let values):
                encoder.tag(6); encoder.integer(UInt64(values.count))
                for value in values { encoder.string(value) }
            }
        }
        self.version = Self.currentVersion; self.digest = encoder.finish()
    }

    /// Fixed schema in the same UTF-8 key order as the generic encoder.
    init(messageSendIdentity: String, domain: V2SendMessageFingerprint, deadline: UInt64) {
        var encoder = OperationFingerprintEncoder(kind: .sendMessage)
        encoder.string("domainFingerprint"); encoder.tag(4); encoder.data(domain.digest)
        encoder.string("domainFingerprintVersion"); encoder.tag(2); encoder.integer(UInt64(domain.version))
        encoder.string("firstSubmissionDeadline"); encoder.tag(2); encoder.integer(deadline)
        encoder.string("identity"); encoder.tag(1); encoder.string(messageSendIdentity)
        self.version = Self.currentVersion; self.digest = encoder.finish()
    }

    private enum CodingKeys: String, CodingKey { case version, digest }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: values.decode(UInt16.self, forKey: .version), digest: values.decode(Data.self, forKey: .digest))
    }
}

/// Fixed-width integers and length-prefixed exact UTF-8 prevent concatenation ambiguity.
/// Domain adapters explicitly enumerate fields; this is not a JSON canonicalizer.
public struct V2OperationFingerprintField: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case absent, text(String), unsigned(UInt64), signed(Int64), bytes(Data), flag(Bool), orderedText([String])
    }
    public let name: String
    public let value: Value
    public init(_ name: String, _ value: Value) { self.name = name; self.value = value }
}

/// Stream the canonical bytes directly into SHA-256; no aggregate Data buffer.
private struct OperationFingerprintEncoder {
    private var hasher = SHA256()
    init(kind: V2OperationKind) {
        string("im.v2.operation")
        integer(UInt64(V2OperationFingerprint.currentVersion))
        string(kind.rawValue)
    }
    mutating func tag(_ value: UInt8) {
        var byte = value
        withUnsafeBytes(of: &byte) { hasher.update(bufferPointer: $0) }
    }
    mutating func integer(_ value: UInt64) {
        var bytes = value.bigEndian
        withUnsafeBytes(of: &bytes) { hasher.update(bufferPointer: $0) }
    }
    mutating func string(_ value: String) {
        var value = value
        value.withUTF8 { bytes in
            integer(UInt64(bytes.count))
            hasher.update(bufferPointer: UnsafeRawBufferPointer(bytes))
        }
    }
    mutating func data(_ value: Data) {
        integer(UInt64(value.count))
        hasher.update(data: value)
    }
    mutating func finish() -> Data { Data(hasher.finalize()) }
}
