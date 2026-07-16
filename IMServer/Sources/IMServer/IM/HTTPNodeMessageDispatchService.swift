import Foundation
import Vapor

/// Sends a pre-routed realtime envelope directly to a Gateway node. The
/// receiver only writes to its local TCP registry and never looks up routes.
final class HTTPNodeMessageDispatchService: NodeMessageDispatchService, @unchecked Sendable {
    private let configuration: IMNodeDispatchConfiguration
    private var app: Application?

    init(configuration: IMNodeDispatchConfiguration) {
        self.configuration = configuration
    }

    func start(app: Application) async throws {
        guard configuration.mode == .http,
              !configuration.endpointsByNodeID.isEmpty,
              let sharedSecret = configuration.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sharedSecret.isEmpty
        else {
            throw Abort(.internalServerError, reason: "HTTP node dispatch requires endpoints and a shared secret.")
        }
        self.app = app
    }

    func shutdown() async {
        app = nil
    }

    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws {
        guard let app else {
            throw Abort(.serviceUnavailable, reason: "HTTP node dispatch service has not started.")
        }
        guard nodeID != app.imNodeID,
              let baseURL = configuration.endpoint(for: nodeID)
        else {
            throw Abort(.serviceUnavailable, reason: "No realtime dispatch endpoint configured for node \(nodeID).")
        }
        guard let sharedSecret = configuration.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sharedSecret.isEmpty
        else {
            throw Abort(.serviceUnavailable, reason: "HTTP node dispatch requires a shared secret.")
        }

        let body = IMNodeRealtimeDispatchRequest(
            originNodeID: app.imNodeID,
            targetNodeID: nodeID,
            expiresAtEpochSeconds: Int(Date().timeIntervalSince1970) + 15,
            envelope: envelope
        )
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "Content-Type", value: "application/json")
        headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
        let response = try await app.client.post(
            URI(string: "\(baseURL)/internal/im/realtime/node-dispatch"),
            headers: headers
        ) { request in
            try request.content.encode(body)
        }
        guard response.status == .noContent else {
            throw Abort(.badGateway, reason: "Node \(nodeID) rejected realtime dispatch with HTTP \(response.status.code).")
        }
    }
}
