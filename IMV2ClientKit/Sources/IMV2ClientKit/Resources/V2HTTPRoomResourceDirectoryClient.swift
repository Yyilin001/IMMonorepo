import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public protocol V2RoomResourceDirectoryReading: Sendable {
    func query(roomID: RoomID, query: V2RoomResourceQuery) async throws -> V2RoomResourcePage
}

public enum V2ClientResourceDirectoryError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidResponse, authorizationUnavailable, notVisible, invalidCursor, unavailable
}

public struct V2HTTPRoomResourceDirectoryClient: V2RoomResourceDirectoryReading {
    private let baseURL: URL
    private let credentials: any V2ClientMediaEdgeCredentialProvider
    private let transport: any V2ClientMediaEdgeHTTPTransport
    public init(baseURL: URL, credentials: any V2ClientMediaEdgeCredentialProvider,
                transport: any V2ClientMediaEdgeHTTPTransport) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw V2ClientResourceDirectoryError.invalidEndpoint }
        self.baseURL = baseURL; self.credentials = credentials; self.transport = transport
    }

    public func query(roomID: RoomID, query: V2RoomResourceQuery) async throws -> V2RoomResourcePage {
        try Task.checkCancellation()
        let credential = try await credentials.mediaEdgeCredentials()
        try Task.checkCancellation()
        guard !credential.accessToken.isEmpty, !credential.accessToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw V2ClientResourceDirectoryError.authorizationUnavailable
        }
        let endpoint = baseURL.appendingPathComponent("v2/rooms").appendingPathComponent(roomID.rawValue).appendingPathComponent("resources/query")
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(query)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        V2HTTPRequestDeadline.attach(credential.requestDeadline, to: &request)
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard data.count <= 512 * 1_024 else { throw V2ClientResourceDirectoryError.invalidResponse }
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 401: throw V2ClientResourceDirectoryError.authorizationUnavailable
        case 403,404: throw V2ClientResourceDirectoryError.notVisible
        case 400: throw V2ClientResourceDirectoryError.invalidCursor
        case 429,500...599: throw V2ClientResourceDirectoryError.unavailable
        default: throw V2ClientResourceDirectoryError.invalidResponse
        }
        let page: V2RoomResourcePage
        do { page = try JSONDecoder().decode(V2RoomResourcePage.self, from: data) }
        catch { throw V2ClientResourceDirectoryError.invalidResponse }
        guard page.items.count <= query.limit,
              page.nextCursor.map({ $0 != query.cursor }) ?? true,
              page.items.allSatisfy({ item in
                  item.descriptor.key.home == .room(roomID) && item.descriptor.state == .ready
                  && query.category.includes(contentType: item.descriptor.contentType)
                  && (query.before.map({ item.createdAt < $0 }) ?? true)
                  && (query.after.map({ item.createdAt > $0 }) ?? true)
              }) else { throw V2ClientResourceDirectoryError.invalidResponse }
        return page
    }
}
