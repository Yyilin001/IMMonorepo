import Vapor

func routes(_ app: Application) throws {
    if app.imRuntimeRole.servesHTTP {
        try app.register(collection: RootRoutes())
        try app.register(collection: HelloController())
        try app.register(collection: InternalMetricsController())
    }

    if app.imRuntimeRole.servesGateway {
        try app.register(collection: AuthController())
        try app.register(collection: GatewayRelayController())
        if app.commandAPIIngressConfiguration.isEnabled {
            try app.register(collection: GatewayCommandBridgeController())
        }
    }

    if app.imRuntimeRole.servesCommandAPI {
        let controller = IMConversationController()
        try controller.registerCommandRoutes(on: app)
        try app.register(collection: InternalMessageCommandController())
        try app.register(collection: UserController())
        try app.register(collection: MediaController())
        try app.register(collection: FileController())
    }

    if app.imRuntimeRole.servesQueryAPI {
        let controller = IMConversationController()
        try controller.registerQueryRoutes(on: app)
    }
}
