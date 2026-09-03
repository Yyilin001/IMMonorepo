import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(OSLog)
import OSLog
#endif
import IMV2Core

/// Isolates URLSession from authentication request/response validation. This
/// keeps refresh-rotation tests deterministic and prevents callers from
/// accidentally observing refresh credentials through URLSession delegates.
public protocol V2AuthHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public actor V2URLSessionAuthHTTPTransport: V2AuthHTTPTransport {
    private let session: URLSession

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.stskcxfz.imapp", category: "v2.http-auth")
    #endif

    public init(session: URLSession = V2SecureURLSession.account) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            #if canImport(OSLog)
            // URLSession's numeric code is enough to distinguish trust,
            // connection and timeout failures without logging a URL or payload.
            Self.logger.error("Auth HTTP transport failed with URL error code \(error.code.rawValue, privacy: .public)")
            #endif
            throw error
        }
        guard let response = response as? HTTPURLResponse else {
            throw V2HTTPAuthTransportError.invalidResponse
        }
        return (data, response)
    }
}

/// HTTPS implementation of the device-credential refresh contract. It sends
/// one persisted operation ID per `V2AuthSession` refresh; the server can
/// therefore replay a completed rotation safely after response loss.
public struct V2HTTPDeviceCredentialAuthTransport: V2AuthTransport, Sendable {
    private let refreshEndpoint: URL
    private let transport: any V2AuthHTTPTransport

    public init(
        refreshEndpoint: URL,
        transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()
    ) throws {
        guard refreshEndpoint.scheme?.lowercased() == "https", refreshEndpoint.host != nil else {
            throw V2HTTPAuthTransportError.invalidEndpoint
        }
        self.refreshEndpoint = refreshEndpoint
        self.transport = transport
    }

    public func refresh(_ request: V2RefreshRequest) async throws -> V2AuthCredentials {
        try Task.checkCancellation()
        var urlRequest = URLRequest(
            url: refreshEndpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Pragma")
        do {
            urlRequest.httpBody = try JSONEncoder().encode(V2DeviceCredentialRefreshHTTPBody(request: request))
        } catch {
            throw V2HTTPAuthTransportError.invalidRequest
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2HTTPAuthTransportError {
            throw error
        } catch {
            throw V2HTTPAuthTransportError.networkFailure
        }
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2HTTPAuthTransportError.invalidResponse
        case 401, 403: throw V2AuthTransportError.terminalRejection
        default: throw V2HTTPAuthTransportError.serverStatus(response.statusCode)
        }

        do {
            let body = try JSONDecoder().decode(V2DeviceCredentialRefreshHTTPResponse.self, from: data)
            return try .init(
                userID: .init(body.userID),
                deviceID: .init(body.deviceID),
                accessToken: body.accessToken,
                accessTokenExpiresAt: Date(timeIntervalSince1970: Double(body.accessTokenExpiresAtMilliseconds) / 1_000),
                refreshCredential: body.refreshCredential
            )
        } catch let error as V2AuthSessionError {
            throw error
        } catch {
            throw V2HTTPAuthTransportError.invalidResponse
        }
    }
}

public enum V2HTTPAuthTransportError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidRequest
    case invalidResponse
    case serverStatus(Int)
    case networkFailure
}

private struct V2DeviceCredentialRefreshHTTPBody: Encodable {
    let userID: String
    let deviceID: String
    let refreshCredential: String
    let operationID: UUID

    init(request: V2RefreshRequest) {
        userID = request.userID.rawValue
        deviceID = request.deviceID.rawValue
        refreshCredential = request.refreshCredential
        operationID = request.operationID
    }
}

private struct V2DeviceCredentialRefreshHTTPResponse: Decodable {
    let userID: String
    let deviceID: String
    let accessToken: String
    let accessTokenExpiresAtMilliseconds: Int64
    let refreshCredential: String
}
