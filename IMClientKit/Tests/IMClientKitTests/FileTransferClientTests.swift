import Foundation
import Testing
@testable import IMClientKit

private struct UploadResult: Codable, Equatable, Sendable, APIResponseBody {
    let message: String
}

private struct AuthorizedFileUploadEndpoint: AuthorizedUploadEndpoint {
    typealias Response = UploadResult

    let baseRequestSpec = HTTPRequestSpec(path: "upload", method: .post)
    let uploadBody: UploadBody
}

private struct BackgroundAuthorizedFileUploadEndpoint: AuthorizedUploadEndpoint {
    typealias Response = UploadResult

    let baseRequestSpec = HTTPRequestSpec(path: "upload", method: .post)
    let uploadBody: UploadBody
    let backgroundTransfer: BackgroundTransferConfiguration? = BackgroundTransferConfiguration(
        identifier: "tests.background.upload",
        isDiscretionary: false,
        waitsForConnectivity: false
    )
}

private struct AuthorizedDownloadEndpointForTests: AuthorizedDownloadEndpoint {
    let baseRequestSpec = HTTPRequestSpec(path: "download")
}

private struct BackgroundAuthorizedDownloadEndpointForTests: AuthorizedDownloadEndpoint {
    let baseRequestSpec = HTTPRequestSpec(path: "download")
    let backgroundTransfer: BackgroundTransferConfiguration? = BackgroundTransferConfiguration(
        identifier: "tests.background.download",
        isDiscretionary: false,
        waitsForConnectivity: false
    )
}

private actor DownloadAttemptCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private func makeByteStream(
    chunks: [Data],
    suspendAfterChunks: Bool = false
) -> HTTPByteStream {
    HTTPByteStream(
        bytes: AsyncThrowingStream { continuation in
            let producer = Task.detached {
                for chunk in chunks {
                    for byte in chunk {
                        continuation.yield(byte)
                    }
                }

                if suspendAfterChunks {
                    try? await Task.sleep(for: .seconds(10))
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    )
}

struct FileTransferClientTests {
    @Test func backgroundUploadUsesDedicatedBackgroundRunner() async throws {
        let tempFileURL = FileManager.default.temporaryDirectory.appending(path: "background-upload-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: tempFileURL)
        defer { try? FileManager.default.removeItem(at: tempFileURL) }

        let transport = MockFileTransferTransport()
        let client = FileTransferClient(
            baseURL: HTTPFixtures.baseURL,
            transport: transport,
            backgroundUploadRequest: { request, uploadBody, configuration in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                #expect(configuration.identifier == "tests.background.upload")
                if case .file(let fileURL, let contentType) = uploadBody {
                    #expect(fileURL == tempFileURL)
                    #expect(contentType == "text/plain")
                } else {
                    Issue.record("预期使用文件上传。")
                }
                let body = try HTTPFixtures.jsonBody(UploadResult(message: "background-ok"))
                return HTTPFixtures.response(statusCode: 200, body: body)
            }
        )

        let response = try await client.upload(
            BackgroundAuthorizedFileUploadEndpoint(
                uploadBody: .file(tempFileURL, contentType: "text/plain")
            ),
            bearerToken: "test-token"
        )

        #expect(response == UploadResult(message: "background-ok"))
        #expect(await transport.recordedOperations().isEmpty)
    }

    @Test func backgroundDownloadUsesDedicatedBackgroundRunner() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory.appending(path: "background-source-\(UUID().uuidString).txt")
        let destinationURL = FileManager.default.temporaryDirectory.appending(path: "background-dest-\(UUID().uuidString).txt")
        try Data("downloaded".utf8).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let transport = MockFileTransferTransport()
        let client = FileTransferClient(
            baseURL: HTTPFixtures.baseURL,
            transport: transport,
            backgroundDownloadRequest: { request, destination, configuration in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                #expect(configuration.identifier == "tests.background.download")
                #expect(destination == destinationURL)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                return (
                    destination,
                    HTTPURLResponse(
                        url: HTTPFixtures.baseURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )

        let finalURL = try await client.download(
            BackgroundAuthorizedDownloadEndpointForTests(),
            to: destinationURL,
            bearerToken: "test-token"
        )

        #expect(finalURL == destinationURL)
        #expect(try Data(contentsOf: destinationURL) == Data("downloaded".utf8))
        #expect(await transport.recordedOperations().isEmpty)
    }

    @Test func fileUploadUsesFileBackedTransport() async throws {
        let tempFileURL = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: tempFileURL)
        defer { try? FileManager.default.removeItem(at: tempFileURL) }

        let transport = MockFileTransferTransport(
            uploadFileHandler: { request, fileURL in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                #expect(fileURL == tempFileURL)
                let body = try HTTPFixtures.jsonBody(UploadResult(message: "ok"))
                return HTTPFixtures.response(statusCode: 200, body: body)
            }
        )

        let client = FileTransferClient(
            baseURL: HTTPFixtures.baseURL,
            transport: transport
        )

        let response = try await client.upload(
            AuthorizedFileUploadEndpoint(uploadBody: .file(tempFileURL, contentType: "text/plain")),
            bearerToken: "test-token"
        )

        #expect(response == UploadResult(message: "ok"))
        let operations = await transport.recordedOperations()
        #expect(operations == [.uploadFile(tempFileURL)])
    }

    @Test func downloadWithProgressResumesUsingRangeHeader() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appending(path: "resume-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        defer {
            let metadataURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).resume-metadata")
            try? FileManager.default.removeItem(at: metadataURL)
        }

        let prefix = Data(repeating: UInt8(ascii: "a"), count: 32 * 1024)
        let suffix = Data("world".utf8)
        let attempts = DownloadAttemptCounter()

        let transport = MockFileTransferTransport(
            streamDownloadHandler: { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

                switch await attempts.next() {
                case 1:
                    #expect(request.value(forHTTPHeaderField: "Range") == nil)
                    #expect(request.value(forHTTPHeaderField: "If-Range") == nil)
                    let response = HTTPURLResponse(
                        url: HTTPFixtures.baseURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "ETag": "\"demo-v1\"",
                            "Content-Length": "\(prefix.count * 2)"
                        ]
                    )!
                    return (
                        makeByteStream(
                            chunks: [prefix],
                            suspendAfterChunks: true
                        ),
                        response
                    )
                case 2:
                    #expect(request.value(forHTTPHeaderField: "Range") == "bytes=\(prefix.count)-")
                    #expect(request.value(forHTTPHeaderField: "If-Range") == "\"demo-v1\"")
                    let response = HTTPURLResponse(
                        url: HTTPFixtures.baseURL,
                        statusCode: 206,
                        httpVersion: nil,
                        headerFields: [
                            "ETag": "\"demo-v1\"",
                            "Content-Range": "bytes \(prefix.count)-\(prefix.count + suffix.count - 1)/\(prefix.count + suffix.count)",
                            "Content-Length": "\(suffix.count)"
                        ]
                    )!
                    return (makeByteStream(chunks: [suffix]), response)
                default:
                    Issue.record("收到未预期的 streamDownload 请求。")
                    let response = HTTPURLResponse(
                        url: HTTPFixtures.baseURL,
                        statusCode: 500,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return (makeByteStream(chunks: []), response)
                }
            }
        )

        let client = FileTransferClient(baseURL: HTTPFixtures.baseURL, transport: transport)

        let initialOperation = try await client.downloadWithProgress(
            AuthorizedDownloadEndpointForTests(),
            to: destinationURL,
            bearerToken: "test-token"
        )

        var initialIterator = initialOperation.events.makeAsyncIterator()
        let firstEvent = try await initialIterator.next()
        guard case .progress(let initialProgress)? = firstEvent else {
            Issue.record("预期第一次下载先落一段可续传数据。")
            return
        }
        #expect(initialProgress.transferredBytes == Int64(prefix.count))

        initialOperation.cancel()
        _ = try await initialIterator.next()

        let operation = try await client.downloadWithProgress(
            AuthorizedDownloadEndpointForTests(),
            to: destinationURL,
            bearerToken: "test-token"
        )

        var progressEvents: [FileTransferProgress] = []
        var completedURL: URL?
        for try await event in operation.events {
            switch event {
            case .progress(let progress):
                progressEvents.append(progress)
            case .completed(let url):
                completedURL = url
            }
        }

        #expect(completedURL == destinationURL)
        var expectedData = prefix
        expectedData.append(suffix)
        #expect(try Data(contentsOf: destinationURL) == expectedData)
        #expect(progressEvents.first?.resumedBytes == Int64(prefix.count))
        #expect(progressEvents.last?.transferredBytes == Int64(prefix.count + suffix.count))
        #expect(progressEvents.last?.totalBytes == Int64(prefix.count + suffix.count))

        let operations = await transport.recordedOperations()
        #expect(operations == [.streamDownload, .streamDownload])
    }

    @Test func downloadWithProgressRestartsFromScratchWhenIfRangeValidationFails() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appending(path: "resume-reset-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        defer {
            let metadataURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).resume-metadata")
            try? FileManager.default.removeItem(at: metadataURL)
        }

        let prefix = Data(repeating: UInt8(ascii: "b"), count: 32 * 1024)
        let replacement = Data("fresh".utf8)
        let attempts = DownloadAttemptCounter()

        let transport = MockFileTransferTransport(
            streamDownloadHandler: { request in
                switch await attempts.next() {
                case 1:
                    let response = HTTPURLResponse(
                        url: HTTPFixtures.baseURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "ETag": "\"demo-v1\"",
                            "Content-Length": "\(prefix.count * 2)"
                        ]
                    )!
                    return (
                        makeByteStream(
                            chunks: [prefix],
                            suspendAfterChunks: true
                        ),
                        response
                    )
                case 2:
                    #expect(request.value(forHTTPHeaderField: "Range") == "bytes=\(prefix.count)-")
                    #expect(request.value(forHTTPHeaderField: "If-Range") == "\"demo-v1\"")
                    let response = HTTPURLResponse(
                        url: HTTPFixtures.baseURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "ETag": "\"demo-v2\"",
                            "Content-Length": "\(replacement.count)"
                        ]
                    )!
                    return (makeByteStream(chunks: [replacement]), response)
                default:
                    Issue.record("收到未预期的 streamDownload 请求。")
                    let response = HTTPURLResponse(
                        url: HTTPFixtures.baseURL,
                        statusCode: 500,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return (makeByteStream(chunks: []), response)
                }
            }
        )

        let client = FileTransferClient(baseURL: HTTPFixtures.baseURL, transport: transport)
        let initialOperation = try await client.downloadWithProgress(
            AuthorizedDownloadEndpointForTests(),
            to: destinationURL,
            bearerToken: "test-token"
        )

        var initialIterator = initialOperation.events.makeAsyncIterator()
        _ = try await initialIterator.next()
        initialOperation.cancel()
        _ = try await initialIterator.next()

        let operation = try await client.downloadWithProgress(
            AuthorizedDownloadEndpointForTests(),
            to: destinationURL,
            bearerToken: "test-token"
        )

        var completedURL: URL?
        for try await event in operation.events {
            if case .completed(let url) = event {
                completedURL = url
            }
        }

        #expect(completedURL == destinationURL)
        #expect(try Data(contentsOf: destinationURL) == replacement)
    }

    @Test func uploadWithProgressEmitsProgressAndCompletion() async throws {
        let tempFileURL = FileManager.default.temporaryDirectory.appending(path: "upload-progress-\(UUID().uuidString).txt")
        try Data("progress".utf8).write(to: tempFileURL)
        defer { try? FileManager.default.removeItem(at: tempFileURL) }
        let body = try HTTPFixtures.jsonBody(UploadResult(message: "uploaded"))
        let (_, response) = HTTPFixtures.response(statusCode: 200, body: body)

        let transport = MockFileTransferTransport(
            uploadFileProgressHandler: { request, fileURL in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                #expect(fileURL == tempFileURL)
                let totalBytes = Int64((try? Data(contentsOf: fileURL).count) ?? 8)
                return AsyncThrowingStream { continuation in
                    continuation.yield(.progress(transferredBytes: totalBytes / 2, totalBytes: totalBytes))
                    continuation.yield(.progress(transferredBytes: totalBytes, totalBytes: totalBytes))
                    continuation.yield(.completed(body, response))
                    continuation.finish()
                }
            }
        )

        let client = FileTransferClient(baseURL: HTTPFixtures.baseURL, transport: transport)
        let operation = try await client.uploadWithProgress(
            AuthorizedFileUploadEndpoint(uploadBody: .file(tempFileURL, contentType: "text/plain")),
            bearerToken: "test-token"
        )

        var progressEvents: [FileTransferProgress] = []
        var completed: UploadResult?
        for try await event in operation.events {
            switch event {
            case .progress(let progress):
                progressEvents.append(progress)
            case .completed(let response):
                completed = response
            }
        }

        #expect(completed == UploadResult(message: "uploaded"))
        #expect(progressEvents.count == 2)
        #expect(progressEvents.last?.fractionCompleted == 1)

        let operations = await transport.recordedOperations()
        #expect(operations == [.uploadFileWithProgress(tempFileURL)])
    }

    @Test func uploadWithProgressCanBeCancelled() async throws {
        let tempFileURL = FileManager.default.temporaryDirectory.appending(path: "upload-cancel-\(UUID().uuidString).txt")
        try Data("cancel".utf8).write(to: tempFileURL)
        defer { try? FileManager.default.removeItem(at: tempFileURL) }

        let transport = MockFileTransferTransport(
            uploadFileProgressHandler: { _, _ in
                AsyncThrowingStream { continuation in
                    let producer = Task.detached {
                        continuation.yield(.progress(transferredBytes: 3, totalBytes: 6))
                        try? await Task.sleep(for: .seconds(10))
                        continuation.yield(.progress(transferredBytes: 6, totalBytes: 6))
                        continuation.finish()
                    }

                    continuation.onTermination = { _ in
                        producer.cancel()
                    }
                }
            }
        )

        let client = FileTransferClient(baseURL: HTTPFixtures.baseURL, transport: transport)
        let operation = try await client.uploadWithProgress(
            AuthorizedFileUploadEndpoint(uploadBody: .file(tempFileURL, contentType: "text/plain")),
            bearerToken: "test-token"
        )

        var iterator = operation.events.makeAsyncIterator()
        let firstEvent = try await iterator.next()
        guard case .progress(let progress)? = firstEvent else {
            Issue.record("预期第一条事件为上传进度。")
            return
        }
        #expect(progress.transferredBytes == 3)

        operation.cancel()

        let nextEvent = try await iterator.next()
        if nextEvent != nil {
            Issue.record("取消上传后不应再收到后续事件。")
        }
    }

    @Test func backgroundUploadWithProgressIsRejected() async throws {
        let tempFileURL = FileManager.default.temporaryDirectory.appending(path: "background-progress-upload-\(UUID().uuidString).txt")
        try Data("progress".utf8).write(to: tempFileURL)
        defer { try? FileManager.default.removeItem(at: tempFileURL) }

        let client = FileTransferClient(baseURL: HTTPFixtures.baseURL, transport: MockFileTransferTransport())

        do {
            _ = try await client.uploadWithProgress(
                BackgroundAuthorizedFileUploadEndpoint(
                    uploadBody: .file(tempFileURL, contentType: "text/plain")
                ),
                bearerToken: "test-token"
            )
            Issue.record("预期抛出 unsupported。")
        } catch let error as APIError {
            if case .unsupported(let message) = error {
                #expect(message.contains("upload"))
            } else {
                Issue.record("收到错误类型不正确：\(error.localizedDescription)")
            }
        }
    }

    @Test func backgroundDownloadWithProgressIsRejected() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appending(path: "background-progress-download-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let client = FileTransferClient(baseURL: HTTPFixtures.baseURL, transport: MockFileTransferTransport())

        do {
            _ = try await client.downloadWithProgress(
                BackgroundAuthorizedDownloadEndpointForTests(),
                to: destinationURL,
                bearerToken: "test-token"
            )
            Issue.record("预期抛出 unsupported。")
        } catch let error as APIError {
            if case .unsupported(let message) = error {
                #expect(message.contains("download"))
            } else {
                Issue.record("收到错误类型不正确：\(error.localizedDescription)")
            }
        }
    }
}
