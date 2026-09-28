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
        var bytes = Data()
        func integer(_ value: UInt64) { var value = value.bigEndian; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
        func data(_ value: Data) { integer(UInt64(value.count)); bytes.append(value) }
        data(Data("im.v2.operation".utf8)); integer(UInt64(Self.currentVersion)); data(Data(kind.rawValue.utf8))
        for field in fields.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }) {
            data(Data(field.name.utf8))
            switch field.value {
            case .absent: bytes.append(0)
            case .text(let text): bytes.append(1); data(Data(text.utf8))
            case .unsigned(let value): bytes.append(2); integer(value)
            case .signed(let value): bytes.append(3); integer(UInt64(bitPattern: value))
            case .bytes(let value): bytes.append(4); data(value)
            case .flag(let flag): bytes.append(5); bytes.append(flag ? 1 : 0)
            case .orderedText(let values):
                bytes.append(6); integer(UInt64(values.count)); for value in values { data(Data(value.utf8)) }
            }
        }
        self.version = Self.currentVersion; self.digest = Data(SHA256.hash(data: bytes))
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
