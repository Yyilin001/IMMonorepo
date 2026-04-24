import Foundation

public protocol HTTPClientLogger: Sendable {
    func logRequest(_ request: URLRequest)
    func logResponse(_ response: HTTPURLResponse, data: Data, for request: URLRequest)
    func logError(_ error: Error, for request: URLRequest)
}

public struct HTTPLogHandler: Sendable {
    public let logRequest: @Sendable (URLRequest) -> Void
    public let logResponse: @Sendable (HTTPURLResponse, Data, URLRequest) -> Void
    public let logError: @Sendable (Error, URLRequest) -> Void

    init<Logger: HTTPClientLogger>(_ logger: Logger) {
        logRequest = { request in
            logger.logRequest(request)
        }
        logResponse = { response, data, request in
            logger.logResponse(response, data: data, for: request)
        }
        logError = { error, request in
            logger.logError(error, for: request)
        }
    }

    public static let noop = HTTPLogHandler(NoopHTTPClientLogger())
}

public struct NoopHTTPClientLogger: HTTPClientLogger {
    init() { }
    public func logRequest(_: URLRequest) { }
    public func logResponse(_: HTTPURLResponse, data _: Data, for _: URLRequest) { }
    public func logError(_: Error, for _: URLRequest) { }
}

public struct RedactingHTTPClientLogger: HTTPClientLogger {
    public typealias Sink = @Sendable (String) -> Void

    private static let redactedHeaders: Set<String> = [
        "authorization",
        "cookie",
        "set-cookie"
    ]
    private static let redactedValueKeys: Set<String> = [
        "accesstoken",
        "access_token",
        "refreshtoken",
        "refresh_token",
        "token",
        "password",
        "secret",
        "code",
        "authorization_code",
        "id_token"
    ]

    private let sink: Sink

    init(sink: @escaping Sink = { print($0) }) {
        self.sink = sink
    }

    public func logRequest(_ request: URLRequest) {
        let message = [
            "[HTTP] Request \(request.httpMethod ?? "UNKNOWN") \(sanitizeURL(request.url))",
            "Headers: \(sanitize(headers: request.allHTTPHeaderFields ?? [:]))",
            "Body: \(sanitizeBody(request.httpBody))"
        ].joined(separator: "\n")
        sink(message)
    }

    public func logResponse(_ response: HTTPURLResponse, data: Data, for request: URLRequest) {
        let responseHeaders = response.allHeaderFields.reduce(into: [String: String]()) { partialResult, entry in
            partialResult[String(describing: entry.key)] = String(describing: entry.value)
        }
        let message = [
            "[HTTP] Response \(response.statusCode) \(request.httpMethod ?? "UNKNOWN") \(sanitizeURL(request.url))",
            "Headers: \(sanitize(headers: responseHeaders))",
            "Body: \(sanitizeBody(data))"
        ].joined(separator: "\n")
        sink(message)
    }

    public func logError(_ error: Error, for request: URLRequest) {
        sink("[HTTP] Error \(request.httpMethod ?? "UNKNOWN") \(sanitizeURL(request.url)): \(error.localizedDescription)")
    }

    private func sanitize(headers: [String: String]) -> [String: String] {
        headers.reduce(into: [String: String]()) { partialResult, entry in
            if Self.redactedHeaders.contains(entry.key.lowercased()) {
                partialResult[entry.key] = "<redacted>"
            } else if entry.key.lowercased() == "location",
                      let sanitizedLocation = sanitizeURLString(entry.value)
            {
                partialResult[entry.key] = sanitizedLocation
            } else {
                partialResult[entry.key] = entry.value
            }
        }
    }

    private func sanitizeBody(_ data: Data?) -> String {
        guard let data, !data.isEmpty else {
            return "<empty>"
        }

        if let object = try? JSONSerialization.jsonObject(with: data),
           let sanitized = sanitizeJSON(object),
           let normalizedData = try? JSONSerialization.data(withJSONObject: sanitized, options: [.fragmentsAllowed]),
           let string = String(data: normalizedData, encoding: .utf8)
        {
            return string
        }

        if let string = String(data: data, encoding: .utf8) {
            return String(string.prefix(256))
        }

        return "<\(data.count) bytes>"
    }

    private func sanitizeJSON(_ object: Any) -> Any? {
        switch object {
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { partialResult, entry in
                if Self.redactedValueKeys.contains(entry.key.lowercased()) {
                    partialResult[entry.key] = "<redacted>"
                } else {
                    partialResult[entry.key] = sanitizeJSON(entry.value)
                }
            }
        case let array as [Any]:
            return array.map { sanitizeJSON($0) as Any }
        default:
            return object
        }
    }

    private func sanitizeURL(_ url: URL?) -> String {
        guard let url else {
            return "-"
        }
        return sanitizeURLString(url.absoluteString) ?? url.absoluteString
    }

    private func sanitizeURLString(_ urlString: String) -> String? {
        guard let url = URL(string: urlString),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems.map { item in
                if Self.redactedValueKeys.contains(item.name.lowercased()) {
                    return URLQueryItem(name: item.name, value: "<redacted>")
                }
                return item
            }
        }

        return components.string
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct HTTPCodingConfiguration: Sendable {
    public let makeEncoder: @Sendable () -> JSONEncoder
    public let makeDecoder: @Sendable () -> JSONDecoder

    public init(
        makeEncoder: @escaping @Sendable () -> JSONEncoder = {
            JSONEncoder()
        },
        makeDecoder: @escaping @Sendable () -> JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }
    ) {
        self.makeEncoder = makeEncoder
        self.makeDecoder = makeDecoder
    }

    public static let `default` = HTTPCodingConfiguration()
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return (data, httpResponse)
    }
}

public struct HTTPClient: Sendable {
    public let baseURL: URL
    public let logger: HTTPLogHandler
    public let coding: HTTPCodingConfiguration

    private let sendRequest: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(
        baseURL: URL,
        transport: URLSessionTransport = URLSessionTransport(),
        logger: HTTPLogHandler = .noop,
        coding: HTTPCodingConfiguration = .default
    ) {
        self.init(
            baseURL: baseURL,
            sendRequest: { request in
                try await transport.send(request)
            },
            logger: logger,
            coding: coding
        )
    }

    public init(environment: NetworkEnvironment) {
        self.init(
            baseURL: environment.baseURL,
            transport: URLSessionTransport(session: environment.session),
            logger: environment.logger,
            coding: environment.coding
        )
    }

    public init<Transport: HTTPTransport>(
        baseURL: URL,
        transport: Transport,
        logger: HTTPLogHandler = .noop,
        coding: HTTPCodingConfiguration = .default
    ) {
        self.init(
            baseURL: baseURL,
            sendRequest: { request in
                try await transport.send(request)
            },
            logger: logger,
            coding: coding
        )
    }

    init<Transport: HTTPTransport, Logger: HTTPClientLogger>(
        baseURL: URL,
        transport: Transport,
        logger: Logger,
        coding: HTTPCodingConfiguration = .default
    ) {
        self.init(
            baseURL: baseURL,
            transport: transport,
            logger: HTTPLogHandler(logger),
            coding: coding
        )
    }

    private init(
        baseURL: URL,
        sendRequest: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
        logger: HTTPLogHandler,
        coding: HTTPCodingConfiguration
    ) {
        self.baseURL = baseURL
        self.sendRequest = sendRequest
        self.logger = logger
        self.coding = coding
    }

    public func execute<Request: Endpoint>(
        _ request: Request,
        bearerToken: String? = nil
    ) async throws -> Request.Response {
        if request.requiresAuthorization, bearerToken == nil {
            throw APIError.unauthorized("缺少访问令牌，请重新登录。")
        }

        let body = try request.makeBody(using: coding.makeEncoder())
        let urlRequest = try HTTPRequestBuilder.build(
            spec: request.requestSpec,
            baseURL: baseURL,
            bearerToken: bearerToken,
            cachePolicy: request.cachePolicy,
            accept: "application/json",
            contentType: request.requestContentType ?? (body == nil ? nil : "application/json"),
            body: body
        )
        logger.logRequest(urlRequest)

        let data: Data
        let response: HTTPURLResponse

        do {
            (data, response) = try await sendRequest(urlRequest)
        } catch {
            throw HTTPResponseProcessor.mapTransportError(error, logger: logger, request: urlRequest)
        }

        logger.logResponse(response, data, urlRequest)
        try HTTPResponseProcessor.validate(response: response, data: data, coding: coding)
        return try HTTPResponseProcessor.decode(Request.Response.self, from: data, coding: coding)
    }
}

public struct ServerErrorEnvelope: Decodable {
    public let reason: String?
}

public enum APIError: LocalizedError {
    case invalidResponse
    case unauthorized(String?)
    case forbidden(String)
    case validationFailed(String)
    case payloadTooLarge(String)
    case rateLimited(retryAfter: TimeInterval?, message: String)
    case server(statusCode: Int, message: String)
    case decodingFailed(String)
    case encodingFailed(String)
    case unsupported(String)
    case cancelled
    case timeout
    case connectivity(Error)

    public var isUnauthorized: Bool {
        if case .unauthorized = self {
            return true
        }
        return false
    }

    public var isConnectivityFailure: Bool {
        if case .connectivity = self {
            return true
        }
        return false
    }

    public var shouldPreserveSession: Bool {
        switch self {
        case .cancelled, .timeout, .connectivity, .rateLimited, .payloadTooLarge:
            return true
        case .server(let statusCode, _):
            return 500..<600 ~= statusCode
        case .invalidResponse, .unauthorized, .forbidden, .validationFailed, .decodingFailed, .encodingFailed, .unsupported:
            return false
        }
    }

    public var shouldMarkServerOffline: Bool {
        switch self {
        case .timeout, .connectivity:
            return true
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无效响应。"
        case .unauthorized(let reason):
            return reason ?? "当前登录已失效，请重新登录。"
        case .forbidden(let message):
            return message
        case .validationFailed(let message):
            return message
        case .payloadTooLarge(let message):
            return message
        case .rateLimited(let retryAfter, let message):
            if let retryAfter {
                return "\(message) 请在 \(Int(retryAfter)) 秒后重试。"
            }
            return message
        case .server(_, let message):
            return message
        case .decodingFailed(let message):
            return "解析服务器响应失败：\(message)"
        case .encodingFailed(let message):
            return "编码请求失败：\(message)"
        case .unsupported(let message):
            return message
        case .cancelled:
            return "请求已取消。"
        case .timeout:
            return "请求超时，请稍后重试。"
        case .connectivity:
            return "当前无法连接服务器。"
        }
    }
}
