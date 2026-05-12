import Foundation
import Vapor

enum IMMigrationStartupPolicy {
    static let environmentKey = "IM_AUTO_MIGRATE_ON_START"

    static func validateStartup(app: Application) throws {
        _ = try shouldAutoMigrate(app: app)
    }

    static func shouldAutoMigrate(app: Application) throws -> Bool {
        let configuredValue = try environmentFlag(named: environmentKey)

        switch app.environment {
        case .production:
            if configuredValue == true, app.imRuntimeRole != .ops {
                throw Abort(
                    .internalServerError,
                    reason: "Production serving and worker roles must not run auto-migration on startup. Use the ops role for migrations."
                )
            }
            return app.imRuntimeRole == .ops && configuredValue == true
        case .development, .testing:
            return configuredValue ?? true
        default:
            return configuredValue ?? false
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
