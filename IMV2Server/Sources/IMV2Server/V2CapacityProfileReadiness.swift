import Fluent
import IMV2Core
import SQLKit

public enum V2CapacityProfileReadinessError: Error, Equatable, Sendable {
    case invalidSchema(String)
    case unsupportedDatabase
    case persistedLimitsMismatch(profileID: String)
}

/// Proves that an already-issued shard admission pool still implements the
/// immutable capacity profile selected by this process.
///
/// Environment variables are only the desired deployment configuration. The
/// authoritative command/fan-out ceilings live in PostgreSQL once a pool is
/// issued. Accepting traffic with the same profile ID but different limits
/// would otherwise defer this deployment error until the old durable window
/// becomes full and starts returning `RATE_LIMITED`.
public enum V2CapacityProfileReadiness {
    public static func verify(
        database: any Database,
        schema: String = "im_v2",
        profile: V2CapacityProfile
    ) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2CapacityProfileReadinessError.unsupportedDatabase
        }
        guard schema.range(
            of: "^[A-Za-z_][A-Za-z0-9_]*$",
            options: .regularExpression
        ) != nil else {
            throw V2CapacityProfileReadinessError.invalidSchema(schema)
        }

        let limits = profile.limits
        let row = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1
                FROM \(unsafeRaw: schema).shard_admission_pools
                WHERE capacity_profile_id = \(bind: profile.id)
                  AND (
                      command_window_limit <> \(bind: limits.maxCommandsPerWindow)
                      OR fanout_window_limit <> \(bind: limits.maxFanoutUnitsPerWindow)
                      OR max_outstanding_fanout_units <>
                          \(bind: limits.maxOutstandingFanoutUnits)
                      OR max_outstanding_plans <> \(bind: limits.maxOutstandingPlans)
                  )
            ) AS exists
            """).first(decoding: CapacityProfileMismatchRow.self)
        guard row?.exists == false else {
            throw V2CapacityProfileReadinessError.persistedLimitsMismatch(
                profileID: profile.id
            )
        }
    }
}

private struct CapacityProfileMismatchRow: Decodable {
    let exists: Bool
}
