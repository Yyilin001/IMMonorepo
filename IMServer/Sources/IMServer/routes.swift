import Vapor

func routes(_ app: Application) throws {
    if app.imRuntimeRole.servesHTTP {
        try app.register(collection: RootRoutes())
        try app.register(collection: HelloController())
        try app.register(collection: InternalMetricsController())
        try app.register(collection: InternalReportsController())
    }

    if app.imRuntimeRole.servesGateway {
        try app.register(collection: AuthController())
        try app.register(collection: InternalGatewayDrainController())
        try app.register(collection: GatewayRelayController(configuration: app.gatewayRelayConfiguration))
        try app.register(
            collection: InternalCellRealtimeDispatchController(
                maxBodySize: app.gatewayRelayConfiguration.domainEventPacketMaxBodySize
            )
        )
        if app.commandAPIIngressConfiguration.isEnabled {
            try app.register(collection: GatewayCommandBridgeController())
        }
    }

    if app.imRuntimeRole.servesCommandAPI {
        let controller = IMConversationController()
        try controller.registerCommandRoutes(on: app)
        try app.register(collection: InternalMessageCommandController())
        try app.register(collection: InternalConversationMigrationController())
        try app.register(collection: InternalConversationMigrationTransferController())
        try app.register(collection: InternalConversationMigrationVerificationController())
        try app.register(collection: InternalConversationMigrationFinalizeController())
        try app.register(collection: UserController())
        try app.register(collection: MediaController())
        try app.register(collection: FileController())
        if app.adminConfiguration.isEnabled {
            try app.register(collection: AdminController())
        }
    }

    if app.imRuntimeRole.servesQueryAPI {
        let controller = IMConversationController()
        try controller.registerQueryRoutes(on: app)
    }
}
