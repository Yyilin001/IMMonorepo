import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Resource import HTTP response context")
struct V2ResourceImportHTTPContractTests {
    enum Action: String, CaseIterable, Sendable { case create, status, cancel }
    enum Mismatch: CaseIterable, Sendable { case operation, home }
    enum Usage: CaseIterable, Sendable { case attachment, personalAvatar, groupAvatar }

    @Test(arguments: Action.allCases)
    func matchingResponsePreservesStatusAndSendsScopedRequest(action: Action) async throws {
        let f = try Fixture(), expected = try f.response()
        let http = ImportContractHTTP(data: try JSONEncoder().encode(expected))
        let client = try f.client(http)
        #expect(try await f.perform(action, client: client) == expected)
        let request = try #require(await http.last)
        let suffix = action == .create ? "" : "/" + action.rawValue
        #expect(request.url?.path == "/v2/resource-imports" + suffix)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let body = try #require(request.httpBody)
        if action == .create { #expect(try JSONDecoder().decode(V2ResourceImportRequest.self, from: body) == f.request) }
        else { #expect(try JSONDecoder().decode(V2ResourceImportLocator.self, from: body) == f.locator) }
    }

    @Test(arguments: Action.allCases, Mismatch.allCases)
    func rejectsAnotherOperationsOrHomesResponse(action: Action, mismatch: Mismatch) async throws {
        let f = try Fixture()
        let response = try f.response(locator: .init(home: mismatch == .home ? .room(.init(uuid: UUID())) : f.locator.home,
            operationID: mismatch == .operation ? .init(uuid: UUID()) : f.locator.operationID))
        let client = try f.client(ImportContractHTTP(data: JSONEncoder().encode(response)))
        await #expect(throws: V2ClientMediaTransferError.invalidMediaEdgeResponse) { try await f.perform(action, client: client) }
    }

    @Test(arguments: Usage.allCases)
    func creationRejectsWrongMediaAndWrongDestinationKind(usage: Usage) async throws {
        let f = try Fixture(usage: usage)
        let expected = try f.response()
        let matching = try f.client(ImportContractHTTP(data: JSONEncoder().encode(expected)))
        #expect(try await matching.create(f.request) == expected)
        let wrongKind: V2ResourceHome = switch f.locator.home {
        case .room: .account(.init(uuid: UUID()))
        case .account: .room(.init(uuid: UUID()))
        }
        for response in [try f.response(media: .init(uuid: UUID())), try f.response(locator: .init(home: wrongKind, operationID: f.locator.operationID))] {
            let client = try f.client(ImportContractHTTP(data: JSONEncoder().encode(response)))
            await #expect(throws: V2ClientMediaTransferError.invalidMediaEdgeResponse) { try await client.create(f.request) }
        }
    }

    @Test(arguments: Action.allCases)
    func malformedSuccessUsesTheTypedContractError(action: Action) async throws {
        let f = try Fixture(), client = try f.client(ImportContractHTTP(data: Data("{}".utf8)))
        await #expect(throws: V2ClientMediaTransferError.invalidMediaEdgeResponse) { try await f.perform(action, client: client) }
    }

    private struct Fixture {
        let request: V2ResourceImportRequest
        let locator: V2ResourceImportLocator
        init(usage: Usage = .attachment) throws {
            let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
            let target: V2ResourceUsage = switch usage {
            case .attachment: .messageAttachment(room)
            case .personalAvatar: .userAvatar
            case .groupAvatar: .groupAvatar(room)
            }
            request = try .init(operationID: .init(uuid: UUID()),
                source: .message(location: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())),
                    mediaID: .init(uuid: UUID()), variantID: nil),
                targetUsage: target, targetMediaID: .init(uuid: UUID()))
            locator = .init(home: target.home(actorUserID: user), operationID: request.operationID)
        }
        func response(locator: V2ResourceImportLocator? = nil, media: MediaID? = nil) throws -> V2ResourceImportStatus {
            try .init(locator: locator ?? self.locator, mediaID: media ?? request.targetMediaID, state: .copying, bindableUntil: nil)
        }
        func client(_ http: ImportContractHTTP) throws -> V2HTTPResourceImportClient {
            try .init(endpoint: #require(URL(string: "https://account.invalid/v2/resource-imports")),
                credentials: ImportContractCredentials(), transport: http)
        }
        func perform(_ action: Action, client: V2HTTPResourceImportClient) async throws -> V2ResourceImportStatus {
            switch action {
            case .create: try await client.create(request)
            case .status: try await client.status(locator)
            case .cancel: try await client.cancel(locator)
            }
        }
    }
}

private struct ImportContractCredentials: V2ClientMediaEdgeCredentialProvider {
    func mediaEdgeCredentials() -> V2ClientMediaEdgeCredentials {
        .init(accessToken: "fixture", deviceID: .init(uuid: UUID()))
    }
}
private actor ImportContractHTTP: V2ClientMediaEdgeHTTPTransport {
    let data: Data
    var last: URLRequest?
    init(data: Data) { self.data = data }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        last = request
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (data, response)
    }
}
