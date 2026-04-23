import Foundation

public struct NetworkEnvironment: Sendable {
    public let baseURL: URL
    public let session: URLSession
    public let logger: HTTPLogHandler
    public let coding: HTTPCodingConfiguration

    public init(
        baseURL: URL = AppConstants.apiBaseURL,
        sessionConfiguration: URLSessionConfiguration = .default,
        logger: HTTPLogHandler = .noop,
        coding: HTTPCodingConfiguration = .default
    ) {
        let configuration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? sessionConfiguration
        self.init(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            logger: logger,
            coding: coding
        )
    }

    public init(
        baseURL: URL = AppConstants.apiBaseURL,
        session: URLSession,
        logger: HTTPLogHandler = .noop,
        coding: HTTPCodingConfiguration = .default
    ) {
        self.baseURL = baseURL
        self.session = session
        self.logger = logger
        self.coding = coding
    }

    public func makeHTTPClient() -> HTTPClient {
        HTTPClient(
            baseURL: baseURL,
            transport: URLSessionTransport(session: session),
            logger: logger,
            coding: coding
        )
    }

    public func makeFileTransferClient() -> FileTransferClient {
        FileTransferClient(
            baseURL: baseURL,
            transport: URLSessionFileTransferTransport(session: session),
            logger: logger,
            coding: coding
        )
    }

    public func makeStreamingClient() -> StreamingClient {
        StreamingClient(
            baseURL: baseURL,
            transport: URLSessionStreamingTransport(session: session),
            logger: logger,
            coding: coding
        )
    }
}
