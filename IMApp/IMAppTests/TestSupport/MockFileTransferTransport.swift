import Foundation
@testable import IMApp
@testable import IMClientKit

actor MockFileTransferTransport: FileTransferTransport {
    enum RecordedOperation: Equatable {
        case uploadData
        case uploadFile(URL)
        case uploadDataWithProgress
        case uploadFileWithProgress(URL)
        case download
        case streamDownload
    }

    typealias UploadDataHandler = @Sendable (URLRequest, Data) async throws -> (Data, HTTPURLResponse)
    typealias UploadFileHandler = @Sendable (URLRequest, URL) async throws -> (Data, HTTPURLResponse)
    typealias UploadDataProgressHandler = @Sendable (URLRequest, Data) -> AsyncThrowingStream<UploadTransportEvent, Error>
    typealias UploadFileProgressHandler = @Sendable (URLRequest, URL) -> AsyncThrowingStream<UploadTransportEvent, Error>
    typealias DownloadHandler = @Sendable (URLRequest) async throws -> (URL, HTTPURLResponse)
    typealias StreamDownloadHandler = @Sendable (URLRequest) async throws -> (HTTPByteStream, HTTPURLResponse)

    private let uploadDataHandler: UploadDataHandler
    private let uploadFileHandler: UploadFileHandler
    private let uploadDataProgressHandler: UploadDataProgressHandler
    private let uploadFileProgressHandler: UploadFileProgressHandler
    private let downloadHandler: DownloadHandler
    private let streamDownloadHandler: StreamDownloadHandler
    private var recordedRequests: [URLRequest] = []
    private var operations: [RecordedOperation] = []

    init(
        uploadDataHandler: @escaping UploadDataHandler = { _, _ in HTTPFixtures.response(statusCode: 200) },
        uploadFileHandler: @escaping UploadFileHandler = { _, _ in HTTPFixtures.response(statusCode: 200) },
        uploadDataProgressHandler: @escaping UploadDataProgressHandler = { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.progress(transferredBytes: 0, totalBytes: 0))
                let (data, response) = HTTPFixtures.response(statusCode: 200)
                continuation.yield(.completed(data, response))
                continuation.finish()
            }
        },
        uploadFileProgressHandler: @escaping UploadFileProgressHandler = { _, fileURL in
            let totalBytes = (try? Data(contentsOf: fileURL).count).map(Int64.init)
            return AsyncThrowingStream { continuation in
                continuation.yield(.progress(transferredBytes: totalBytes ?? 0, totalBytes: totalBytes))
                let (data, response) = HTTPFixtures.response(statusCode: 200)
                continuation.yield(.completed(data, response))
                continuation.finish()
            }
        },
        downloadHandler: @escaping DownloadHandler = { _ in
            let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data().write(to: url)
            return (
                url,
                HTTPURLResponse(
                    url: HTTPFixtures.baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        },
        streamDownloadHandler: @escaping StreamDownloadHandler = { _ in
            (
                HTTPByteStream(
                    bytes: AsyncThrowingStream { continuation in
                        continuation.finish()
                    }
                ),
                HTTPURLResponse(
                    url: HTTPFixtures.baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
    ) {
        self.uploadDataHandler = uploadDataHandler
        self.uploadFileHandler = uploadFileHandler
        self.uploadDataProgressHandler = uploadDataProgressHandler
        self.uploadFileProgressHandler = uploadFileProgressHandler
        self.downloadHandler = downloadHandler
        self.streamDownloadHandler = streamDownloadHandler
    }

    func upload(_ request: URLRequest, from data: Data) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        operations.append(.uploadData)
        return try await uploadDataHandler(request, data)
    }

    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        operations.append(.uploadFile(fileURL))
        return try await uploadFileHandler(request, fileURL)
    }

    func uploadWithProgress(_ request: URLRequest, from data: Data) async -> AsyncThrowingStream<UploadTransportEvent, Error> {
        recordedRequests.append(request)
        operations.append(.uploadDataWithProgress)
        return uploadDataProgressHandler(request, data)
    }

    func uploadWithProgress(_ request: URLRequest, fromFile fileURL: URL) async -> AsyncThrowingStream<UploadTransportEvent, Error> {
        recordedRequests.append(request)
        operations.append(.uploadFileWithProgress(fileURL))
        return uploadFileProgressHandler(request, fileURL)
    }

    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        recordedRequests.append(request)
        operations.append(.download)
        return try await downloadHandler(request)
    }

    func streamDownload(_ request: URLRequest) async throws -> (HTTPByteStream, HTTPURLResponse) {
        recordedRequests.append(request)
        operations.append(.streamDownload)
        return try await streamDownloadHandler(request)
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }

    func recordedOperations() -> [RecordedOperation] {
        operations
    }
}
