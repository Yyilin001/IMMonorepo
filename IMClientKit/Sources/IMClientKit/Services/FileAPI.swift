import Foundation

public struct FileUploadRequest<Response: APIResponseBody & Sendable>: RequestSpecProviding, RequestExecutionOptionsProviding, BackgroundTransferCapability {
    public let requestSpec: HTTPRequestSpec
    public let uploadBody: UploadBody
    public let retryPolicy: RetryPolicy
    public let cachePolicy: RequestCachePolicy
    public let backgroundTransfer: BackgroundTransferConfiguration?

    public var transportKind: TransportKind {
        backgroundTransfer == nil ? .upload : .backgroundUpload
    }

    public init(
        path: String,
        method: HTTPMethod = .post,
        headers: [String: String] = [:],
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval? = nil,
        uploadBody: UploadBody,
        retryPolicy: RetryPolicy = .useDefault,
        cachePolicy: RequestCachePolicy = .reloadIgnoringLocalCacheData,
        backgroundTransfer: BackgroundTransferConfiguration? = nil
    ) {
        self.requestSpec = HTTPRequestSpec(
            path: path,
            method: method,
            headers: headers,
            queryItems: queryItems,
            timeout: timeout
        )
        self.uploadBody = uploadBody
        self.retryPolicy = retryPolicy
        self.cachePolicy = cachePolicy
        self.backgroundTransfer = backgroundTransfer
    }
}

public struct FileDownloadRequest: RequestSpecProviding, RequestExecutionOptionsProviding, BackgroundTransferCapability {
    public let destinationURL: URL
    public let requestSpec: HTTPRequestSpec
    public let resumeIfPossible: Bool
    public let retryPolicy: RetryPolicy
    public let cachePolicy: RequestCachePolicy
    public let backgroundTransfer: BackgroundTransferConfiguration?

    public var transportKind: TransportKind {
        backgroundTransfer == nil ? .download : .backgroundDownload
    }

    public init(
        path: String,
        destinationURL: URL,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval? = nil,
        resumeIfPossible: Bool = true,
        retryPolicy: RetryPolicy = .useDefault,
        cachePolicy: RequestCachePolicy = .reloadIgnoringLocalCacheData,
        backgroundTransfer: BackgroundTransferConfiguration? = nil
    ) {
        self.destinationURL = destinationURL
        self.requestSpec = HTTPRequestSpec(
            path: path,
            method: method,
            headers: headers,
            queryItems: queryItems,
            timeout: timeout
        )
        self.resumeIfPossible = resumeIfPossible
        self.retryPolicy = retryPolicy
        self.cachePolicy = cachePolicy
        self.backgroundTransfer = backgroundTransfer
    }
}

public struct FileAPI: Sendable {
    public let sessionClient: SessionClient

    public init(sessionClient: SessionClient) {
        self.sessionClient = sessionClient
    }

    public func upload<Response: APIResponseBody & Sendable>(
        _ request: FileUploadRequest<Response>
    ) async throws -> Response {
        try await sessionClient.upload(
            UploadFileEndpoint(
                baseRequestSpec: request.requestSpec,
                uploadBody: request.uploadBody,
                retryPolicy: request.retryPolicy,
                cachePolicy: request.cachePolicy,
                backgroundTransfer: request.backgroundTransfer
            )
        )
    }

    public func uploadWithProgress<Response: APIResponseBody & Sendable>(
        _ request: FileUploadRequest<Response>
    ) async throws -> FileTransferOperation<UploadTransferEvent<Response>> {
        try await sessionClient.uploadWithProgress(
            UploadFileEndpoint(
                baseRequestSpec: request.requestSpec,
                uploadBody: request.uploadBody,
                retryPolicy: request.retryPolicy,
                cachePolicy: request.cachePolicy,
                backgroundTransfer: request.backgroundTransfer
            )
        )
    }

    public func download(_ request: FileDownloadRequest) async throws -> URL {
        try await sessionClient.download(
            DownloadFileEndpoint(
                baseRequestSpec: request.requestSpec,
                retryPolicy: request.retryPolicy,
                cachePolicy: request.cachePolicy,
                backgroundTransfer: request.backgroundTransfer
            ),
            to: request.destinationURL
        )
    }

    public func downloadWithProgress(_ request: FileDownloadRequest) async throws -> FileTransferOperation<DownloadTransferEvent> {
        try await sessionClient.downloadWithProgress(
            DownloadFileEndpoint(
                baseRequestSpec: request.requestSpec,
                retryPolicy: request.retryPolicy,
                cachePolicy: request.cachePolicy,
                backgroundTransfer: request.backgroundTransfer
            ),
            to: request.destinationURL,
            resumeIfPossible: request.resumeIfPossible
        )
    }
}

private struct UploadFileEndpoint<Response: APIResponseBody & Sendable>: AuthorizedUploadEndpoint {
    public let baseRequestSpec: HTTPRequestSpec
    public let uploadBody: UploadBody
    public let retryPolicy: RetryPolicy
    public let cachePolicy: RequestCachePolicy
    public let backgroundTransfer: BackgroundTransferConfiguration?
}

private struct DownloadFileEndpoint: AuthorizedDownloadEndpoint {
    public let baseRequestSpec: HTTPRequestSpec
    public let retryPolicy: RetryPolicy
    public let cachePolicy: RequestCachePolicy
    public let backgroundTransfer: BackgroundTransferConfiguration?
}
