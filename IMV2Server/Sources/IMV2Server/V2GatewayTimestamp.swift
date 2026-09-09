import Foundation

enum V2GatewayTimestampError: Error {
    case unrepresentable
}

/// Preserve the wire's millisecond truncation while rejecting non-finite or
/// overflowing server/domain dates before encoding any response or hint.
func v2GatewayMilliseconds(_ date: Date) throws -> Int64 {
    guard let value = Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)) else {
        throw V2GatewayTimestampError.unrepresentable
    }
    return value
}
