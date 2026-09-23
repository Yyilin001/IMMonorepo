import HTTPTypes
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
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let token = Data(repeating: 9, count: 32).base64EncodedString()
        let store = OperatorReplayRouteStore()
        V2VaporDurableWorkOperatorReplayRoutes(
            authenticator: try .init(base64EncodedBearerToken: token),
            service: .init(store: store, roomOwnerStores: ["room-a": store], operatorPrincipal: "oncall-primary")
        ).register(on: app)
        let request = V2DurableWorkReplayHTTPRequest(
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000891")!,
            targetKind: .userStateEvent,
            sourceShardID: "room-a",
            sourceEventID: "00000000-0000-0000-0000-000000000892",
            targetUserID: "00000000-0000-0000-0000-000000000893",
            projectionKind: "membership",
            reason: .dependencyRecovered
        )

        try await app.testing { client in
            let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"], to: "internal/v2/durable-work/replay", beforeSend: { vaporRequest in
            try vaporRequest.content.encode(request)
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[.pragma] == "no-cache")
            var decoded: V2DurableWorkReplayHTTPResponse?
            decoded = try await response.content.decode(V2DurableWorkReplayHTTPResponse.self)
            #expect(decoded?.operationID == request.operationID)
            #expect(decoded?.outcome == .requeued)
            #expect(decoded?.wasIdempotent == false)
        }
        let recorded = try #require(await store.commands().first)
        #expect(recorded.command.operationID == request.operationID)
        #expect(recorded.principal == "oncall-primary")
    }

    @Test("personal replay selects its configured source owner and never falls back to control")
    func sourceOwnerSelection() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let token = Data(repeating: 12, count: 32).base64EncodedString()
        let control = OperatorReplayRouteStore()
        let owner = OperatorReplayRouteStore()
        V2VaporDurableWorkOperatorReplayRoutes(
            authenticator: try .init(base64EncodedBearerToken: token),
            service: .init(store: control, roomOwnerStores: ["room-a": owner], operatorPrincipal: "oncall-primary")
        ).register(on: app)
        for shard in [nil, "unknown", " room-a", "room-a"] as [String?] {
            let single = V2DurableWorkReplayHTTPRequest(operationID: UUID(), targetKind: .userStateEvent,
                sourceShardID: shard, sourceEventID: UUID().uuidString, targetUserID: UUID().uuidString,
                projectionKind: "membership", reason: .dataRepaired)
            try await app.testing { client in
                let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"], to: "internal/v2/durable-work/replay", beforeSend: { request in
                try request.content.encode(single)
            })
                #expect(response.status == (shard == "room-a" ? .ok : .badRequest))
            }
            let batch = V2DurableWorkEventReplayHTTPRequest(operationID: UUID(), targetKind: .userStateEvent,
                sourceShardID: shard, sourceEventID: UUID().uuidString, reason: .dataRepaired, limit: 10)
            try await app.testing { client in
                let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"], to: "internal/v2/durable-work/replay-event", beforeSend: { request in
                try request.content.encode(batch)
            })
                #expect(response.status == (shard == "room-a" ? .ok : .badRequest))
                if shard == "room-a" { #expect(response.headers[.cacheControl] == "no-store") }
            }
        }
        #expect(await owner.commands().count == 1)
        #expect(await owner.events().count == 1)
        #expect(await control.commands().isEmpty)
        #expect(await control.events().isEmpty)
        let invalid = V2DurableWorkReplayHTTPRequest(operationID: UUID(), targetKind: .mediaScan,
            sourceShardID: "room-a", sourceEventID: UUID().uuidString, reason: .dataRepaired)
        try await app.testing { client in
            let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"], to: "internal/v2/durable-work/replay", beforeSend: { request in
            try request.content.encode(invalid)
        })
            #expect(response.status == .badRequest)
        }
        #expect(await control.commands().isEmpty)
        #expect(await owner.commands().count == 1)
    }

    @Test("route refuses absent or invalid bearer credentials before invoking replay")
    func rejectsUnauthenticatedReplay() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let token = Data(repeating: 10, count: 32).base64EncodedString()
        let store = OperatorReplayRouteStore()
        V2VaporDurableWorkOperatorReplayRoutes(
            authenticator: try .init(base64EncodedBearerToken: token),
            service: .init(store: store, roomOwnerStores: ["room-a": store], operatorPrincipal: "oncall-primary")
        ).register(on: app)
        let request = V2DurableWorkReplayHTTPRequest(
            operationID: UUID(),
            targetKind: .mediaScan,
            sourceEventID: "00000000-0000-0000-0000-000000000894",
            reason: .falsePositive
        )

        try await app.testing { client in
            let response = try await client.send(.post, to: "internal/v2/durable-work/replay", beforeSend: { vaporRequest in
            try vaporRequest.content.encode(request)
        })
            #expect(response.status == .unauthorized)
        }
        try await app.testing { client in
            let response = try await client.send(.post, headers: [.authorization: "Bearer wrong"], to: "internal/v2/durable-work/replay", beforeSend: { vaporRequest in
            try vaporRequest.content.encode(request)
        })
            #expect(response.status == .unauthorized)
        }
        #expect(await store.commands().isEmpty)
    }

    @Test("route rejects malformed target shapes without calling replay")
    func rejectsMalformedTarget() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let token = Data(repeating: 11, count: 32).base64EncodedString()
        let store = OperatorReplayRouteStore()
        V2VaporDurableWorkOperatorReplayRoutes(
            authenticator: try .init(base64EncodedBearerToken: token),
            service: .init(store: store, roomOwnerStores: ["room-a": store], operatorPrincipal: "oncall-primary")
        ).register(on: app)
        let malformed = V2DurableWorkReplayHTTPRequest(
            operationID: UUID(),
            targetKind: .userStateEvent,
            sourceShardID: "room-a",
            sourceEventID: "00000000-0000-0000-0000-000000000895",
            reason: .dataRepaired
        )
        try await app.testing { client in
            let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"], to: "internal/v2/durable-work/replay", beforeSend: { vaporRequest in
            try vaporRequest.content.encode(malformed)
        })
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
