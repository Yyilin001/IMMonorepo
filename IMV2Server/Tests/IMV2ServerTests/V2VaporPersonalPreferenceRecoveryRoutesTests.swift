@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2ActorContracts
import IMV2Core
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@testable import IMV2Server
@testable import IMV2ServerInfrastructure

struct V2VaporPersonalPreferenceRecoveryRoutesTests {
    @Test(arguments: ["pin-baseline", "moderation-baseline"])
    func cancelledBaselineRemainsCancellation(path: String) async throws {
        let app = try await Application(.testing)
        let actor = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
        let observed = RouteCancellationObservation()
        let client = V2RoomRefAdministrationClient(caller: .init(timeout: .seconds(1)) { _, _, _ in
            throw V2RoomCallFailure.notAccepted(.cancelled)
        })
        do {
            app.middleware.use(RouteCancellationObserver(observed: observed))
            V2VaporGroupCapabilityRoutes(authenticator: PreferenceRouteAuthenticator(actor: actor), rooms: client).register(on: app)
            V2VaporMessageModerationRoutes(authenticator: PreferenceRouteAuthenticator(actor: actor), rooms: client).register(on: app)
            try await app.testing { http in
                let response = try await http.send(.get, to: URI(string: "v2/rooms/\(room.rawValue)/messages/\(message.rawValue)/\(path)"), beforeSend: { request in
                    request.headers.bearerAuthorization = .init(token: "token")
                    request.headers[HTTPField.Name("X-IM-Device-ID")!] = UUID().uuidString
                })
                #expect(response.status == .internalServerError)
                #expect(await observed.didObserveCancellation())
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test func routeBindsRoomActorAndReturnsNoStore() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let actor = UserID(uuid: UUID())
        let room = RoomID(uuid: UUID())
        let command = try V2ConversationStateCommand(
            operationID: .init(uuid: UUID()), roomID: room, isPinned: true, isArchived: false, muteUntil: nil,
            expectedRevision: .initial, firstSubmissionDeadlineMilliseconds: 1000)
        let request = try V2PersonalPreferenceRecoveryRequest(
            identity: command.identity(actorUserID: actor), fingerprint: command.fingerprint(actorUserID: actor),
            action: .query)
        let client = V2RoomRefAdministrationClient(
            caller: .init(
                timeout: .seconds(1),
                invoke: { wire, user, _ in
                    guard user == actor, case .administration(.personalPreferenceRecovery(let value)) = wire,
                        value.request == request
                    else { throw V2RoomCallFailure.outcomeUnknown }
                    return .administration(.personalPreferenceRecovery(.unresolved))
                }))
        V2VaporPersonalPreferenceRecoveryRoutes(
            authenticator: PreferenceRouteAuthenticator(actor: actor), administration: client
        ).register(on: app)
        try await app.testing { http in
            let response = try await http.send(
                .post, to: URI(string: "v2/rooms/\(room.rawValue)/personal-preferences/operations/recover"),
                beforeSend: { value in
                    value.headers.bearerAuthorization = .init(token: "token")
                    value.headers[HTTPField.Name("X-IM-Device-ID")!] = UUID().uuidString
                    try value.content.encode(request, using: JSONEncoder())
                })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(try await response.content.decode(V2PersonalPreferenceRecoveryResult.self) == .unresolved)
            let wrong = try await http.send(
                .post, to: URI(string: "v2/rooms/\(UUID().uuidString)/personal-preferences/operations/recover"),
                beforeSend: { value in
                    value.headers.bearerAuthorization = .init(token: "token")
                    value.headers[HTTPField.Name("X-IM-Device-ID")!] = UUID().uuidString
                    try value.content.encode(request, using: JSONEncoder())
                })
            #expect(wrong.status == .badRequest)
            #expect(wrong.headers[.cacheControl] == "no-store")
        }
    }
}
private struct PreferenceRouteAuthenticator: V2GatewayAuthenticator {
    let actor: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        .init(userID: actor, expiresAt: nil)
    }
}

private actor RouteCancellationObservation {
    private var observed = false
    func record() { observed = true }
    func didObserveCancellation() -> Bool { observed }
}
private struct RouteCancellationObserver: Middleware, Sendable {
    let observed: RouteCancellationObservation
    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        do { return try await next.respond(to: request) }
        catch is CancellationError { await observed.record(); throw CancellationError() }
    }
}
