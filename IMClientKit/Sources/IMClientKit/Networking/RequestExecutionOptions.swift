import Foundation

public enum TransportKind: Sendable, Equatable {
    case request
    case upload
    case backgroundUpload
    case download
    case backgroundDownload
    case stream

    public var isBackgroundTransfer: Bool {
        switch self {
        case .backgroundUpload, .backgroundDownload:
            return true
        case .request, .upload, .download, .stream:
            return false
        }
    }
}

public enum RetryPolicy: Sendable, Equatable {
    case useDefault
    case never
    case refreshTokenOnUnauthorized(maxAttempts: Int)

    public func unauthorizedRefreshAttempts(requiresAuthorization: Bool) -> Int {
        switch self {
        case .useDefault:
            return requiresAuthorization ? 1 : 0
        case .never:
            return 0
        case .refreshTokenOnUnauthorized(let maxAttempts):
            return max(0, maxAttempts)
        }
    }
}

public enum RequestCachePolicy: Sendable, Equatable {
    case useProtocolCachePolicy
    case reloadIgnoringLocalCacheData
    case returnCacheDataElseLoad
    case returnCacheDataDontLoad

    public var urlRequestCachePolicy: URLRequest.CachePolicy {
        switch self {
        case .useProtocolCachePolicy:
            return .useProtocolCachePolicy
        case .reloadIgnoringLocalCacheData:
            return .reloadIgnoringLocalCacheData
        case .returnCacheDataElseLoad:
            return .returnCacheDataElseLoad
        case .returnCacheDataDontLoad:
            return .returnCacheDataDontLoad
        }
    }
}

public struct BackgroundTransferConfiguration: Sendable, Equatable {
    public let identifier: String?
    public let isDiscretionary: Bool
    public let waitsForConnectivity: Bool

    init(
        identifier: String? = nil,
        isDiscretionary: Bool = true,
        waitsForConnectivity: Bool = true
    ) {
        self.identifier = identifier
        self.isDiscretionary = isDiscretionary
        self.waitsForConnectivity = waitsForConnectivity
    }
}

public protocol RequestExecutionOptionsProviding: Sendable {
    var transportKind: TransportKind { get }
    var retryPolicy: RetryPolicy { get }
    var cachePolicy: RequestCachePolicy { get }
}

public protocol BackgroundTransferCapability: Sendable {
    var backgroundTransfer: BackgroundTransferConfiguration? { get }
}

extension RequestExecutionOptionsProviding {
    public var retryPolicy: RetryPolicy { .useDefault }
    public var cachePolicy: RequestCachePolicy { .useProtocolCachePolicy }
}

extension BackgroundTransferCapability {
    public var backgroundTransfer: BackgroundTransferConfiguration? { nil }
}
