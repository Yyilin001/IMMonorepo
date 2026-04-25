import Foundation

public struct MediaUploadCreateRequestBody: Codable, Sendable {
    public let kind: IMMediaAssetKind
    public let mimeType: String
    public let byteSize: Int64
    public let filename: String
    public let width: Int?
    public let height: Int?
    public let durationMillis: Int?
    public let previewAssetID: String?

    public init(
        kind: IMMediaAssetKind,
        mimeType: String,
        byteSize: Int64,
        filename: String,
        width: Int? = nil,
        height: Int? = nil,
        durationMillis: Int? = nil,
        previewAssetID: String? = nil
    ) {
        self.kind = kind
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.filename = filename
        self.width = width
        self.height = height
        self.durationMillis = durationMillis
        self.previewAssetID = previewAssetID
    }
}

public struct MediaUploadSessionResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let uploadID: String
    public let uploadPath: String
    public let completePath: String
    public let expiresAt: Date
}

public enum MediaRequest {
    public struct CreateUploadSession: AuthorizedEndpoint {
        public typealias Response = MediaUploadSessionResponseBody

        let payload: MediaUploadCreateRequestBody

        public var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/media/uploads", method: .post)
        }

        public var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct UploadChunk: AuthorizedUploadEndpoint {
        public typealias Response = EmptyResponse

        public let baseRequestSpec: HTTPRequestSpec
        public let uploadBody: UploadBody
        public let retryPolicy: RetryPolicy
        public let cachePolicy: RequestCachePolicy
        public let backgroundTransfer: BackgroundTransferConfiguration?
        public var transportKind: TransportKind {
            backgroundTransfer == nil ? .upload : .backgroundUpload
        }

        public init(
            uploadID: String,
            uploadBody: UploadBody,
            retryPolicy: RetryPolicy = .useDefault,
            cachePolicy: RequestCachePolicy = .reloadIgnoringLocalCacheData,
            backgroundTransfer: BackgroundTransferConfiguration? = nil
        ) {
            self.baseRequestSpec = .init(
                path: "api/media/uploads/\(uploadID)/chunk",
                method: .put
            )
            self.uploadBody = uploadBody
            self.retryPolicy = retryPolicy
            self.cachePolicy = cachePolicy
            self.backgroundTransfer = backgroundTransfer
        }
    }

    public struct CompleteUpload: AuthorizedEndpoint {
        public typealias Response = IMMediaAsset

        let uploadID: String

        public var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/media/uploads/\(uploadID)/complete", method: .post)
        }
    }

    public struct DownloadAsset: AuthorizedDownloadEndpoint {
        public let baseRequestSpec: HTTPRequestSpec
        public let retryPolicy: RetryPolicy
        public let cachePolicy: RequestCachePolicy
        public let backgroundTransfer: BackgroundTransferConfiguration?

        public init(
            assetID: String,
            retryPolicy: RetryPolicy = .useDefault,
            cachePolicy: RequestCachePolicy = .reloadIgnoringLocalCacheData,
            backgroundTransfer: BackgroundTransferConfiguration? = nil
        ) {
            self.baseRequestSpec = .init(path: "api/media/assets/\(assetID)", method: .get)
            self.retryPolicy = retryPolicy
            self.cachePolicy = cachePolicy
            self.backgroundTransfer = backgroundTransfer
        }
    }
}
