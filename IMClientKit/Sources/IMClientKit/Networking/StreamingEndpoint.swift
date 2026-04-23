import Foundation

public protocol StreamingCapability: Sendable {
    var preferredChunkSize: Int { get }
}

public protocol StreamingEndpoint: RequestSpecProviding, RequestBodyCapability, StreamingCapability, RequestExecutionOptionsProviding { }

public protocol AuthorizedStreamingEndpoint: StreamingEndpoint, AuthorizedRequestSpecProviding { }

extension StreamingCapability {
    var preferredChunkSize: Int { 4096 }
}

extension StreamingEndpoint {
    public var transportKind: TransportKind { .stream }
}

public struct StreamingConnection: Sendable {
    public let chunks: AsyncThrowingStream<Data, Error>
}
