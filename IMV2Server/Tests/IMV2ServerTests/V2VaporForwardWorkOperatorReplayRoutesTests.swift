import Foundation
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("Forward replay operator HTTP boundary")
struct V2VaporForwardWorkOperatorReplayRoutesTests {
    @Test("explicit owner routing, authentication and sanitized errors", arguments: ["ok", "unauthenticated", "malformed", "unknown", "conflict", "owner", "database"])
    func boundary(scenario: String) async throws {
        let app = try await Application.make(.testing)
        do {
            let token = Data(repeating: 19, count: 32).base64EncodedString()
            let store = ForwardReplayHTTPStore(scenario: scenario)
            let service = try V2ForwardWorkOperatorReplayService(stores: ["room-a": store], operatorPrincipal: "oncall-test")
            V2VaporForwardWorkOperatorReplayRoutes(authenticator: try .init(base64EncodedBearerToken: token), service: service).register(on: app)
            let input = V2ForwardWorkReplayHTTPRequest(operationID: UUID(), shardID: scenario == "unknown" ? "room-b" : "room-a",
                kind: scenario == "malformed" ? .media : .delivery, exportID: UUID(), reason: .dependencyRecovered)
            let expected: HTTPStatus = ["ok": .ok, "unauthenticated": .unauthorized, "malformed": .badRequest,
                "unknown": .notFound, "conflict": .conflict, "owner": .conflict, "database": .serviceUnavailable][scenario]!
            try await app.testing().test(.POST, "internal/v2/forward-work/replay",
                headers: ["Authorization": "Bearer \(scenario == "unauthenticated" ? "wrong" : token)"],
                beforeRequest: { try $0.content.encode(input) }) { response async in
                #expect(response.status == expected)
                if scenario == "ok" {
                    #expect(response.headers.first(name: .cacheControl) == "no-store")
                    expectContent(V2DurableWorkReplayHTTPResponse.self, response) {
                        #expect($0.operationID == input.operationID && $0.outcome == .requeued)
                    }
                }
                #expect(!response.body.string.contains("private-database-detail"))
            }
            #expect(await store.calls == (["unauthenticated", "malformed", "unknown"].contains(scenario) ? 0 : 1))
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }
}

private actor ForwardReplayHTTPStore: V2ForwardWorkReplayStore {
    let scenario: String
    private(set) var calls = 0
    init(scenario: String) { self.scenario = scenario }
    func replay(_ command: V2ForwardWorkReplayCommand, operatorPrincipal: String, now: Date) async throws -> V2DurableWorkReplayResult {
        calls += 1
        #expect(operatorPrincipal == "oncall-test")
        #expect(command.shardID == "room-a")
        if scenario == "conflict" { throw V2ForwardWorkReplayError.idempotencyConflict }
        if scenario == "owner" { throw V2ForwardWorkReplayError.ownerChanged }
        if scenario == "database" { throw NSError(domain: "private-database-detail", code: 1) }
        return .init(operationID: command.operationID, outcome: .requeued, wasIdempotent: false)
    }
}
