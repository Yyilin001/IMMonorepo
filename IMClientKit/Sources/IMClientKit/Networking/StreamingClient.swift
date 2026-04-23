import Foundation

public struct StreamingClient: Sendable {
    public let baseURL: URL
    public let logger: HTTPLogHandler
    public let coding: HTTPCodingConfiguration

    private let openRequest: @Sendable (URLRequest) async throws -> (HTTPByteStream, HTTPURLResponse)

    public init(
        baseURL: URL = AppConstants.apiBaseURL,
        transport: URLSessionStreamingTransport = URLSessionStreamingTransport(),
        logger: HTTPLogHandler = .noop,
        coding: HTTPCodingConfiguration = .default
    ) {
        self.init(
            baseURL: baseURL,
            openRequest: { request in
                try await transport.open(request)
            },
            logger: logger,
            coding: coding
        )
    }

    public init(environment: NetworkEnvironment) {
        self.init(
            baseURL: environment.baseURL,
            transport: URLSessionStreamingTransport(session: environment.session),
            logger: environment.logger,
            coding: environment.coding
        )
    }

    init<Transport: StreamingTransport>(
        baseURL: URL = AppConstants.apiBaseURL,
        transport: Transport,
        logger: HTTPLogHandler = .noop,
        coding: HTTPCodingConfiguration = .default
    ) {
        self.init(
            baseURL: baseURL,
            openRequest: { request in
                try await transport.open(request)
            },
            logger: logger,
            coding: coding
        )
    }

    init<Transport: StreamingTransport, Logger: HTTPClientLogger>(
        baseURL: URL = AppConstants.apiBaseURL,
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
        openRequest: @escaping @Sendable (URLRequest) async throws -> (HTTPByteStream, HTTPURLResponse),
        logger: HTTPLogHandler,
        coding: HTTPCodingConfiguration
    ) {
        self.baseURL = baseURL
        self.openRequest = openRequest
        self.logger = logger
        self.coding = coding
    }

    public func openStream<Request: StreamingEndpoint>(
        _ request: Request,
        bearerToken: String? = nil
    ) async throws -> StreamingConnection {
        if request.requiresAuthorization, bearerToken == nil {
            throw APIError.unauthorized("缺少访问令牌，请重新登录。")
        }

        let urlRequest = try buildRequest(for: request, bearerToken: bearerToken)
        logger.logRequest(urlRequest)

        let bytes: HTTPByteStream
        let response: HTTPURLResponse

        do {
            (bytes, response) = try await openRequest(urlRequest)
        } catch {
            throw HTTPResponseProcessor.mapTransportError(error, logger: logger, request: urlRequest)
        }

        if !(200..<300 ~= response.statusCode) {
            let errorData = try await bytes.collectData(maxBytes: 64 * 1024)
            logger.logResponse(response, errorData, urlRequest)
            try HTTPResponseProcessor.validate(response: response, data: errorData, coding: coding)
        }

        logger.logResponse(response, Data("<stream-opened>".utf8), urlRequest)

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let producer = Task.detached(priority: .utility) {
                var buffer = Data()
                let chunkSize = max(request.preferredChunkSize, 1)

                do {
                    for try await byte in bytes.bytes {
                        buffer.append(byte)
                        if buffer.count >= chunkSize {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }

                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                producer.cancel()
            }
        }

        return StreamingConnection(chunks: stream)
    }

    private func buildRequest<Request: StreamingEndpoint>(
        for request: Request,
        bearerToken: String?
    ) throws -> URLRequest {
        let body = try request.makeBody(using: coding.makeEncoder())
        return try HTTPRequestBuilder.build(
            spec: HTTPRequestSpec(
                path: request.path,
                method: request.method,
                headers: request.headers,
                queryItems: request.queryItems,
                timeout: request.timeout ?? 300,
                requiresAuthorization: request.requiresAuthorization
            ),
            baseURL: baseURL,
            bearerToken: bearerToken,
            cachePolicy: request.cachePolicy,
            contentType: request.requestContentType ?? (body == nil ? nil : "application/json"),
            body: body
        )
    }
}
