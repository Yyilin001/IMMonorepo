import Foundation

/// Authentication for the loopback-only operator service. The credential is
/// an independently provisioned, high-entropy bearer secret; it is never a
/// user/device access token and never enters the public gateway process.
public struct V2OperatorReplayBearerAuthenticator: Sendable {
    private let key: V2AccessTokenHMACKey
    private let expectedDigest: Data

    public init(base64EncodedBearerToken token: String) throws {
        guard let bytes = Data(base64Encoded: token), bytes.count >= 32 else {
            throw V2GatewayAuthenticationError.invalidKeyMaterial
        }
        key = try .init(rawBytes: bytes)
        expectedDigest = Data(key.digest(token).utf8)
    }

    public func isAuthorized(bearerToken: String?) -> Bool {
        guard let bearerToken, !bearerToken.isEmpty else { return false }
        return v2ConstantTimeEqual(Data(key.digest(bearerToken).utf8), expectedDigest)
    }
}

private func v2ConstantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    let maximumCount = max(lhs.count, rhs.count)
    var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
    for index in 0..<maximumCount {
        let left = index < lhs.count ? lhs[lhs.index(lhs.startIndex, offsetBy: index)] : 0
        let right = index < rhs.count ? rhs[rhs.index(rhs.startIndex, offsetBy: index)] : 0
        difference |= left ^ right
    }
    return difference == 0
}
