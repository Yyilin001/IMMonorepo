import Foundation
import NIOCore
import Vapor

/// Accepts an already-authorized realtime packet from another Cell. The target
/// only writes to its local Gateway registry; it never routes the envelope a
/// second time.
struct InternalCellRealtimeDispatchController: RouteCollection {
    private static let internalSecretHeader = "X-IM-Internal-Secret"
    private let maxBodySize: ByteCount

    init(maxBodySize: ByteCount = ByteCount(value: IMGatewayRelayConfiguration.defaultDomainEventPacketMaxBodyBytes)) {
        self.maxBodySize = maxBodySize
    }

    func boot(routes: any RoutesBuilder) throws {
        let realtime = routes.grouped("internal", "im", "realtime")
        realtime.on(
            .POST,
            "dispatch",
            body: .collect(maxSize: maxBodySize),
            use: dispatch
        )
        realtime.on(
            .POST,
            "node-dispatch",
            body: .collect(maxSize: maxBodySize),
            use: dispatchToNode
        )
    }

    func dispatch(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(IMCellRealtimeDispatchRequest.self)
        try validate(req: req, body: body)
        await req.application.connectionRoutingService.handleRemoteDispatch(body.envelope)
        return .noContent
    }

    private func validate(req: Request, body: IMCellRealtimeDispatchRequest) throws {
        let expectedSecret = req.application.cellIngressConfiguration.sharedSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expectedSecret, !expectedSecret.isEmpty,
              req.headers.first(name: Self.internalSecretHeader) == expectedSecret
        else {
            throw Abort(.unauthorized, reason: "Invalid remote Cell realtime ingress credential.")
        }
        guard IMRealtimeCellConfiguration.isValid(cellID: body.originCellID),
              body.originCellID != req.application.imRealtimeCellID,
              body.targetCellID == req.application.imRealtimeCellID,
              body.hop == 1
        else {
            throw Abort(.badGateway, reason: "Invalid remote Cell realtime dispatch route.")
        }
        guard body.expiresAtEpochSeconds >= Int(Date().timeIntervalSince1970) else {
            throw Abort(.gatewayTimeout, reason: "Remote Cell realtime dispatch expired before delivery.")
        }
    }

    private func dispatchToNode(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(IMNodeRealtimeDispatchRequest.self)
        try validate(req: req, body: body)
        await req.application.connectionRoutingService.handleRemoteDispatch(body.envelope)
        return .noContent
    }

    private func validate(req: Request, body: IMNodeRealtimeDispatchRequest) throws {
        let expectedSecret = req.application.nodeDispatchConfiguration.sharedSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expectedSecret, !expectedSecret.isEmpty,
              req.headers.first(name: Self.internalSecretHeader) == expectedSecret
        else {
            throw Abort(.unauthorized, reason: "Invalid remote node realtime ingress credential.")
        }
        guard !body.originNodeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.originNodeID != req.application.imNodeID,
              body.targetNodeID == req.application.imNodeID
        else {
            throw Abort(.badGateway, reason: "Invalid remote node realtime dispatch route.")
        }
        guard body.expiresAtEpochSeconds >= Int(Date().timeIntervalSince1970) else {
            throw Abort(.gatewayTimeout, reason: "Remote node realtime dispatch expired before delivery.")
        }
    }
}

struct IMCellRealtimeDispatchRequest: Content, Sendable {
    let originCellID: String
    let targetCellID: String
    let hop: Int
    let expiresAtEpochSeconds: Int
    let envelope: NodeMessageDispatchEnvelope
}

struct IMNodeRealtimeDispatchRequest: Content, Sendable {
    let originNodeID: String
    let targetNodeID: String
    let expiresAtEpochSeconds: Int
    let envelope: NodeMessageDispatchEnvelope
}
