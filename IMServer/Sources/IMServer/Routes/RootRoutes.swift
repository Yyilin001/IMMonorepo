import Vapor

struct RootRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("health") { req -> HealthResponse in
            HealthResponse(status: "ok", role: req.application.imRuntimeRole.rawValue)
        }

        routes.get { req async throws -> Response in
            try await req.fileio.asyncStreamFile(
                at: req.application.directory.publicDirectory + "index.html"
            )
        }
    }
}

private struct HealthResponse: Content {
    let status: String
    let role: String
}
