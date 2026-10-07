import Foundation
import IMV2ServerContracts

/// Operation receipts require a positive, PostgreSQL-representable timestamp.
/// Preserve the caller's business error and the existing truncation convention.
func v2PersistenceMilliseconds(_ date: Date, invalid: any Error) throws -> UInt64 {
    guard v2PostgresTimestampCanEncode(date) else { throw invalid }
    return try v2PositiveMilliseconds(date, invalid: invalid)
}

/// Some operation response clocks require only the protocol range, not SQL storage.
func v2PositiveMilliseconds(_ date: Date, invalid: any Error) throws -> UInt64 {
    let value = date.timeIntervalSince1970 * 1_000
    guard value.isFinite, value > 0, value < Double(Int64.max) else { throw invalid }
    return UInt64(try v2GatewayMilliseconds(date))
}

func v2PersistenceUnsigned(_ value: Int64, invalid: any Error) throws -> UInt64 {
    guard value >= 0 else { throw invalid }
    return UInt64(value)
}

func v2EncodePersistenceJSON<Value: Encodable>(_ value: Value) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

func v2DecodePersistenceJSON<Value: Decodable>(_ type: Value.Type, from value: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(value.utf8))
}
