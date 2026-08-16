import Foundation
import IMV2Core
import IMV2Server
import Vapor

public struct V2VaporProfilePresentationRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let presentations: any V2ProfilePresentationManaging
    public init(authenticator: any V2GatewayAuthenticator, presentations: any V2ProfilePresentationManaging) { self.authenticator = authenticator; self.presentations = presentations }

    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "profile-presentations", "contact-aliases") { request async throws -> Response in
            let actor = try await authenticate(request)
            let cursor = try paginationCursor(request)
            let limit = try paginationLimit(request)
            do {
                let page = try await presentations.contactAliases(ownerUserID: actor.userID, afterTargetUserID: cursor, limit: limit)
                return try response(AliasListResponse(values: page.values, nextCursor: page.nextCursor?.rawValue))
            }
            catch { throw map(error) }
        }
        routes.put("v2", "profile-presentations", "contact-aliases", ":target") { request async throws -> Response in
            let actor = try await authenticate(request)
            guard let rawTarget = request.parameters.get("target"), let target = try? UserID(rawTarget) else { throw Abort(.badRequest) }
            let input = try request.content.decode(AliasUpdateRequest.self)
            do {
                let value = try await presentations.updateContactAlias(ownerUserID: actor.userID, targetUserID: target, operationID: try .init(input.operationID), expectedRevision: input.expectedRevision.flatMap(V2ProfileRevision.init(rawValue:)), remarkName: input.remarkName)
                return try response(AliasResponse(value: value))
            } catch { throw map(error) }
        }
        routes.get("v2", "profile-presentations", "groups", ":room", "nicknames") { request async throws -> Response in
            let actor = try await authenticate(request)
            guard let rawRoom = request.parameters.get("room"), let room = try? RoomID(rawRoom) else { throw Abort(.badRequest) }
            let cursor = try paginationCursor(request)
            let limit = try paginationLimit(request)
            do {
                let page = try await presentations.groupNicknames(actorUserID: actor.userID, roomID: room, afterUserID: cursor, limit: limit)
                return try response(NicknameListResponse(values: page.values, nextCursor: page.nextCursor?.rawValue))
            }
            catch { throw map(error) }
        }
        routes.put("v2", "profile-presentations", "groups", ":room", "nickname") { request async throws -> Response in
            let actor = try await authenticate(request)
            guard let rawRoom = request.parameters.get("room"), let room = try? RoomID(rawRoom) else { throw Abort(.badRequest) }
            let input = try request.content.decode(NicknameUpdateRequest.self)
            do {
                let value = try await presentations.updateOwnGroupNickname(actorUserID: actor.userID, roomID: room, operationID: try .init(input.operationID), expectedRevision: input.expectedRevision.flatMap(V2ProfileRevision.init(rawValue:)), nickname: input.nickname)
                return try response(NicknameResponse(value: value))
            } catch { throw map(error) }
        }
    }
    private func paginationCursor(_ request: Request) throws -> UserID? {
        guard let raw = request.query[String.self, at: "cursor"] else { return nil }
        guard raw.utf8.count <= 64, let cursor = try? UserID(raw) else { throw Abort(.badRequest) }
        return cursor
    }
    private func paginationLimit(_ request: Request) throws -> Int {
        let limit = request.query[Int.self, at: "limit"] ?? 200
        guard (1...500).contains(limit) else { throw Abort(.badRequest) }
        return limit
    }
    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection { guard let token = request.headers.bearerAuthorization?.token, let rawDevice = request.headers.first(name: "X-IM-Device-ID"), let deviceID = try? DeviceID(rawDevice) else { throw Abort(.unauthorized) }; do { return .init(userID: try await authenticator.authenticateSession(accessToken: token, deviceID: deviceID).userID, deviceID: deviceID, capabilityProfile: "account-edge") } catch { throw Abort(.unauthorized) } }
    private func map(_ error: Error) -> Abort { guard let error = error as? V2ProfilePresentationError else { return Abort(.serviceUnavailable) }; switch error { case .forbidden: return Abort(.forbidden); case .unavailable: return Abort(.notFound); case .revisionConflict: return Abort(.conflict); case .operationPayloadMismatch, .invalidPresentation: return Abort(.badRequest); case .corruptPersistenceState: return Abort(.serviceUnavailable) } }
    private func response<T: Content>(_ value: T) throws -> Response { let data = try JSONEncoder().encode(value); var headers = HTTPHeaders(); headers.replaceOrAdd(name: .contentType, value: "application/json"); headers.replaceOrAdd(name: .cacheControl, value: "no-store"); headers.replaceOrAdd(name: "Pragma", value: "no-cache"); return .init(status: .ok, headers: headers, body: .init(data: data)) }
}
private struct AliasUpdateRequest: Content { let operationID: String; let expectedRevision: UInt64?; let remarkName: String?; enum CodingKeys: String, CodingKey { case operationID = "operation_id"; case expectedRevision = "expected_revision"; case remarkName = "remark_name" } }
private struct NicknameUpdateRequest: Content { let operationID: String; let expectedRevision: UInt64?; let nickname: String?; enum CodingKeys: String, CodingKey { case operationID = "operation_id"; case expectedRevision = "expected_revision"; case nickname } }
private struct AliasListResponse: Content { let values: [V2ContactAlias]; let nextCursor: String?; enum CodingKeys: String, CodingKey { case values = "aliases"; case nextCursor = "next_cursor" } }
private struct AliasResponse: Content { let value: V2ContactAlias; enum CodingKeys: String, CodingKey { case value = "alias" } }
private struct NicknameListResponse: Content { let values: [V2GroupMemberPresentation]; let nextCursor: String?; enum CodingKeys: String, CodingKey { case values = "nicknames"; case nextCursor = "next_cursor" } }
private struct NicknameResponse: Content { let value: V2GroupMemberPresentation; enum CodingKeys: String, CodingKey { case value = "nickname" } }
