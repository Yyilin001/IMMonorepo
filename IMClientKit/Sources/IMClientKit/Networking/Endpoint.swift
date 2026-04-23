import Foundation

public protocol APIResponseBody: Sendable {
    static func decode(from data: Data, using decoder: JSONDecoder) throws -> Self
}

public extension APIResponseBody where Self: Decodable {
    static func decode(from data: Data, using decoder: JSONDecoder) throws -> Self {
        try decoder.decode(Self.self, from: data)
    }
}

extension Array: APIResponseBody where Element: APIResponseBody & Decodable {
    public static func decode(from data: Data, using decoder: JSONDecoder) throws -> [Element] {
        try decoder.decode([Element].self, from: data)
    }
}

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"
    case trace = "TRACE"
    case connect = "CONNECT"
}

public struct HTTPRequestSpec: Sendable {
    public let path: String
    public let method: HTTPMethod
    public let headers: [String: String]
    public let queryItems: [URLQueryItem]
    public let timeout: TimeInterval?
    public let requiresAuthorization: Bool

    init(
        path: String,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval? = nil,
        requiresAuthorization: Bool = false
    ) {
        self.path = path
        self.method = method
        self.headers = headers
        self.queryItems = queryItems
        self.timeout = timeout
        self.requiresAuthorization = requiresAuthorization
    }

    public static func authorized(
        path: String,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval? = nil
    ) -> Self {
        Self(
            path: path,
            method: method,
            headers: headers,
            queryItems: queryItems,
            timeout: timeout,
            requiresAuthorization: true
        )
    }

    public func requiringAuthorization(_ requiresAuthorization: Bool = true) -> Self {
        Self(
            path: path,
            method: method,
            headers: headers,
            queryItems: queryItems,
            timeout: timeout,
            requiresAuthorization: requiresAuthorization
        )
    }
}

public protocol RequestSpecProviding: Sendable {
    var requestSpec: HTTPRequestSpec { get }
}

public protocol AuthorizedRequestSpecProviding: Sendable {
    var baseRequestSpec: HTTPRequestSpec { get }
}

public protocol RequestBodyCapability: Sendable {
    var requestContentType: String? { get }
    func makeBody(using encoder: JSONEncoder) throws -> Data?
}

public protocol Endpoint: RequestSpecProviding, RequestBodyCapability, RequestExecutionOptionsProviding {
    associatedtype Response: APIResponseBody
}

public protocol AuthorizedEndpoint: Endpoint, AuthorizedRequestSpecProviding { }

extension RequestSpecProviding {
    var path: String { requestSpec.path }
    var method: HTTPMethod { requestSpec.method }
    var headers: [String: String] { requestSpec.headers }
    var queryItems: [URLQueryItem] { requestSpec.queryItems }
    var timeout: TimeInterval? { requestSpec.timeout }
    var requiresAuthorization: Bool { requestSpec.requiresAuthorization }
}

extension AuthorizedRequestSpecProviding {
    public var requestSpec: HTTPRequestSpec {
        baseRequestSpec.requiringAuthorization()
    }
}

extension RequestBodyCapability {
    public var requestContentType: String? { nil }
    public func makeBody(using _: JSONEncoder) throws -> Data? {
        nil
    }
}

extension Endpoint {
    public var transportKind: TransportKind { .request }
}

public struct EmptyResponse: APIResponseBody, Sendable {
    public static func decode(from _: Data, using _: JSONDecoder) throws -> Self {
        EmptyResponse()
    }
}
