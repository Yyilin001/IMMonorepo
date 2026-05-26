import Foundation

public enum HTTPRequestBuilder {
    public static func build(
        spec: HTTPRequestSpec,
        baseURL: URL,
        bearerToken: String?,
        cachePolicy: RequestCachePolicy = .useProtocolCachePolicy,
        accept: String? = nil,
        contentType: String? = nil,
        body: Data? = nil
    ) throws -> URLRequest {
        try build(
            baseURL: baseURL,
            path: spec.path,
            method: spec.method,
            headers: spec.headers,
            queryItems: spec.queryItems,
            timeout: spec.timeout,
            bearerToken: bearerToken,
            cachePolicy: cachePolicy,
            accept: accept,
            contentType: contentType,
            body: body
        )
    }

    public static func build(
        baseURL: URL,
        path: String,
        method: HTTPMethod,
        headers: [String: String] = [:],
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval?,
        bearerToken: String?,
        cachePolicy: RequestCachePolicy = .useProtocolCachePolicy,
        accept: String? = nil,
        contentType: String? = nil,
        body: Data? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidResponse
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = timeout ?? 15
        request.cachePolicy = cachePolicy.urlRequestCachePolicy

        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }

        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        for (header, value) in headers {
            request.setValue(value, forHTTPHeaderField: header)
        }

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if let body {
            request.httpBody = body
        }

        return request
    }
}

public enum HTTPResponseProcessor {
    public static func validate(
        response: HTTPURLResponse,
        data: Data,
        coding: HTTPCodingConfiguration
    ) throws {
        guard 200..<300 ~= response.statusCode else {
            let serverError = try? coding.makeDecoder().decode(ServerErrorEnvelope.self, from: data)
            let message = serverError?.reason ?? "请求失败，状态码 \(response.statusCode)。"

            if response.statusCode == 401 {
                throw APIError.unauthorized(serverError?.reason)
            }

            switch response.statusCode {
            case 403:
                if message.contains("邮箱尚未验证") {
                    throw APIError.emailVerificationRequired(email: nil, message: message)
                }
                throw APIError.forbidden(message)
            case 413:
                throw APIError.payloadTooLarge(message)
            case 422:
                throw APIError.validationFailed(message)
            case 429:
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                throw APIError.rateLimited(retryAfter: retryAfter, message: message)
            case 400:
                if message.contains("验证码已过期") {
                    throw APIError.verificationCodeExpired(message)
                }
                if message.contains("验证码无效") {
                    throw APIError.verificationCodeInvalid(message)
                }
                if message.contains("密码") {
                    throw APIError.passwordPolicyFailed(message)
                }
                throw APIError.validationFailed(message)
            default:
                throw APIError.server(statusCode: response.statusCode, message: message)
            }
        }
    }

    public static func decode<Response: APIResponseBody>(
        _: Response.Type,
        from data: Data,
        coding: HTTPCodingConfiguration
    ) throws -> Response {
        do {
            return try Response.decode(from: data, using: coding.makeDecoder())
        } catch {
            throw APIError.decodingFailed(error.localizedDescription)
        }
    }

    public static func mapTransportError(
        _ error: Error,
        logger: HTTPLogHandler,
        request: URLRequest
    ) -> APIError {
        if error is CancellationError {
            logger.logError(APIError.cancelled, request)
            return .cancelled
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                logger.logError(APIError.cancelled, request)
                return .cancelled
            case .timedOut:
                logger.logError(APIError.timeout, request)
                return .timeout
            default:
                logger.logError(urlError, request)
                return .connectivity(urlError)
            }
        }

        logger.logError(error, request)
        if let apiError = error as? APIError {
            return apiError
        }
        return .connectivity(error)
    }
}

public protocol FileTransferTransport: Sendable {
    func upload(_ request: URLRequest, from data: Data) async throws -> (Data, HTTPURLResponse)
    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse)
    func uploadWithProgress(_ request: URLRequest, from data: Data) async -> AsyncThrowingStream<UploadTransportEvent, Error>
    func uploadWithProgress(_ request: URLRequest, fromFile fileURL: URL) async -> AsyncThrowingStream<UploadTransportEvent, Error>
    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse)
    func streamDownload(_ request: URLRequest) async throws -> (HTTPByteStream, HTTPURLResponse)
}

public enum UploadTransportEvent: Sendable {
    case progress(transferredBytes: Int64, totalBytes: Int64?)
    case completed(Data, HTTPURLResponse)
}

public struct URLSessionFileTransferTransport: FileTransferTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func upload(_ request: URLRequest, from data: Data) async throws -> (Data, HTTPURLResponse) {
        let (responseData, response) = try await session.upload(for: request, from: data)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return (responseData, httpResponse)
    }

    public func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        let (responseData, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return (responseData, httpResponse)
    }

    public func uploadWithProgress(_ request: URLRequest, from data: Data) async -> AsyncThrowingStream<UploadTransportEvent, Error> {
        UploadProgressTask(request: request, uploadSource: .data(data)).stream()
    }

    public func uploadWithProgress(_ request: URLRequest, fromFile fileURL: URL) async -> AsyncThrowingStream<UploadTransportEvent, Error> {
        UploadProgressTask(request: request, uploadSource: .file(fileURL)).stream()
    }

    public func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (downloadedURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return (downloadedURL, httpResponse)
    }

    public func streamDownload(_ request: URLRequest) async throws -> (HTTPByteStream, HTTPURLResponse) {
        let (rawBytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        let byteStream = HTTPByteStream(
            bytes: AsyncThrowingStream { continuation in
                let producer = Task.detached(priority: .utility) {
                    do {
                        for try await byte in rawBytes {
                            continuation.yield(byte)
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
        )

        return (byteStream, httpResponse)
    }
}

private final class UploadProgressTask: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    public enum UploadSource {
        case data(Data)
        case file(URL)
    }

    private let request: URLRequest
    private let uploadSource: UploadSource
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<UploadTransportEvent, Error>.Continuation?
    private var responseData = Data()
    private var response: HTTPURLResponse?
    private var session: URLSession?
    private var task: URLSessionUploadTask?

    init(request: URLRequest, uploadSource: UploadSource) {
        self.request = request
        self.uploadSource = uploadSource
    }

    public func stream() -> AsyncThrowingStream<UploadTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            self.withStateLock {
                self.continuation = continuation
            }
            let session = URLSession(
                configuration: .ephemeral,
                delegate: self,
                delegateQueue: nil
            )
            self.withStateLock {
                self.session = session
            }

            let task: URLSessionUploadTask
            switch uploadSource {
            case .data(let data):
                task = session.uploadTask(with: request, from: data)
            case .file(let fileURL):
                task = session.uploadTask(with: request, fromFile: fileURL)
            }
            self.withStateLock {
                self.task = task
            }
            task.resume()

            continuation.onTermination = { _ in
                let (task, session) = self.withStateLock {
                    let task = self.task
                    let session = self.session
                    self.task = nil
                    self.session = nil
                    self.continuation = nil
                    return (task, session)
                }
                task?.cancel()
                session?.invalidateAndCancel()
            }
        }
    }

    public func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        withStateLock {
            self.response = response as? HTTPURLResponse
        }
        completionHandler(.allow)
    }

    public func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive data: Data
    ) {
        withStateLock {
            responseData.append(data)
        }
    }

    public func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didSendBodyData _: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let continuation = withStateLock { self.continuation }
        continuation?.yield(
            .progress(
                transferredBytes: totalBytesSent,
                totalBytes: totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil
            )
        )
    }

    public func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let (continuation, responseData, response, session) = withStateLock {
            let continuation = self.continuation
            let responseData = self.responseData
            let response = self.response
            let session = self.session
            self.task = nil
            self.session = nil
            return (continuation, responseData, response, session)
        }

        defer {
            session?.finishTasksAndInvalidate()
        }

        if let error {
            continuation?.finish(throwing: error)
            return
        }

        guard let response else {
            continuation?.finish(throwing: APIError.invalidResponse)
            return
        }

        continuation?.yield(.completed(responseData, response))
        continuation?.finish()
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

public struct HTTPByteStream: Sendable {
    public let bytes: AsyncThrowingStream<UInt8, Error>

    public init(bytes: AsyncThrowingStream<UInt8, Error>) {
        self.bytes = bytes
    }

    public func collectData(maxBytes: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(maxBytes, 4096))

        for try await byte in bytes {
            guard data.count < maxBytes else {
                break
            }
            data.append(byte)
        }

        return data
    }
}

public protocol StreamingTransport: Sendable {
    func open(_ request: URLRequest) async throws -> (HTTPByteStream, HTTPURLResponse)
}

public struct URLSessionStreamingTransport: StreamingTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func open(_ request: URLRequest) async throws -> (HTTPByteStream, HTTPURLResponse) {
        let (rawBytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        let byteStream = HTTPByteStream(
            bytes: AsyncThrowingStream { continuation in
                let producer = Task.detached(priority: .utility) {
                    do {
                        for try await byte in rawBytes {
                            continuation.yield(byte)
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
        )

        return (byteStream, httpResponse)
    }
}
