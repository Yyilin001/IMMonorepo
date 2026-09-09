import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// Version metadata only; provider material is never returned by the edge.
public struct V2PushIntentEpochHTTPResponse: Content, Sendable {
    public let epoch: UInt64
}

public struct V2PushIntentClaimHTTPRequest: Content, Sendable {
    public let requestID: UUID
    public let expectedEpoch: UInt64
}

public struct V2PushIntentHTTPRequest: Content, Sendable {
    public let epoch: UInt64
    public let revision: UInt64
    public let enabled: Bool
    public let provider: V2PushEndpointProvider?
    public let environment: V2PushEndpointEnvironment?
    public let token: String?
}

/// Required conditional storage dependency. No fallback to legacy writes.
public struct V2VaporPushIntentRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let store: any V2PushEndpointIntentStoring
    private let now: @Sendable () -> Date

    public init(authenticator: any V2GatewayAuthenticator, store: any V2PushEndpointIntentStoring, now: @escaping @Sendable () -> Date = Date.init) {
        self.authenticator = authenticator
        self.store = store
        self.now = now
    }

    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "push-endpoint", "session") { request async -> Response in
            await respond {
                let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
                let epoch = try await store.intentEpoch(actorUserID: identity.userID, deviceID: identity.deviceID)
                return try epochResponse(epoch)
            }
        }
        routes.post("v2", "push-endpoint", "session") { request async -> Response in
            await respond {
                let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
                let body = try request.content.decode(V2PushIntentClaimHTTPRequest.self)
                let claim = try V2PushIntentSessionClaim(requestID: body.requestID, expectedEpoch: body.expectedEpoch)
                let epoch = try await store.claimIntentSession(actorUserID: identity.userID, deviceID: identity.deviceID, claim: claim, now: now())
                return try epochResponse(epoch)
            }
        }
        routes.put("v2", "push-endpoint", "intent") { request async -> Response in
            await respond {
                let identity = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
                let body = try request.content.decode(V2PushIntentHTTPRequest.self)
                let version = try V2PushIntentVersion(epoch: body.epoch, revision: body.revision)
                let intent: V2PushEndpointIntent
                if body.enabled {
                    guard let provider = body.provider, let environment = body.environment, let token = body.token else { throw V2PushDeviceEndpointError.invalidRegistration }
                    intent = .enabled(try .init(provider: provider, environment: environment, token: token))
                } else {
                    guard body.provider == nil, body.environment == nil, body.token == nil else { throw V2PushDeviceEndpointError.invalidRegistration }
                    intent = .disabled
                }
                try await store.publishIntent(actorUserID: identity.userID, deviceID: identity.deviceID, version: version, intent: intent, now: now())
                return Response(status: .noContent)
            }
        }
    }

    private func epochResponse(_ epoch: UInt64) throws -> Response {
        let response = Response(status: .ok)
        try response.content.encode(V2PushIntentEpochHTTPResponse(epoch: epoch))
        return response
    }

    private func respond(_ operation: () async throws -> Response) async -> Response {
        let response: Response
        do { response = try await operation() }
        catch { response = v2PushIntentErrorResponse(error) }
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return response
    }
}

/// Fixed diagnostic codes; never serialize thrown descriptions or request data.
func v2PushIntentErrorResponse(_ error: any Error) -> Response {
    let status: HTTPResponseStatus
    let code: String
    switch error {
    case V2PushDeviceEndpointError.staleIntent: status = .conflict; code = "stale_intent"
    case V2PushDeviceEndpointError.intentConflict: status = .conflict; code = "intent_conflict"
    case V2PushDeviceEndpointError.intentVersionRequired: status = .preconditionRequired; code = "intent_version_required"
    case V2PushDeviceEndpointError.invalidRegistration, is V2PushIntentVersionError, is DecodingError:
        status = .badRequest; code = "invalid_request"
    case V2PushDeviceEndpointError.deviceUnavailable: status = .forbidden; code = "device_unavailable"
    case let abort as any AbortError where [400, 401, 403, 413, 415].contains(abort.status.code):
        status = abort.status; code = "request_rejected"
    default: status = .serviceUnavailable; code = "unavailable"
    }
    return Response(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store", "Pragma": "no-cache"], body: .init(string: "{\"code\":\"\(code)\"}"))
}
