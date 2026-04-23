import Vapor

struct HelloController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let hello = routes.grouped("hello")
        hello.get(use: helloWorld)
        hello.get("greet", ":name", use: greet)
        hello.get("info", use: info)
        hello.get("query", use: queryGreeting)
    }

    func helloWorld(req: Request) async throws -> String {
        "Hello, world!"
    }

    func greet(req: Request) async throws -> String {
        guard let name = req.parameters.get("name"), !name.isEmpty else {
            throw Abort(.badRequest, reason: "Missing route parameter: name")
        }

        return "Hello, \(name)!"
    }

    func info(req: Request) async throws -> HelloInfoResponse {
        HelloInfoResponse(
            message: "Hello from Vapor",
            availableRoutes: [
                "/hello",
                "/hello/greet/:name",
                "/hello/info",
                "/hello/query?name=YourName"
            ]
        )
    }

    func queryGreeting(req: Request) async throws -> GreetingResponse {
        let query = try req.query.decode(GreetingQuery.self)
        let displayName = (query.name?.isEmpty == false) ? query.name! : "Guest"
        return GreetingResponse(greeting: "Hello, \(displayName)!")
    }
}

struct HelloInfoResponse: Content {
    let message: String
    let availableRoutes: [String]
}

struct GreetingQuery: Content {
    let name: String?
}

struct GreetingResponse: Content {
    let greeting: String
}
