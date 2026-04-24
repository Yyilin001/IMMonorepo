import Foundation

public struct FileTransferClient: Sendable {
    public let baseURL: URL
    public let logger: HTTPLogHandler
    public let coding: HTTPCodingConfiguration

    private let uploadData: @Sendable (URLRequest, Data) async throws -> (Data, HTTPURLResponse)
    private let uploadFile: @Sendable (URLRequest, URL) async throws -> (Data, HTTPURLResponse)
    private let uploadWithProgressData: @Sendable (URLRequest, Data) async -> AsyncThrowingStream<UploadTransportEvent, Error>
    private let uploadWithProgressFile: @Sendable (URLRequest, URL) async -> AsyncThrowingStream<UploadTransportEvent, Error>
    private let downloadRequest: @Sendable (URLRequest) async throws -> (URL, HTTPURLResponse)
    private let streamDownloadRequest: @Sendable (URLRequest) async throws -> (HTTPByteStream, HTTPURLResponse)
    private let backgroundUploadRequest: @Sendable (URLRequest, UploadBody, BackgroundTransferConfiguration) async throws -> (Data, HTTPURLResponse)
    private let backgroundDownloadRequest: @Sendable (URLRequest, URL, BackgroundTransferConfiguration) async throws -> (URL, HTTPURLResponse)

    public init(
        baseURL: URL,
        transport: URLSessionFileTransferTransport = URLSessionFileTransferTransport(),
        logger: HTTPLogHandler = .noop,
        coding: HTTPCodingConfiguration = .default
    ) {
        self.init(
            baseURL: baseURL,
            uploadData: { request, data in
                try await transport.upload(request, from: data)
            },
            uploadFile: { request, fileURL in
                try await transport.upload(request, fromFile: fileURL)
            },
            uploadWithProgressData: { request, data in
                await transport.uploadWithProgress(request, from: data)
            },
            uploadWithProgressFile: { request, fileURL in
                await transport.uploadWithProgress(request, fromFile: fileURL)
            },
            downloadRequest: { request in
                try await transport.download(request)
            },
            streamDownloadRequest: { request in
                try await transport.streamDownload(request)
            },
            backgroundUploadRequest: { request, uploadBody, configuration in
                try await BackgroundTransferCoordinator.shared.upload(
                    request: request,
                    uploadBody: uploadBody,
                    configuration: configuration
                )
            },
            backgroundDownloadRequest: { request, destinationURL, configuration in
                try await BackgroundTransferCoordinator.shared.download(
                    request: request,
                    destinationURL: destinationURL,
                    configuration: configuration
                )
            },
            logger: logger,
            coding: coding
        )
    }

    public init(environment: NetworkEnvironment) {
        self.init(
            baseURL: environment.baseURL,
            transport: URLSessionFileTransferTransport(session: environment.session),
            logger: environment.logger,
            coding: environment.coding
        )
    }

    init<Transport: FileTransferTransport>(
        baseURL: URL,
        transport: Transport,
        backgroundUploadRequest: @escaping @Sendable (URLRequest, UploadBody, BackgroundTransferConfiguration) async throws -> (Data, HTTPURLResponse) = { request, uploadBody, configuration in
            try await BackgroundTransferCoordinator.shared.upload(
                request: request,
                uploadBody: uploadBody,
                configuration: configuration
            )
        },
        backgroundDownloadRequest: @escaping @Sendable (URLRequest, URL, BackgroundTransferConfiguration) async throws -> (URL, HTTPURLResponse) = { request, destinationURL, configuration in
            try await BackgroundTransferCoordinator.shared.download(
                request: request,
                destinationURL: destinationURL,
                configuration: configuration
            )
        },
        logger: HTTPLogHandler = .noop,
        coding: HTTPCodingConfiguration = .default
    ) {
        self.init(
            baseURL: baseURL,
            uploadData: { request, data in
                try await transport.upload(request, from: data)
            },
            uploadFile: { request, fileURL in
                try await transport.upload(request, fromFile: fileURL)
            },
            uploadWithProgressData: { request, data in
                await transport.uploadWithProgress(request, from: data)
            },
            uploadWithProgressFile: { request, fileURL in
                await transport.uploadWithProgress(request, fromFile: fileURL)
            },
            downloadRequest: { request in
                try await transport.download(request)
            },
            streamDownloadRequest: { request in
                try await transport.streamDownload(request)
            },
            backgroundUploadRequest: backgroundUploadRequest,
            backgroundDownloadRequest: backgroundDownloadRequest,
            logger: logger,
            coding: coding
        )
    }

    init<Transport: FileTransferTransport, Logger: HTTPClientLogger>(
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
        uploadData: @escaping @Sendable (URLRequest, Data) async throws -> (Data, HTTPURLResponse),
        uploadFile: @escaping @Sendable (URLRequest, URL) async throws -> (Data, HTTPURLResponse),
        uploadWithProgressData: @escaping @Sendable (URLRequest, Data) async -> AsyncThrowingStream<UploadTransportEvent, Error>,
        uploadWithProgressFile: @escaping @Sendable (URLRequest, URL) async -> AsyncThrowingStream<UploadTransportEvent, Error>,
        downloadRequest: @escaping @Sendable (URLRequest) async throws -> (URL, HTTPURLResponse),
        streamDownloadRequest: @escaping @Sendable (URLRequest) async throws -> (HTTPByteStream, HTTPURLResponse),
        backgroundUploadRequest: @escaping @Sendable (URLRequest, UploadBody, BackgroundTransferConfiguration) async throws -> (Data, HTTPURLResponse),
        backgroundDownloadRequest: @escaping @Sendable (URLRequest, URL, BackgroundTransferConfiguration) async throws -> (URL, HTTPURLResponse),
        logger: HTTPLogHandler,
        coding: HTTPCodingConfiguration
    ) {
        self.baseURL = baseURL
        self.uploadData = uploadData
        self.uploadFile = uploadFile
        self.uploadWithProgressData = uploadWithProgressData
        self.uploadWithProgressFile = uploadWithProgressFile
        self.downloadRequest = downloadRequest
        self.streamDownloadRequest = streamDownloadRequest
        self.backgroundUploadRequest = backgroundUploadRequest
        self.backgroundDownloadRequest = backgroundDownloadRequest
        self.logger = logger
        self.coding = coding
    }

    public func upload<Request: UploadEndpoint>(
        _ request: Request,
        bearerToken: String? = nil
    ) async throws -> Request.Response {
        if request.requiresAuthorization, bearerToken == nil {
            throw APIError.unauthorized("缺少访问令牌，请重新登录。")
        }

        let urlRequest = try buildUploadRequest(
            for: request,
            contentType: request.uploadBody.contentTypeHeader,
            bearerToken: bearerToken
        )
        logger.logRequest(urlRequest)

        let data: Data
        let response: HTTPURLResponse

        do {
            if let backgroundTransfer = request.backgroundTransfer {
                (data, response) = try await backgroundUploadRequest(
                    urlRequest,
                    request.uploadBody,
                    backgroundTransfer
                )
            } else {
                switch request.uploadBody {
                case .file(let fileURL, _):
                    (data, response) = try await uploadFile(urlRequest, fileURL)
                default:
                    let body = try request.uploadBody.inMemoryData() ?? Data()
                    (data, response) = try await uploadData(urlRequest, body)
                }
            }
        } catch {
            throw HTTPResponseProcessor.mapTransportError(error, logger: logger, request: urlRequest)
        }

        logger.logResponse(response, data, urlRequest)
        try HTTPResponseProcessor.validate(response: response, data: data, coding: coding)
        return try HTTPResponseProcessor.decode(Request.Response.self, from: data, coding: coding)
    }

    public func uploadWithProgress<Request: UploadEndpoint>(
        _ request: Request,
        bearerToken: String? = nil
    ) async throws -> FileTransferOperation<UploadTransferEvent<Request.Response>>
    where Request.Response: Sendable {
        if request.requiresAuthorization, bearerToken == nil {
            throw APIError.unauthorized("缺少访问令牌，请重新登录。")
        }
        if request.backgroundTransfer != nil {
            throw APIError.unsupported(
                "后台上传不支持进度流接口，请改用 upload(_:)"
            )
        }

        let urlRequest = try buildUploadRequest(
            for: request,
            contentType: request.uploadBody.contentTypeHeader,
            bearerToken: bearerToken
        )
        logger.logRequest(urlRequest)

        let transportStream: AsyncThrowingStream<UploadTransportEvent, Error>
        switch request.uploadBody {
        case .file(let fileURL, _):
            transportStream = await uploadWithProgressFile(urlRequest, fileURL)
        default:
            let body = try request.uploadBody.inMemoryData() ?? Data()
            transportStream = await uploadWithProgressData(urlRequest, body)
        }

        let cancellationController = FileTransferCancellationController()

        let events = AsyncThrowingStream { continuation in
            let producer = Task.detached(priority: .utility) {
                do {
                    for try await event in transportStream {
                        switch event {
                        case .progress(let transferredBytes, let totalBytes):
                            continuation.yield(
                                UploadTransferEvent<Request.Response>.progress(
                                    FileTransferProgress(
                                        transferredBytes: transferredBytes,
                                        totalBytes: totalBytes,
                                        resumedBytes: 0
                                    )
                                )
                            )
                        case .completed(let data, let response):
                            self.logger.logResponse(response, data, urlRequest)
                            try HTTPResponseProcessor.validate(response: response, data: data, coding: self.coding)
                            let decoded = try HTTPResponseProcessor.decode(Request.Response.self, from: data, coding: self.coding)
                            continuation.yield(.completed(decoded))
                            continuation.finish()
                        }
                    }
                } catch {
                    let mappedError = HTTPResponseProcessor.mapTransportError(error, logger: self.logger, request: urlRequest)
                    continuation.finish(throwing: mappedError)
                }
            }

            cancellationController.install {
                producer.cancel()
                continuation.finish()
            }

            continuation.onTermination = { _ in
                producer.cancel()
            }
        }

        return FileTransferOperation(
            events: events,
            cancellationController: cancellationController
        )
    }

    public func download<Request: DownloadEndpoint>(
        _ request: Request,
        to destinationURL: URL,
        bearerToken: String? = nil
    ) async throws -> URL {
        if request.requiresAuthorization, bearerToken == nil {
            throw APIError.unauthorized("缺少访问令牌，请重新登录。")
        }

        let urlRequest = try buildDownloadRequest(for: request, bearerToken: bearerToken)
        logger.logRequest(urlRequest)

        let temporaryURL: URL
        let response: HTTPURLResponse

        do {
            if let backgroundTransfer = request.backgroundTransfer {
                (temporaryURL, response) = try await backgroundDownloadRequest(
                    urlRequest,
                    destinationURL,
                    backgroundTransfer
                )
            } else {
                (temporaryURL, response) = try await downloadRequest(urlRequest)
            }
        } catch {
            throw HTTPResponseProcessor.mapTransportError(error, logger: logger, request: urlRequest)
        }

        if 200..<300 ~= response.statusCode {
            logger.logResponse(response, Data("<downloaded>".utf8), urlRequest)
            let finalURL: URL
            if request.backgroundTransfer != nil {
                finalURL = temporaryURL
            } else {
                finalURL = try moveDownloadedFile(from: temporaryURL, to: destinationURL)
            }
            removeDownloadMetadata(for: destinationURL)
            return finalURL
        }

        let errorData = (try? Data(contentsOf: temporaryURL)) ?? Data()
        logger.logResponse(response, errorData, urlRequest)
        try HTTPResponseProcessor.validate(response: response, data: errorData, coding: coding)
        return destinationURL
    }

    public func downloadWithProgress<Request: DownloadEndpoint>(
        _ request: Request,
        to destinationURL: URL,
        resumeIfPossible: Bool = true,
        bearerToken: String? = nil
    ) async throws -> FileTransferOperation<DownloadTransferEvent> {
        if request.requiresAuthorization, bearerToken == nil {
            throw APIError.unauthorized("缺少访问令牌，请重新登录。")
        }
        if request.backgroundTransfer != nil {
            throw APIError.unsupported(
                "后台下载不支持进度流接口，请改用 download(_:to:)"
            )
        }

        let resumeContext = loadResumeContext(
            at: destinationURL,
            resumeIfPossible: resumeIfPossible
        )
        let urlRequest = try buildDownloadRequest(
            for: request,
            bearerToken: bearerToken,
            resumeContext: resumeContext
        )
        logger.logRequest(urlRequest)

        let byteStream: HTTPByteStream
        let response: HTTPURLResponse

        do {
            (byteStream, response) = try await streamDownloadRequest(urlRequest)
        } catch {
            throw HTTPResponseProcessor.mapTransportError(error, logger: logger, request: urlRequest)
        }

        if !(200..<300 ~= response.statusCode) {
            let errorData = try await byteStream.collectData(maxBytes: 64 * 1024)
            logger.logResponse(response, errorData, urlRequest)
            try HTTPResponseProcessor.validate(response: response, data: errorData, coding: coding)
        }

        let strategy = resolveResumeStrategy(
            response: response,
            destinationURL: destinationURL,
            resumeContext: resumeContext
        )
        let persistedMetadata = DownloadResumeMetadata.from(response: response)
            ?? (strategy.shouldAppend ? resumeContext.metadata : nil)
        if let persistedMetadata {
            try? writeDownloadMetadata(persistedMetadata, for: destinationURL)
        } else {
            removeDownloadMetadata(for: destinationURL)
        }
        let totalBytes = expectedTotalBytes(response: response, resumedBytes: strategy.resumedBytes)
        logger.logResponse(response, Data("<download-started>".utf8), urlRequest)

        let cancellationController = FileTransferCancellationController()

        let events = AsyncThrowingStream { continuation in
            let producer = Task.detached(priority: .utility) {
                do {
                    let fileHandle = try self.prepareDownloadFileHandle(
                        at: destinationURL,
                        append: strategy.shouldAppend
                    )
                    defer { try? fileHandle.close() }

                    var buffer = Data()
                    var transferredBytes = strategy.resumedBytes
                    let writeChunkSize = 32 * 1024

                    if strategy.resumedBytes > 0 {
                        continuation.yield(
                            DownloadTransferEvent.progress(
                                FileTransferProgress(
                                    transferredBytes: transferredBytes,
                                    totalBytes: totalBytes,
                                    resumedBytes: strategy.resumedBytes
                                )
                            )
                        )
                    }

                    for try await byte in byteStream.bytes {
                        buffer.append(byte)
                        if buffer.count >= writeChunkSize {
                            try Task.checkCancellation()
                            try fileHandle.write(contentsOf: buffer)
                            transferredBytes += Int64(buffer.count)
                            continuation.yield(
                                .progress(
                                    FileTransferProgress(
                                        transferredBytes: transferredBytes,
                                        totalBytes: totalBytes,
                                        resumedBytes: strategy.resumedBytes
                                    )
                                )
                            )
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }

                    try Task.checkCancellation()
                    if !buffer.isEmpty {
                        try fileHandle.write(contentsOf: buffer)
                        transferredBytes += Int64(buffer.count)
                        continuation.yield(
                            .progress(
                                FileTransferProgress(
                                    transferredBytes: transferredBytes,
                                    totalBytes: totalBytes,
                                    resumedBytes: strategy.resumedBytes
                                )
                            )
                        )
                    }

                    try Task.checkCancellation()
                    self.removeDownloadMetadata(for: destinationURL)
                    continuation.yield(.completed(destinationURL))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            cancellationController.install {
                producer.cancel()
                continuation.finish()
            }

            continuation.onTermination = { _ in
                producer.cancel()
            }
        }

        return FileTransferOperation(
            events: events,
            cancellationController: cancellationController
        )
    }

    private func buildUploadRequest<Request: UploadEndpoint>(
        for request: Request,
        contentType: String,
        bearerToken: String?
    ) throws -> URLRequest {
        let timeout = request.timeout ?? (request.transportKind.isBackgroundTransfer ? 15 * 60 : 60)
        return try HTTPRequestBuilder.build(
            spec: HTTPRequestSpec(
                path: request.path,
                method: request.method,
                headers: request.headers,
                queryItems: request.queryItems,
                timeout: timeout,
                requiresAuthorization: request.requiresAuthorization
            ),
            baseURL: baseURL,
            bearerToken: bearerToken,
            cachePolicy: request.cachePolicy,
            accept: "application/json",
            contentType: contentType
        )
    }

    private func buildDownloadRequest<Request: DownloadEndpoint>(
        for request: Request,
        bearerToken: String?,
        resumeContext: DownloadResumeContext = .empty
    ) throws -> URLRequest {
        var headers = request.headers
        let body = try request.makeBody(using: coding.makeEncoder())
        if resumeContext.offset > 0, let metadata = resumeContext.metadata {
            headers["Range"] = "bytes=\(resumeContext.offset)-"
            headers["If-Range"] = metadata.ifRangeHeaderValue
        }

        let timeout = request.timeout ?? (request.transportKind.isBackgroundTransfer ? 15 * 60 : 120)
        return try HTTPRequestBuilder.build(
            spec: HTTPRequestSpec(
                path: request.path,
                method: request.method,
                headers: headers,
                queryItems: request.queryItems,
                timeout: timeout,
                requiresAuthorization: request.requiresAuthorization
            ),
            baseURL: baseURL,
            bearerToken: bearerToken,
            cachePolicy: request.cachePolicy,
            contentType: request.requestContentType ?? (body == nil ? nil : "application/json"),
            body: body
        )
    }

    private func currentFileSize(at url: URL) -> Int64 {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private func resolveResumeStrategy(
        response: HTTPURLResponse,
        destinationURL: URL,
        resumeContext: DownloadResumeContext
    ) -> (shouldAppend: Bool, resumedBytes: Int64) {
        if resumeContext.offset > 0, response.statusCode == 206 {
            return (true, resumeContext.offset)
        }

        if resumeContext.offset > 0 {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        return (false, 0)
    }

    private func loadResumeContext(
        at destinationURL: URL,
        resumeIfPossible: Bool
    ) -> DownloadResumeContext {
        guard resumeIfPossible else {
            return .empty
        }

        let offset = currentFileSize(at: destinationURL)
        guard offset > 0, let metadata = readDownloadMetadata(for: destinationURL) else {
            return .empty
        }

        return DownloadResumeContext(
            offset: offset,
            metadata: metadata
        )
    }

    private func expectedTotalBytes(response: HTTPURLResponse, resumedBytes: Int64) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let slashIndex = contentRange.lastIndex(of: "/")
        {
            let totalString = contentRange[contentRange.index(after: slashIndex)...]
            if totalString != "*", let total = Int64(totalString) {
                return total
            }
        }

        if let contentLength = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) {
            return resumedBytes + contentLength
        }

        return nil
    }

    private func prepareDownloadFileHandle(at url: URL, append: Bool) throws -> FileHandle {
        let fileManager = FileManager.default
        let directoryURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if !append {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            fileManager.createFile(atPath: url.path, contents: nil)
        } else if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        let fileHandle = try FileHandle(forWritingTo: url)
        if append {
            try fileHandle.seekToEnd()
        } else {
            try fileHandle.truncate(atOffset: 0)
        }
        return fileHandle
    }

    private func readDownloadMetadata(for destinationURL: URL) -> DownloadResumeMetadata? {
        let metadataURL = downloadMetadataURL(for: destinationURL)
        guard let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }
        return try? JSONDecoder().decode(DownloadResumeMetadata.self, from: data)
    }

    private func writeDownloadMetadata(
        _ metadata: DownloadResumeMetadata,
        for destinationURL: URL
    ) throws {
        let metadataURL = downloadMetadataURL(for: destinationURL)
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func removeDownloadMetadata(for destinationURL: URL) {
        try? FileManager.default.removeItem(at: downloadMetadataURL(for: destinationURL))
    }

    private func downloadMetadataURL(for destinationURL: URL) -> URL {
        destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).resume-metadata")
    }

    private func moveDownloadedFile(from temporaryURL: URL, to destinationURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }
}

private struct DownloadResumeContext: Sendable {
    public static let empty = DownloadResumeContext(
        offset: 0,
        metadata: nil
    )

    public let offset: Int64
    public let metadata: DownloadResumeMetadata?
}

private struct DownloadResumeMetadata: Codable, Sendable {
    private enum ValidatorKind: String, Codable {
        case entityTag
        case lastModified
    }

    private let validatorKind: ValidatorKind
    private let validatorValue: String

    public var ifRangeHeaderValue: String {
        validatorValue
    }

    public static func from(response: HTTPURLResponse) -> DownloadResumeMetadata? {
        if let entityTag = response.value(forHTTPHeaderField: "ETag"),
           !entityTag.isEmpty
        {
            return DownloadResumeMetadata(
                validatorKind: .entityTag,
                validatorValue: entityTag
            )
        }

        if let lastModified = response.value(forHTTPHeaderField: "Last-Modified"),
           !lastModified.isEmpty
        {
            return DownloadResumeMetadata(
                validatorKind: .lastModified,
                validatorValue: lastModified
            )
        }

        return nil
    }
}
