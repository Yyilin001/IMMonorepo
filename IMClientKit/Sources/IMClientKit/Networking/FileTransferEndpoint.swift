import Foundation

public struct FileTransferProgress: Sendable, Equatable {
    public let transferredBytes: Int64
    public let totalBytes: Int64?
    public let resumedBytes: Int64

    public init(transferredBytes: Int64, totalBytes: Int64?, resumedBytes: Int64 = 0) {
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
        self.resumedBytes = resumedBytes
    }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else {
            return nil
        }
        return Double(transferredBytes) / Double(totalBytes)
    }
}

public enum DownloadTransferEvent: Sendable, Equatable {
    case progress(FileTransferProgress)
    case completed(URL)
}

public enum UploadTransferEvent<Response: APIResponseBody & Sendable>: Sendable {
    case progress(FileTransferProgress)
    case completed(Response)
}

public final class FileTransferCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationAction: (@Sendable () -> Void)?
    private var isCancelled = false

    public func install(_ action: @escaping @Sendable () -> Void) {
        let shouldRunImmediately: Bool
        lock.lock()
        if isCancelled {
            shouldRunImmediately = true
        } else {
            cancellationAction = action
            shouldRunImmediately = false
        }
        lock.unlock()

        if shouldRunImmediately {
            action()
        }
    }

    public func cancel() {
        let action: (@Sendable () -> Void)?
        lock.lock()
        if isCancelled {
            action = nil
        } else {
            isCancelled = true
            action = cancellationAction
            cancellationAction = nil
        }
        lock.unlock()

        action?()
    }
}

public struct FileTransferOperation<Event: Sendable>: Sendable {
    public let events: AsyncThrowingStream<Event, Error>

    private let cancellationController: FileTransferCancellationController

    init(
        events: AsyncThrowingStream<Event, Error>,
        cancellationController: FileTransferCancellationController
    ) {
        self.events = events
        self.cancellationController = cancellationController
    }

    public func cancel() {
        cancellationController.cancel()
    }
}

public struct MultipartPart: Sendable {
    public let name: String
    public let filename: String?
    public let contentType: String?
    public let data: Data

    init(name: String, filename: String? = nil, contentType: String? = nil, data: Data) {
        self.name = name
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

public struct MultipartFormData: Sendable {
    public let boundary: String
    public let parts: [MultipartPart]

    init(parts: [MultipartPart], boundary: String = UUID().uuidString) {
        self.parts = parts
        self.boundary = boundary
    }

    public var contentTypeHeader: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public func encoded() -> Data {
        var body = Data()
        let lineBreak = Data("\r\n".utf8)

        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let filename = part.filename {
                disposition += "; filename=\"\(filename)\""
            }
            body.append(Data(disposition.utf8))
            body.append(lineBreak)

            if let contentType = part.contentType {
                body.append(Data("Content-Type: \(contentType)".utf8))
                body.append(lineBreak)
            }

            body.append(lineBreak)
            body.append(part.data)
            body.append(lineBreak)
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}

public enum UploadBody: Sendable {
    case data(Data, contentType: String)
    case file(URL, contentType: String)
    case multipart(MultipartFormData)

    public var contentTypeHeader: String {
        switch self {
        case .data(_, let contentType), .file(_, let contentType):
            return contentType
        case .multipart(let formData):
            return formData.contentTypeHeader
        }
    }

    public func inMemoryData() throws -> Data? {
        switch self {
        case .data(let data, _):
            return data
        case .file:
            return nil
        case .multipart(let formData):
            return formData.encoded()
        }
    }

    public var fileURL: URL? {
        guard case .file(let fileURL, _) = self else {
            return nil
        }
        return fileURL
    }
}

public protocol UploadEndpoint: RequestSpecProviding, RequestExecutionOptionsProviding, BackgroundTransferCapability {
    associatedtype Response: APIResponseBody

    var uploadBody: UploadBody { get }
}

public protocol AuthorizedUploadEndpoint: UploadEndpoint, AuthorizedRequestSpecProviding { }

public protocol DownloadEndpoint: RequestSpecProviding, RequestBodyCapability, RequestExecutionOptionsProviding, BackgroundTransferCapability { }

public protocol AuthorizedDownloadEndpoint: DownloadEndpoint, AuthorizedRequestSpecProviding { }

extension UploadEndpoint {
    var transportKind: TransportKind {
        backgroundTransfer == nil ? .upload : .backgroundUpload
    }
}

extension DownloadEndpoint {
    public var transportKind: TransportKind {
        backgroundTransfer == nil ? .download : .backgroundDownload
    }
}
