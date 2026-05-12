import Foundation
import Vapor

enum InlineOutboxProjectionPolicy {
    static let environmentKey = "IM_INLINE_OUTBOX_PROJECTION"

    static func validateStartup(app: Application) throws {
        if app.environment == .production, try environmentFlag(named: environmentKey) == true {
            throw Abort(
                .internalServerError,
                reason: "Production must not enable IM_INLINE_OUTBOX_PROJECTION; use outbox-relay and stream-consumer."
            )
        }
    }

    static func allowsInlineProjection(app: Application) throws -> Bool {
        try validateStartup(app: app)
        let configuredValue = try environmentFlag(named: environmentKey)

        switch app.environment {
        case .testing:
            return configuredValue ?? true
        case .development:
            return app.imRuntimeRole == .combined && (configuredValue ?? true)
        default:
            return false
        }
    }

    private static func environmentFlag(named key: String) throws -> Bool? {
        guard let rawValue = Environment.get(key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawValue.isEmpty
        else {
            return nil
        }

        switch rawValue {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            throw Abort(.internalServerError, reason: "\(key) must be one of true/false/1/0/yes/no.")
        }
    }
}
