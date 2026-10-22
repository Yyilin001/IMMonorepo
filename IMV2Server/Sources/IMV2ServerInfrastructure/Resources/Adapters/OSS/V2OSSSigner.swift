import Crypto
import Foundation
import IMV2ServerApplication

/// Credentials remain inside the OSS adapter. Callers may supply refreshed STS credentials.
public struct V2OSSCredentials: Sendable {
    let accessKeyID: String
    let accessKeySecret: String
    let securityToken: String?
    public init(accessKeyID: String, accessKeySecret: String, securityToken: String? = nil) {
        self.accessKeyID = accessKeyID; self.accessKeySecret = accessKeySecret; self.securityToken = securityToken
    }
}

/// OSS V4 differs from AWS SigV4 (notably the bucket in the canonical URI).
/// Reference: Alibaba Cloud OSS V4 authentication specification and SDK test vectors.
struct V2OSSSigner: Sendable {
    let region: String
    let bucket: String
    let credentials: V2OSSCredentials

    func authorization(method: String, key: String, query: [String: String] = [:],
                       headers: [String: String] = [:], additionalHeaders: Set<String> = [],
                       now: Date) throws -> [String: String] {
        var result = try normalized(headers)
        let timestamp = Self.timestamp(now)
        result["x-oss-date"] = timestamp
        result["x-oss-content-sha256"] = "UNSIGNED-PAYLOAD"
        if let token = credentials.securityToken { result["x-oss-security-token"] = token }
        result = try normalized(result)
        let additional = try additionalNames(additionalHeaders, headers: result)
        let signature = try signature(method: method, key: key, query: query, headers: result,
                                      additional: additional, timestamp: timestamp)
        let extra = additional.isEmpty ? "" : ",AdditionalHeaders=\(additional.joined(separator: ";"))"
        result["authorization"] = "OSS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope(timestamp))\(extra),Signature=\(signature)"
        return result
    }

    func presignedURL(endpoint: URL, method: String, key: String, query: [String: String] = [:],
                      headers: [String: String] = [:], additionalHeaders: Set<String> = [],
                      now: Date, expiresAt: Date) throws -> URL {
        // Whole-second timestamps must never extend the upper authorization deadline.
        let start = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        let duration = floor(expiresAt.timeIntervalSince(start))
        guard duration >= 1, duration <= 604_800, expiresAt > now,
              !query.keys.contains(where: { $0.lowercased().hasPrefix("x-oss-") }),
              endpoint.scheme == "https", endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.isEmpty || endpoint.path == "/"
        else { throw V2ResourceProviderError.configurationInvalid }
        let normalizedHeaders = try normalized(headers)
        guard normalizedHeaders["x-oss-content-sha256"] == nil else {
            throw V2ResourceProviderError.configurationInvalid
        }
        let additional = try additionalNames(additionalHeaders, headers: normalizedHeaders)
        let timestamp = Self.timestamp(start)
        var parameters = query
        parameters["x-oss-signature-version"] = "OSS4-HMAC-SHA256"
        parameters["x-oss-credential"] = "\(credentials.accessKeyID)/\(scope(timestamp))"
        parameters["x-oss-date"] = timestamp
        parameters["x-oss-expires"] = String(Int(duration))
        if let token = credentials.securityToken { parameters["x-oss-security-token"] = token }
        if !additional.isEmpty { parameters["x-oss-additional-headers"] = additional.joined(separator: ";") }
        parameters["x-oss-signature"] = try signature(method: method, key: key, query: parameters,
            headers: normalizedHeaders, additional: additional, timestamp: timestamp)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw V2ResourceProviderError.configurationInvalid
        }
        components.percentEncodedPath = "/" + Self.encode(key, preserveSlash: true)
        components.percentEncodedQuery = Self.queryString(parameters)
        guard let url = components.url else { throw V2ResourceProviderError.configurationInvalid }
        return url
    }

    private func signature(method: String, key: String, query: [String: String],
                           headers: [String: String], additional: [String], timestamp: String) throws -> String {
        guard !credentials.accessKeyID.isEmpty, !credentials.accessKeySecret.isEmpty,
              !region.isEmpty, !bucket.isEmpty,
              [credentials.accessKeyID, region, bucket].allSatisfy({ value in
                  value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95, 126].contains($0) }
              })
        else { throw V2ResourceProviderError.configurationInvalid }
        let canonicalHeaders = headers.keys.filter { Self.required($0) || additional.contains($0) }
            .sorted().map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let canonical = [method.uppercased(), Self.encode("/\(bucket)/\(key)", preserveSlash: true),
                         Self.queryString(query), canonicalHeaders, additional.joined(separator: ";"),
                         "UNSIGNED-PAYLOAD"].joined(separator: "\n")
        let message = ["OSS4-HMAC-SHA256", timestamp, scope(timestamp),
                       Self.hex(Data(SHA256.hash(data: Data(canonical.utf8))))].joined(separator: "\n")
        var signingKey = Data(("aliyun_v4" + credentials.accessKeySecret).utf8)
        for part in [String(timestamp.prefix(8)), region, "oss", "aliyun_v4_request"] {
            signingKey = Self.hmac(signingKey, part)
        }
        return Self.hex(Self.hmac(signingKey, message))
    }

    private func normalized(_ headers: [String: String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            let lower = name.lowercased()
            guard !lower.isEmpty, lower != "authorization",
                  lower.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }),
                  result.updateValue(value, forKey: lower) == nil
            else { throw V2ResourceProviderError.configurationInvalid }
        }
        return result
    }
    private func additionalNames(_ names: Set<String>, headers: [String: String]) throws -> [String] {
        let names = Set(names.map { $0.lowercased() }).filter { !Self.required($0) }
        guard names.allSatisfy({ headers[$0] != nil }) else { throw V2ResourceProviderError.configurationInvalid }
        return names.sorted()
    }
    private static func required(_ name: String) -> Bool {
        name == "content-type" || name == "content-md5" || name.hasPrefix("x-oss-")
    }
    private func scope(_ timestamp: String) -> String {
        "\(timestamp.prefix(8))/\(region)/oss/aliyun_v4_request"
    }
    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
    static func encode(_ value: String, preserveSlash: Bool = false) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || [45, 46, 95, 126].contains(byte) || (preserveSlash && byte == 47) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    static func queryString(_ query: [String: String]) -> String {
        query.map { (encode($0.key), encode($0.value)) }.sorted { $0.0 < $1.0 }
            .map { $0.1.isEmpty ? $0.0 : "\($0.0)=\($0.1)" }.joined(separator: "&")
    }
    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    private static func hmac(_ key: Data, _ value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }
}
