#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

enum S3MediaSigningSupport {
    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    static func signingKey(secret: String, date: String, region: String, service: String) -> SymmetricKey {
        let secretKey = SymmetricKey(data: Data(("AWS4" + secret).utf8))
        let dateKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(date.utf8), using: secretKey)))
        let regionKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(region.utf8), using: dateKey)))
        let serviceKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(service.utf8), using: regionKey)))
        return SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data("aws4_request".utf8), using: serviceKey)))
    }
}

extension HMAC<SHA256>.MAC {
    var hexString: String {
        Data(self).map { String(format: "%02x", $0) }.joined()
    }
}

extension Digest {
    var hexString: String {
        Data(self).map { String(format: "%02x", $0) }.joined()
    }
}
