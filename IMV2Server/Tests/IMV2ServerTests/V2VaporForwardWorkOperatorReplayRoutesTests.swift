import IMV2ServerApplication
import IMV2ServerContracts
import HTTPTypes
import Foundation
import IMV2Server
import IMV2ServerInfrastructure
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("Forward replay operator HTTP boundary")
struct V2VaporForwardWorkOperatorReplayRoutesTests {
    @Test("explicit owner routing, authentication and sanitized errors", arguments: ["ok", "unauthenticated", "malformed", "unknown", "conflict", "owner", "database"])
    func boundary(scenario: String) async throws {
        let app = try await Application(.testing)
        do {
            let token = Data(repeating: 19, count: 32).base64EncodedString()
            let store = ForwardReplayHTTPStore(scenario: scenario)
            let service = try V2ForwardWorkOperatorReplayService(stores: ["room-a": store], operatorPrincipal: "oncall-test")
            V2VaporForwardWorkOperatorReplayRoutes(authenticator: try .init(base64EncodedBearerToken: token), service: service).register(on: app)
            let input = V2ForwardWorkReplayHTTPRequest(operationID: UUID(), shardID: scenario == "unknown" ? "room-b" : "room-a",
                kind: scenario == "malformed" ? .media : .delivery, exportID: UUID(), reason: .dependencyRecovered)
            let expected: HTTPResponse.Status = ["ok": .ok, "unauthenticated": .unauthorized, "malformed": .badRequest,
                "unknown": .notFound, "conflict": .conflict, "owner": .conflict, "database": .serviceUnavailable][scenario]!
            try await app.testing { client in
                let response = try await client.send(.post, headers: [.authorization: "Bearer \(scenario == "unauthenticated" ? "wrong" : token)"], to: "internal/v2/forward-work/replay", beforeSend: { try $0.content.encode(input) })
                #expect(response.status == expected)
                if scenario == "ok" {
                    #expect(response.headers[.cacheControl] == "no-store")
                    let decoded = try await response.content.decode(V2DurableWorkReplayHTTPResponse.self)
                    #expect(decoded.operationID == input.operationID && decoded.outcome == .requeued)
                }
                #expect(!(try await response.body.string() ?? "").contains("private-database-detail"))
            }
            #expect(await store.calls == (["unauthenticated", "malformed", "unknown"].contains(scenario) ? 0 : 1))
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
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
