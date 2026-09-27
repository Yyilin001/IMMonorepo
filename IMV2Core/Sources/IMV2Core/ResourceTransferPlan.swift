import Foundation

/// 客户端实际支持的有限传输模式，HTTP 方法由模式唯一决定。
public enum V2ResourceTransferMode: String, Codable, CaseIterable, Sendable {
    case httpPut = "http_put"
    case httpFormPost = "http_form_post"
    case httpPartPut = "http_part_put"
    case httpGet = "http_get"
    case httpRangeGet = "http_range_get"

    public var httpMethod: String {
        switch self {
        case .httpPut, .httpPartPut: "PUT"
        case .httpFormPost: "POST"
        case .httpGet, .httpRangeGet: "GET"
        }
    }

    public var isUpload: Bool {
        switch self {
        case .httpPut, .httpPartPut, .httpFormPost: true
        case .httpGet, .httpRangeGet: false
        }
    }
}

/// 只允许适配器生成的内容头或明确的短期对象能力；禁止复用业务登录凭据。
public struct V2ResourceTransferHeader: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case content
        case objectCapability = "object_capability"
    }

    public let name: String
    public let value: String
    public let kind: Kind

    public init(name: String, value: String, kind: Kind = .content) throws {
        let canonical = name.lowercased()
        let forbidden: Set<String> = ["host", "cookie", "set-cookie", "connection", "proxy-connection",
            "proxy-authorization", "proxy-authenticate", "transfer-encoding", "content-length", "range",
            "te", "trailer", "upgrade", "keep-alive", "expect", "referer", "origin"]
        guard !name.isEmpty, name.utf8.count <= 128, value.utf8.count <= 8_192,
              name.utf8.allSatisfy(Self.isToken),
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }),
              !forbidden.contains(canonical),
              !canonical.hasPrefix("sec-"),
              !canonical.hasPrefix("proxy-"),
              !canonical.hasPrefix("x-forwarded-"),
              canonical != "authorization" || kind == .objectCapability
        else { throw V2ResourceValidationError.invalidTransferHeader }
        self.name = name
        self.value = value
        self.kind = kind
    }

    private static func isToken(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
            || [33,35,36,37,38,39,42,43,45,46,94,95,96,124,126].contains(byte)
    }

    private enum CodingKeys: String, CodingKey { case name, value, kind }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(name: values.decode(String.self, forKey: .name), value: values.decode(String.self, forKey: .value), kind: values.decode(Kind.self, forKey: .kind))
    }
}

/// 仅限经过认证的 HTTP 响应/内存中的短期计划，不得保存到 journal、消息、日志或备份。
///
/// Codable 只用于传输边界，解码始终重复构造校验。目标来源允许列表、当前期限和能力协商
/// 仍由服务端装配及客户端网络边界检查；此值不证明用户已获业务权限。
public struct V2ResourceTransferPlan: Equatable, Codable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let mode: V2ResourceTransferMode
    public let url: URL
    public let headers: [V2ResourceTransferHeader]
    public let formFields: [String: String]
    public let formFileField: String?
    public let expiresAtUnixMilliseconds: Int64
    public let expectedByteCount: Int64
    public let byteRange: V2ResourceByteRange?
    public let partNumber: Int?
    public let checksum: V2ResourceChecksum?

    public var expiresAt: Date { V2ResourceTime.date(expiresAtUnixMilliseconds) }
    public var httpMethod: String { mode.httpMethod }

    public init(version: Int = Self.currentVersion, mode: V2ResourceTransferMode, url: URL,
                headers: [V2ResourceTransferHeader] = [], formFields: [String: String] = [:],
                formFileField: String? = nil, expiresAt: Date, expectedByteCount: Int64,
                byteRange: V2ResourceByteRange? = nil, partNumber: Int? = nil,
                checksum: V2ResourceChecksum? = nil) throws {
        try self.init(version: version, mode: mode, url: url, headers: headers, formFields: formFields,
                      formFileField: formFileField, expiresAtUnixMilliseconds: V2ResourceTime.milliseconds(expiresAt),
                      expectedByteCount: expectedByteCount, byteRange: byteRange, partNumber: partNumber, checksum: checksum)
    }

    private init(version: Int, mode: V2ResourceTransferMode, url: URL,
                 headers: [V2ResourceTransferHeader], formFields: [String: String], formFileField: String?,
                 expiresAtUnixMilliseconds: Int64, expectedByteCount: Int64,
                 byteRange: V2ResourceByteRange?, partNumber: Int?, checksum: V2ResourceChecksum?) throws {
        guard version == Self.currentVersion, url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil,
              url.absoluteString.utf8.count <= 8_192, expectedByteCount >= 0,
              headers.count <= 32, Set(headers.map { $0.name.lowercased() }).count == headers.count,
              headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 16_384,
              formFields.count <= 32,
              formFields.allSatisfy({ Self.validFormName($0.key) && $0.value.utf8.count <= 8_192
                  && $0.value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) }),
              formFields.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 16_384
        else { throw V2ResourceValidationError.invalidTransferPlan }
        switch mode {
        case .httpPut, .httpGet:
            guard byteRange == nil, partNumber == nil, formFields.isEmpty, formFileField == nil
            else { throw V2ResourceValidationError.invalidTransferPlan }
        case .httpFormPost:
            guard let formFileField, Self.validFormName(formFileField), formFields[formFileField] == nil,
                  byteRange == nil, partNumber == nil,
                  !headers.contains(where: { $0.name.lowercased() == "content-type" })
            else { throw V2ResourceValidationError.invalidTransferPlan }
        case .httpPartPut:
            guard let byteRange, let partNumber, (1...10_000).contains(partNumber),
                  expectedByteCount == byteRange.byteCount, formFields.isEmpty, formFileField == nil
            else { throw V2ResourceValidationError.invalidTransferPlan }
        case .httpRangeGet:
            guard let byteRange, expectedByteCount == byteRange.byteCount, partNumber == nil,
                  formFields.isEmpty, formFileField == nil
            else { throw V2ResourceValidationError.invalidTransferPlan }
        }
        self.version = version
        self.mode = mode
        self.url = url
        self.headers = headers
        self.formFields = formFields
        self.formFileField = formFileField
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
        self.expectedByteCount = expectedByteCount
        self.byteRange = byteRange
        self.partNumber = partNumber
        self.checksum = checksum
    }

    private static func validFormName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, mode, url, headers, formFields, formFileField, expiresAtUnixMilliseconds
        case expectedByteCount, byteRange, partNumber, checksum
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: values.decode(Int.self, forKey: .version), mode: values.decode(V2ResourceTransferMode.self, forKey: .mode),
                      url: values.decode(URL.self, forKey: .url), headers: values.decode([V2ResourceTransferHeader].self, forKey: .headers),
                      formFields: values.decode([String: String].self, forKey: .formFields), formFileField: values.decodeIfPresent(String.self, forKey: .formFileField),
                      expiresAtUnixMilliseconds: values.decode(Int64.self, forKey: .expiresAtUnixMilliseconds),
                      expectedByteCount: values.decode(Int64.self, forKey: .expectedByteCount),
                      byteRange: values.decodeIfPresent(V2ResourceByteRange.self, forKey: .byteRange),
                      partNumber: values.decodeIfPresent(Int.self, forKey: .partNumber), checksum: values.decodeIfPresent(V2ResourceChecksum.self, forKey: .checksum))
    }
}
