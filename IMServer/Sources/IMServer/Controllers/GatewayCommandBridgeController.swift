import Foundation
import NIOCore
import Vapor

struct GatewayCommandBridgeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped("api", "im")
            .grouped(
                AccessTokenAuthenticator(),
                User.guardMiddleware(throwing: Abort(.unauthorized, reason: "用户未登录。"))
            )

        IMConversationCommandRoute.registerProxyRoutes(on: protected, use: proxyCommand)
    }

    private func proxyCommand(req: Request) async throws -> Response {
        let configuration = req.application.commandAPIIngressConfiguration
        guard let baseURL = configuration.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !baseURL.isEmpty
        else {
            throw Abort(.serviceUnavailable, reason: "Command API ingress bridge is not configured.")
        }

        let querySuffix = req.url.query.map { "?\($0)" } ?? ""
        let target = URI(string: "\(baseURL)\(req.url.path)\(querySuffix)")
        let proxied = try await req.application.client.send(req.method, headers: Self.forwardedHeaders(from: req, sharedSecret: configuration.sharedSecret), to: target) { outgoing in
            if let bodyData = req.body.data {
                outgoing.body = .init(buffer: bodyData)
            }
        }

        let response = Response(
            status: proxied.status,
            headers: proxied.headers,
            body: proxied.body.map { Response.Body(data: Data(buffer: $0)) } ?? .empty
        )
        return response
    }

    static func forwardedHeaders(from req: Request, sharedSecret: String?) -> HTTPHeaders {
        var headers = HTTPHeaders()
        if let authorization = req.headers.first(name: .authorization) {
            headers.replaceOrAdd(name: .authorization, value: authorization)
        }
        if let contentType = req.headers.first(name: .contentType) {
            headers.replaceOrAdd(name: .contentType, value: contentType)
        }
        if let accept = req.headers.first(name: .accept) {
            headers.replaceOrAdd(name: .accept, value: accept)
        }
        if let sharedSecret, !sharedSecret.isEmpty {
            headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
        }
        return headers
    }
}
