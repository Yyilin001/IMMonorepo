import Foundation
@testable import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("Invite directory import operator HTTP")
struct V2VaporGroupInviteDirectoryImportRoutesTests {
    @Test("bounded authenticated import and sanitized outcomes", arguments: ["ok", "unauthenticated", "malformed", "limit", "epoch", "unknown", "owner", "conflict", "database"])
    func boundary(_ scenario: String) async throws {
        let app = try await Application.make(.testing)
        do {
            let token = Data(repeating: 37, count: 32).base64EncodedString()
            let service = InviteImportHTTPService(scenario: scenario)
            V2VaporGroupInviteDirectoryImportRoutes(authenticator: try .init(base64EncodedBearerToken: token), service: service).register(on: app)
            let input = V2GroupInviteDirectoryImportHTTPRequest(operationID: UUID(), shardID: "room-b",
                ownerEpoch: scenario == "epoch" ? -1 : 0, roomID: UUID(), afterInviteID: nil,
                limit: scenario == "limit" ? 101 : 100, reason: .dataRepaired)
            let expected: HTTPStatus = ["ok": .ok, "unauthenticated": .unauthorized, "malformed": .badRequest, "limit": .badRequest, "epoch": .badRequest, "unknown": .notFound, "owner": .conflict, "conflict": .conflict, "database": .serviceUnavailable][scenario]!
            try await app.testing().test(.POST, "internal/v2/group-invites/import-directory",
                headers: ["Authorization": "Bearer \(scenario == "unauthenticated" ? "wrong" : token)"], beforeRequest: {
                    if scenario == "malformed" || scenario == "unauthenticated" { $0.headers.contentType = .json; $0.body = .init(string: "{") }
                    else { try $0.content.encode(input) }
                }) { response async throws in
                    #expect(response.status == expected)
                    #expect(!response.body.string.contains("private-import-database"))
                    if expected == .ok {
                        #expect(response.headers.first(name: .cacheControl) == "no-store")
                        let result = try JSONDecoder().decode(V2GroupInviteDirectoryImportResult.self, from: Data(response.body.string.utf8))
                        #expect(result.operationID == input.operationID && result.outcome == .conflict)
                    }
                }
            #expect(await service.calls == (["unauthenticated", "malformed", "limit", "epoch"].contains(scenario) ? 0 : 1))
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }
}
private actor InviteImportHTTPService: V2GroupInviteDirectoryImporting {
    let scenario: String
    private(set) var calls = 0
    init(scenario: String) { self.scenario = scenario }
    func importPage(_ command: V2GroupInviteDirectoryImportCommand) async throws -> V2GroupInviteDirectoryImportResult {
        calls += 1
        #expect(command.shardID == "room-b" && command.limit == 100 && command.reason == .dataRepaired)
        if scenario == "unknown" { throw V2GroupInviteDirectoryImportError.unknownShard }
        if scenario == "owner" { throw V2GroupInviteDirectoryImportError.ownerChanged }
        if scenario == "conflict" { throw V2GroupInviteDirectoryImportError.idempotencyConflict }
        if scenario == "database" { throw NSError(domain: "private-import-database", code: 1) }
        return .init(operationID: command.operationID, outcome: .conflict, sourceCount: 1,
            insertedCount: 0, publishedCount: 0, unchangedCount: 0, nextCursor: nil,
            conflictingInviteIDs: [UUID()], wasIdempotent: false)
    }
}
