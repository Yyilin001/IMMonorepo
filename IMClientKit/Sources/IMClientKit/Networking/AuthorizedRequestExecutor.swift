import Foundation

public struct AuthorizedRequestExecutor: Sendable {
    private let httpClient: HTTPClient
    private let fileTransferClient: FileTransferClient
    private let streamingClient: StreamingClient
    private let accessToken: @Sendable (Bool) async throws -> String

    init(
        httpClient: HTTPClient,
        fileTransferClient: FileTransferClient,
        streamingClient: StreamingClient,
        accessToken: @escaping @Sendable (Bool) async throws -> String
    ) {
        self.httpClient = httpClient
        self.fileTransferClient = fileTransferClient
        self.streamingClient = streamingClient
        self.accessToken = accessToken
    }

    public func execute<Request: Endpoint>(_ request: Request) async throws -> Request.Response {
        if request.requiresAuthorization {
            return try await executeAuthorized(retryPolicy: request.retryPolicy) { token in
                try await self.httpClient.execute(request, bearerToken: token)
            }
        }

        return try await httpClient.execute(request)
    }

    public func upload<Request: UploadEndpoint>(_ request: Request) async throws -> Request.Response {
        if request.requiresAuthorization {
            return try await executeAuthorized(retryPolicy: request.retryPolicy) { token in
                try await self.fileTransferClient.upload(request, bearerToken: token)
            }
        }

        return try await fileTransferClient.upload(request)
    }

    public func uploadWithProgress<Request: UploadEndpoint>(
        _ request: Request
    ) async throws -> FileTransferOperation<UploadTransferEvent<Request.Response>>
    where Request.Response: Sendable {
        if request.requiresAuthorization {
            return try await makeAuthorizedUploadWithProgressOperation(request)
        }

        return try await fileTransferClient.uploadWithProgress(request)
    }

    public func download<Request: DownloadEndpoint>(
        _ request: Request,
        to destinationURL: URL
    ) async throws -> URL {
        if request.requiresAuthorization {
            return try await executeAuthorized(retryPolicy: request.retryPolicy) { token in
                try await self.fileTransferClient.download(
                    request,
                    to: destinationURL,
                    bearerToken: token
                )
            }
        }

        return try await fileTransferClient.download(request, to: destinationURL)
    }

    public func downloadWithProgress<Request: DownloadEndpoint>(
        _ request: Request,
        to destinationURL: URL,
        resumeIfPossible: Bool = true
    ) async throws -> FileTransferOperation<DownloadTransferEvent> {
        if request.requiresAuthorization {
            return try await executeAuthorized(retryPolicy: request.retryPolicy) { token in
                try await self.fileTransferClient.downloadWithProgress(
                    request,
                    to: destinationURL,
                    resumeIfPossible: resumeIfPossible,
                    bearerToken: token
                )
            }
        }

        return try await fileTransferClient.downloadWithProgress(
            request,
            to: destinationURL,
            resumeIfPossible: resumeIfPossible
        )
    }

    public func openStream<Request: StreamingEndpoint>(_ request: Request) async throws -> StreamingConnection {
        if request.requiresAuthorization {
            return try await executeAuthorized(retryPolicy: request.retryPolicy) { token in
                try await self.streamingClient.openStream(request, bearerToken: token)
            }
        }

        return try await streamingClient.openStream(request)
    }

    private func executeAuthorized<Response>(
        retryPolicy: RetryPolicy,
        _ operation: @escaping @Sendable (String) async throws -> Response
    ) async throws -> Response {
        var bearerToken = try await accessToken(false)
        var remainingUnauthorizedRetries = retryPolicy.unauthorizedRefreshAttempts(requiresAuthorization: true)

        while true {
            do {
                return try await operation(bearerToken)
            } catch let error as APIError
                where error.isUnauthorized && remainingUnauthorizedRetries > 0 {
                remainingUnauthorizedRetries -= 1
                bearerToken = try await accessToken(true)
                continue
            } catch {
                throw error
            }
        }
    }

    private func makeAuthorizedUploadWithProgressOperation<Request: UploadEndpoint>(
        _ request: Request
    ) async throws -> FileTransferOperation<UploadTransferEvent<Request.Response>>
    where Request.Response: Sendable {
        let initialToken = try await accessToken(false)
        let activeOperation = ActiveFileTransferOperationBox<UploadTransferEvent<Request.Response>>()
        let cancellationController = FileTransferCancellationController()

        let events = AsyncThrowingStream { continuation in
            let producer = Task {
                var bearerToken = initialToken
                var remainingUnauthorizedRetries = request.retryPolicy.unauthorizedRefreshAttempts(requiresAuthorization: true)

                while !Task.isCancelled {
                    do {
                        let operation = try await self.fileTransferClient.uploadWithProgress(
                            request,
                            bearerToken: bearerToken
                        )
                        activeOperation.set(operation)

                        do {
                            for try await event in operation.events {
                                continuation.yield(event)
                            }

                            activeOperation.clear()
                            continuation.finish()
                            return
                        } catch let error as APIError
                            where error.isUnauthorized && remainingUnauthorizedRetries > 0 {
                            activeOperation.clear()
                            remainingUnauthorizedRetries -= 1
                            bearerToken = try await self.accessToken(true)
                            continue
                        } catch is CancellationError {
                            activeOperation.clear()
                            continuation.finish()
                            return
                        } catch {
                            activeOperation.clear()
                            continuation.finish(throwing: error)
                            return
                        }
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }

                continuation.finish()
            }

            cancellationController.install {
                activeOperation.cancel()
                producer.cancel()
                continuation.finish()
            }

            continuation.onTermination = { _ in
                activeOperation.cancel()
                producer.cancel()
            }
        }

        return FileTransferOperation(
            events: events,
            cancellationController: cancellationController
        )
    }
}

private final class ActiveFileTransferOperationBox<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: FileTransferOperation<Event>?

    public func set(_ operation: FileTransferOperation<Event>) {
        lock.lock()
        self.operation = operation
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        operation = nil
        lock.unlock()
    }

    public func cancel() {
        let operation: FileTransferOperation<Event>?
        lock.lock()
        operation = self.operation
        self.operation = nil
        lock.unlock()

        operation?.cancel()
    }
}
