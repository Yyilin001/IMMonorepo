import Vapor

struct RootRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get { req async throws -> Response in
            try await req.fileio.asyncStreamFile(
                at: req.application.directory.publicDirectory + "index.html"
            )
        }
    }
}
