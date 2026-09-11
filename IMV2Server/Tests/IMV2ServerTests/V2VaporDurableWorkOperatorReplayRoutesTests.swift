import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor durable-work operator replay routes")
struct V2VaporDurableWorkOperatorReplayRoutesTests {
    @Test("authorized operator replay is no-store, single-target, and idempotent")
    func authorizedReplay() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let token = Data(repeating: 9, count: 32).base64EncodedString()
        let store = OperatorReplayRouteStore()
        V2VaporDurableWorkOperatorReplayRoutes(
            authenticator: try .init(base64EncodedBearerToken: token),
            service: .init(store: store, operatorPrincipal: "oncall-primary")
        ).register(on: app)
        let request = V2DurableWorkReplayHTTPRequest(
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000891")!,
            targetKind: .fanoutDelivery,
            sourceEventID: "00000000-0000-0000-0000-000000000892",
            targetUserID: "00000000-0000-0000-0000-000000000893",
            projectionKind: "message_created",
            reason: .dependencyRecovered
        )

        try await app.testing().test(.POST, "internal/v2/durable-work/replay", headers: ["Authorization": "Bearer \(token)"], beforeRequest: { vaporRequest in
            try vaporRequest.content.encode(request)
        }) { response async in
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            #expect(response.headers.first(name: "Pragma") == "no-cache")
            var decoded: V2DurableWorkReplayHTTPResponse?
            expectContent(V2DurableWorkReplayHTTPResponse.self, response) { decoded = $0 }
            #expect(decoded?.operationID == request.operationID)
            #expect(decoded?.outcome == .requeued)
            #expect(decoded?.wasIdempotent == false)
        }
        let recorded = try #require(await store.commands().first)
        #expect(recorded.command.operationID == request.operationID)
        #expect(recorded.principal == "oncall-primary")
    }

    @Test("route refuses absent or invalid bearer credentials before invoking replay")
    func rejectsUnauthenticatedReplay() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let token = Data(repeating: 10, count: 32).base64EncodedString()
        let store = OperatorReplayRouteStore()
        V2VaporDurableWorkOperatorReplayRoutes(
            authenticator: try .init(base64EncodedBearerToken: token),
            service: .init(store: store, operatorPrincipal: "oncall-primary")
        ).register(on: app)
        let request = V2DurableWorkReplayHTTPRequest(
            operationID: UUID(),
            targetKind: .roomOutbox,
            sourceEventID: "00000000-0000-0000-0000-000000000894",
            reason: .falsePositive
        )

        try await app.testing().test(.POST, "internal/v2/durable-work/replay", beforeRequest: { vaporRequest in
            try vaporRequest.content.encode(request)
        }) { response async in
            #expect(response.status == .unauthorized)
        }
        try await app.testing().test(.POST, "internal/v2/durable-work/replay", headers: ["Authorization": "Bearer wrong"], beforeRequest: { vaporRequest in
            try vaporRequest.content.encode(request)
        }) { response async in
            #expect(response.status == .unauthorized)
        }
        #expect(await store.commands().isEmpty)
    }

    @Test("route rejects malformed target shapes without calling replay")
    func rejectsMalformedTarget() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let token = Data(repeating: 11, count: 32).base64EncodedString()
        let store = OperatorReplayRouteStore()
        V2VaporDurableWorkOperatorReplayRoutes(
            authenticator: try .init(base64EncodedBearerToken: token),
            service: .init(store: store, operatorPrincipal: "oncall-primary")
        ).register(on: app)
        let malformed = V2DurableWorkReplayHTTPRequest(
            operationID: UUID(),
            targetKind: .fanoutDelivery,
            sourceEventID: "00000000-0000-0000-0000-000000000895",
            reason: .dataRepaired
        )
        try await app.testing().test(.POST, "internal/v2/durable-work/replay", headers: ["Authorization": "Bearer \(token)"], beforeRequest: { vaporRequest in
            try vaporRequest.content.encode(malformed)
        }) { response async in
            #expect(response.status == .badRequest)
        }
        #expect(await store.commands().isEmpty)
    }
}

private actor OperatorReplayRouteStore: V2DurableWorkReplayStore {
    struct Recorded: Sendable {
        let command: V2DurableWorkReplayCommand
        let principal: String
    }

    private var received: [Recorded] = []
    private var batchCommands: [V2DurableWorkEventReplayCommand] = []

    func replay(_ command: V2DurableWorkReplayCommand, operatorPrincipal: String, now _: Date) -> V2DurableWorkReplayResult {
        received.append(.init(command: command, principal: operatorPrincipal))
        return .init(operationID: command.operationID, outcome: .requeued, wasIdempotent: false)
    }

    func commands() -> [Recorded] { received }

    func replayEvent(_ command: V2DurableWorkEventReplayCommand, operatorPrincipal _: String, now _: Date) -> V2DurableWorkEventReplayResult {
        batchCommands.append(command)
        return .init(operationID: command.operationID, requeued: 1, notPaused: 0, hasMore: false)
    }

    func events() -> [V2DurableWorkEventReplayCommand] { batchCommands }
}
