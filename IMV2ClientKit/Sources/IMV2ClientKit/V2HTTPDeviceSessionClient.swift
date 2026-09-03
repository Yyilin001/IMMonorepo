import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// Account-owned session metadata returned by the account edge. Device IDs
/// are opaque and used solely for an explicit remote-log-out command.
public struct V2ClientDeviceSession: Equatable, Sendable, Identifiable {
    public let deviceID: DeviceID
    public let deviceName: String
    public let platform: String
    public let createdAt: Date
    public let lastActiveAt: Date
    public let isCurrentDevice: Bool

    public var id: DeviceID { deviceID }
    public init(deviceID: DeviceID, deviceName: String, platform: String, createdAt: Date, lastActiveAt: Date, isCurrentDevice: Bool) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.isCurrentDevice = isCurrentDevice
    }
}

public struct V2ClientDeviceSessionPage: Equatable, Sendable {
    public let sessions: [V2ClientDeviceSession]
    public let nextCursor: String?

    public init(sessions: [V2ClientDeviceSession], nextCursor: String?) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

public struct V2ClientDeviceSessionCredentials: Sendable {
    public let accessToken: String
    public let deviceID: DeviceID
    public init(accessToken: String, deviceID: DeviceID) { self.accessToken = accessToken; self.deviceID = deviceID }
}

public protocol V2ClientDeviceSessionCredentialProvider: Sendable {
    func deviceSessionCredentials() async throws -> V2ClientDeviceSessionCredentials
}

public protocol V2ClientDeviceSessionHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public actor V2URLSessionDeviceSessionHTTPTransport: V2ClientDeviceSessionHTTPTransport {
    private let session: URLSession
    public init(session: URLSession = V2SecureURLSession.account) { self.session = session }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw V2ClientDeviceSessionError.invalidResponse }
        return (data, response)
    }
}

public protocol V2ClientDeviceSessionManaging: Sendable {
    func list(cursor: String?, pageSize: Int) async throws -> V2ClientDeviceSessionPage
    func revoke(deviceID: DeviceID, operationID: UUID) async throws
    func revokeOtherDevices(operationID: UUID) async throws
}

/// HTTPS account-edge adapter. The caller provides one stable operation ID
/// per user intent, making a retry after an interrupted response safe.
public struct V2HTTPDeviceSessionClient: V2ClientDeviceSessionManaging, Sendable {
    private let endpoint: URL
    private let credentials: any V2ClientDeviceSessionCredentialProvider
    private let transport: any V2ClientDeviceSessionHTTPTransport

    public init(endpoint: URL, credentials: any V2ClientDeviceSessionCredentialProvider, transport: any V2ClientDeviceSessionHTTPTransport = V2URLSessionDeviceSessionHTTPTransport()) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else { throw V2ClientDeviceSessionError.invalidEndpoint }
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
    }

    public func list(cursor: String?, pageSize: Int) async throws -> V2ClientDeviceSessionPage {
        guard (1 ... 100).contains(pageSize) else { throw V2ClientDeviceSessionError.invalidRequest }
        var queryItems = [URLQueryItem(name: "page_size", value: String(pageSize))]
        if let cursor { queryItems.append(.init(name: "cursor", value: cursor)) }
        let request = try await authenticatedRequest(path: [], method: "GET", queryItems: queryItems)
        let (data, response) = try await send(request)
        guard response.statusCode == 200,
              V2HTTPContract.isJSON(response)
        else {
            if response.statusCode == 200 { throw V2ClientDeviceSessionError.invalidResponse }
            throw try failure(for: response)
        }
        do {
            let body = try JSONDecoder().decode(SessionPageBody.self, from: data)
            let sessions: [V2ClientDeviceSession] = try body.sessions.map {
                try V2ClientDeviceSession(
                    deviceID: .init($0.deviceID),
                    deviceName: $0.deviceName,
                    platform: $0.platform,
                    createdAt: Date(timeIntervalSince1970: Double($0.createdAtMilliseconds) / 1_000),
                    lastActiveAt: Date(timeIntervalSince1970: Double($0.lastActiveAtMilliseconds) / 1_000),
                    isCurrentDevice: $0.isCurrentDevice
                )
            }
            return .init(sessions: sessions, nextCursor: body.nextCursor)
        } catch { throw V2ClientDeviceSessionError.invalidResponse }
    }

    public func revoke(deviceID: DeviceID, operationID: UUID) async throws {
        try await mutate(path: ["revoke"], body: .init(deviceID: deviceID.rawValue, operationID: operationID))
    }

    public func revokeOtherDevices(operationID: UUID) async throws {
        try await mutate(path: ["revoke-others"], body: .init(deviceID: nil, operationID: operationID))
    }

    private func mutate(path: [String], body: MutationBody) async throws {
        var request = try await authenticatedRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { request.httpBody = try JSONEncoder().encode(body) }
        catch { throw V2ClientDeviceSessionError.invalidRequest }
        let (_, response) = try await send(request)
        guard response.statusCode == 204 else { throw try failure(for: response) }
    }

    private func authenticatedRequest(path: [String], method: String, queryItems: [URLQueryItem] = []) async throws -> URLRequest {
        let current: V2ClientDeviceSessionCredentials
        do { current = try await credentials.deviceSessionCredentials() }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2ClientDeviceSessionError.authorizationUnavailable }
        guard !current.accessToken.isEmpty,
              !current.accessToken.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2ClientDeviceSessionError.authorizationUnavailable }
        let pathTarget = path.reduce(endpoint) { $0.appendingPathComponent($1) }
        guard var components = URLComponents(url: pathTarget, resolvingAgainstBaseURL: false) else {
            throw V2ClientDeviceSessionError.invalidEndpoint
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let target = components.url else { throw V2ClientDeviceSessionError.invalidRequest }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(current.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as V2ClientDeviceSessionError { throw error }
        catch { throw V2ClientDeviceSessionError.networkFailure }
    }

    private func failure(for response: HTTPURLResponse) throws -> V2ClientDeviceSessionError {
        switch response.statusCode {
        case 400: return .invalidRequest
        case 401, 403: return .authorizationDenied
        case 404: return .sessionUnavailable
        default: return .serverStatus(response.statusCode)
        }
    }
}

public enum V2ClientDeviceSessionError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidRequest
    case authorizationUnavailable
    case authorizationDenied
    case sessionUnavailable
    case invalidResponse
    case serverStatus(Int)
    case networkFailure
}

private struct SessionBody: Decodable {
    let deviceID: String; let deviceName: String; let platform: String
    let createdAtMilliseconds: Int64; let lastActiveAtMilliseconds: Int64; let isCurrentDevice: Bool
}
private struct SessionPageBody: Decodable { let sessions: [SessionBody]; let nextCursor: String? }
private struct MutationBody: Encodable { let deviceID: String?; let operationID: UUID }
