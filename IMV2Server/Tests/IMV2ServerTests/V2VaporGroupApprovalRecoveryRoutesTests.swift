import Foundation
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("Approval recovery operator HTTP")
struct V2VaporGroupApprovalRecoveryRoutesTests {
    @Test("authentication, owner selection, bounded candidates and sanitized recovery errors", arguments: ["ok", "unauthenticated", "malformed", "unknown", "conflict", "owner", "database", "candidates", "limit"])
    func boundary(_ scenario: String) async throws {
        let app = try await Application.make(.testing)
        do {
            let token = Data(repeating: 29, count: 32).base64EncodedString()
            let store = ApprovalRecoveryHTTPStore(scenario: scenario)
            let service = try V2GroupApprovalRecoveryService(stores: ["room-a": store], operatorPrincipal: "recovery-oncall")
            V2VaporGroupApprovalRecoveryRoutes(authenticator: try .init(base64EncodedBearerToken: token), service: service).register(on: app)
            let input = V2GroupApprovalRecoveryHTTPRequest(operationID: UUID(), shardID: scenario == "unknown" ? "unknown" : "room-a", ownerEpoch: scenario == "malformed" ? -1 : 3, roomID: UUID(), requestID: UUID(), reviewerUserID: UUID(), decisionOperationID: UUID(), reason: .dependencyRecovered)
            let listing = scenario == "candidates" || scenario == "limit"
            let expected: HTTPStatus = ["ok": .ok, "unauthenticated": .unauthorized, "malformed": .badRequest, "unknown": .notFound, "conflict": .conflict, "owner": .conflict, "database": .serviceUnavailable, "candidates": .ok, "limit": .badRequest][scenario]!
            try await app.testing().test(.POST, "internal/v2/group-approvals/\(listing ? "candidates" : "recover")",
                headers: ["Authorization": "Bearer \(scenario == "unauthenticated" ? "wrong" : token)"], beforeRequest: {
                    if listing { try $0.content.encode(V2GroupApprovalRecoveryCandidatesHTTPRequest(shardID: "room-a", ownerEpoch: 3, roomID: input.roomID, after: nil, limit: scenario == "limit" ? 101 : 10)) }
                    else { try $0.content.encode(input) }
                }) { response async throws in
                    #expect(response.status == expected)
                    if expected == .ok {
                        #expect(response.headers.first(name: .cacheControl) == "no-store")
                        if !listing {
                            let result = try JSONDecoder().decode(V2GroupApprovalRecoveryResult.self, from: Data(response.body.string.utf8))
                            #expect(result.operationID == input.operationID && result.outcome == .released)
                        }
                    }
                    #expect(!response.body.string.contains("private-recovery-database"))
                }
            #expect(await store.calls == (["unauthenticated", "malformed", "unknown", "limit"].contains(scenario) ? 0 : 1))
            try await app.asyncShutdown()
        } catch { try? await app.asyncShutdown(); throw error }
    }
}
private actor ApprovalRecoveryHTTPStore: V2GroupApprovalRecoveryStore {
    let scenario: String
    private(set) var calls = 0
    init(scenario: String) { self.scenario = scenario }
    func candidates(scope: V2GroupApprovalRecoveryScope, after: UUID?, limit: Int) async throws -> V2GroupApprovalRecoveryPage {
        calls += 1
        #expect(scope.shardID == "room-a" && scope.ownerEpoch == 3 && limit == 10)
        return .init(candidates: [], nextCursor: nil)
    }
    func recover(_ command: V2GroupApprovalRecoveryCommand, operatorPrincipal: String, now: Date) async throws -> V2GroupApprovalRecoveryResult {
        calls += 1
        #expect(operatorPrincipal == "recovery-oncall" && command.scope.shardID == "room-a" && command.scope.ownerEpoch == 3)
        if scenario == "conflict" { throw V2GroupApprovalRecoveryError.idempotencyConflict }
        if scenario == "owner" { throw V2GroupApprovalRecoveryError.ownerChanged }
        if scenario == "database" { throw NSError(domain: "private-recovery-database", code: 1) }
        return .init(operationID: command.operationID, outcome: .released, detail: .noHistoricalAdd, wasIdempotent: false)
    }
}
