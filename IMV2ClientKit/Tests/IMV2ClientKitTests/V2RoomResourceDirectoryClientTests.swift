import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Resource directory HTTP client")
struct V2RoomResourceDirectoryClientTests {
    private func page(room: RoomID) throws -> V2RoomResourcePage {
        let media = MediaID(uuid: UUID())
        return try .init(items: [.init(messageID: .init(uuid: UUID()), messageRevision: 1,
            position: .init(roomSequence: 9, ordinal: 0, mediaID: media), createdAt: 1000,
            descriptor: .init(key: .init(home: .room(room), mediaID: media), revision: 1, displayName: .init("photo.jpg"),
                contentType: "image/jpeg", byteCount: 32, checksum: .init(value: String(repeating: "a", count: 64)), state: .ready))],
            snapshotUpperRoomSequence: 10, nextCursor: nil)
    }

    @Test func sendsScopedAuthenticatedQueryAndValidatesResultContext() async throws {
        let room = RoomID(uuid: UUID()), expected = try page(room: room)
        let http = DirectoryClientHTTP(data: try JSONEncoder().encode(expected), status: 200)
        let client = try V2HTTPRoomResourceDirectoryClient(baseURL: #require(URL(string: "https://account.invalid")), credentials: DirectoryClientCredentials(), transport: http)
        #expect(try await client.query(roomID: room, query: .init(category: .image)) == expected)
        let request = try #require(await http.last)
        #expect(request.url?.path == "/v2/rooms/\(room.rawValue)/resources/query")
        #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let body = try #require(request.httpBody)
        #expect(try JSONDecoder().decode(V2RoomResourceQuery.self, from: body).category == .image)
        await #expect(throws: V2ClientResourceDirectoryError.invalidResponse) {
            try await client.query(roomID: .init(uuid: UUID()), query: .init())
        }
        await #expect(throws: V2ClientResourceDirectoryError.invalidResponse) {
            try await client.query(roomID: room, query: .init(category: .file))
        }
    }

    @Test func rejectsAContinuationWhichDoesNotAdvance() async throws {
        let room = RoomID(uuid: UUID()), entry = try page(room: room)
        let response = try V2RoomResourcePage(items: entry.items, snapshotUpperRoomSequence: 10, nextCursor: "same-cursor")
        let http = DirectoryClientHTTP(data: try JSONEncoder().encode(response), status: 200)
        let client = try V2HTTPRoomResourceDirectoryClient(baseURL: #require(URL(string: "https://account.invalid")),
            credentials: DirectoryClientCredentials(), transport: http)
        await #expect(throws: V2ClientResourceDirectoryError.invalidResponse) {
            try await client.query(roomID: room, query: .init(cursor: "same-cursor"))
        }
        // A newly issued cursor is valid, including on the first page.
        #expect(try await client.query(roomID: room, query: .init()) == response)
        #expect(try await client.query(roomID: room, query: .init(cursor: "previous-cursor")) == response)
    }

    @Test(arguments: [400,401,403,404,429,500,302])
    func mapsStatusBeforeTryingToDecode(code: Int) async throws {
        let http = DirectoryClientHTTP(data: Data("not JSON".utf8), status: code)
        let client = try V2HTTPRoomResourceDirectoryClient(baseURL: #require(URL(string: "https://account.invalid")), credentials: DirectoryClientCredentials(), transport: http)
        let error: V2ClientResourceDirectoryError
        switch code {
        case 400: error = .invalidCursor
        case 401: error = .authorizationUnavailable
        case 403,404: error = .notVisible
        case 429,500: error = .unavailable
        default: error = .invalidResponse
        }
        await #expect(throws: error) { try await client.query(roomID: .init(uuid: UUID()), query: .init()) }
    }
}
private struct DirectoryClientCredentials: V2ClientMediaEdgeCredentialProvider {
    func mediaEdgeCredentials() throws -> V2ClientMediaEdgeCredentials {
        .init(accessToken: "fixture", deviceID: .init(uuid: UUID()))
    }
}
private actor DirectoryClientHTTP: V2ClientMediaEdgeHTTPTransport {
    let data: Data; let status: Int
    var last: URLRequest?
    init(data: Data, status: Int) { self.data = data; self.status = status }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        last = request
        let url = try #require(request.url)
        return (data, try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type":"application/json"])))
    }
}
