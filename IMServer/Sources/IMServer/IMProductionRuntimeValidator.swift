import Foundation
import Vapor

enum IMProductionRuntimeValidator {
    static func validateRole(app: Application) throws {
        guard app.environment == .production else {
            return
        }

        switch app.imRuntimeRole {
        case .projectionWorker:
            throw Abort(.internalServerError, reason: "projection-worker is a development/testing fallback only; use stream-consumer in production.")
        case .combined:
            throw Abort(.internalServerError, reason: "combined runtime role is not supported in production.")
        case .gateway, .commandAPI, .queryAPI, .outboxRelay, .streamConsumer, .ops:
            return
        }
    }

    static func validate(app: Application) throws {
        guard app.environment == .production else {
            return
        }

        try validateRole(app: app)

        guard let configuredNodeID = Environment.get("IM_NODE_ID")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configuredNodeID.isEmpty
        else {
            throw Abort(.internalServerError, reason: "Production requires IM_NODE_ID to be explicitly configured.")
        }

        try IMProductionRuntimeValidationSupport.validatePublicBaseURLConfiguration()
        try IMProductionRuntimeValidationSupport.validatePrimaryDatabaseConfiguration()
        try IMProductionRuntimeValidationSupport.validateProductionSecretConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateDevelopmentSeedConfigurationDisabled()
        try app.metricsConfiguration.validateStartup(environment: app.environment)

        switch app.imRuntimeRole {
        case .gateway:
            try IMGatewayProductionValidator.validate(app: app)
        case .commandAPI:
            try IMCommandAPIProductionValidator.validate(app: app)
        case .queryAPI:
            try IMQueryAPIProductionValidator.validate(app: app)
        case .outboxRelay:
            try IMOutboxRelayProductionValidator.validate(app: app)
        case .streamConsumer:
            try IMStreamConsumerProductionValidator.validate(app: app)
        case .ops:
            try IMOpsProductionValidator.validate(app: app)
        case .projectionWorker:
            throw Abort(.internalServerError, reason: "projection-worker is a development/testing fallback only; use stream-consumer in production.")
        case .combined:
            throw Abort(.internalServerError, reason: "combined runtime role is not supported in production.")
        }
    }

}
