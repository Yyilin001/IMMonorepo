import FluentKit
import Foundation
import IMV2ActorContracts
import SQLKit

public enum V2PostgresHostSessionSettlementError: Error, Equatable, Sendable {
    case unsupportedDatabase, observerIsTarget, preparedTransactionsEnabled
    case terminationUnconfirmed, deadlineExceeded
}

/// Database-side cleanup after an exclusion backend has irreversibly stopped
/// the old process and prevented new connections from that incarnation.
/// This API does not certify process exclusion or grant placement authority.
public enum V2PostgresHostSessionSettlement {
    public static func settle(host: V2ActorHostIdentity, database: any Database,
                              deadline: ContinuousClock.Instant) async throws {
        guard !database.inTransaction else {
            throw V2PostgresHostSessionSettlementError.unsupportedDatabase
        }
        let marker = V2ActorPostgresSessionIdentity.applicationName(host)
        try await v2WithOwnerBatchConnection(database: database, deadline: deadline,
            metrics: nil, interrupted: { _ in }) { borrowed, _ in
            guard let sql = borrowed as? any SQLDatabase else {
                throw V2PostgresHostSessionSettlementError.unsupportedDatabase
            }
            guard let settings = try await sql.raw("""
                SELECT current_setting('application_name') AS application_name,
                       current_setting('max_prepared_transactions')::integer AS prepared_transactions
                """).first(decoding: Settings.self) else {
                throw V2PostgresHostSessionSettlementError.unsupportedDatabase
            }
            guard settings.applicationName != marker else {
                throw V2PostgresHostSessionSettlementError.observerIsTarget
            }
            // Two-phase transactions survive backend death and cannot be
            // attributed to an incarnation by application_name. Never certify
            // settlement under a deployment enabling that unsupported mode.
            guard settings.preparedTransactions == 0 else {
                throw V2PostgresHostSessionSettlementError.preparedTransactionsEnabled
            }
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw V2PostgresHostSessionSettlementError.deadlineExceeded
                }
                let sessions = try await sql.raw("""
                    SELECT pid, backend_start::text AS backend_start
                    FROM pg_stat_activity WHERE application_name = \(bind: marker)
                    ORDER BY pid
                    """).all(decoding: Session.self)
                if sessions.isEmpty { return }
                for session in sessions {
                    try Task.checkCancellation()
                    let remaining = ContinuousClock.now.duration(to: deadline).components
                    guard remaining.seconds >= 0 else {
                        throw V2PostgresHostSessionSettlementError.deadlineExceeded
                    }
                    let milliseconds = remaining.seconds > 0 ? 1000
                        : Int(remaining.attoseconds / 1_000_000_000_000_000)
                    guard milliseconds > 0 else {
                        throw V2PostgresHostSessionSettlementError.deadlineExceeded
                    }
                    // Positive timeout awaits actual backend termination.
                    // Recheck the observed incarnation and backend start; a
                    // vanished session requires no signal to its former PID.
                    let result = try await sql.raw("""
                        SELECT pg_terminate_backend(pid, \(bind: milliseconds)::bigint) AS terminated
                        FROM pg_stat_activity
                        WHERE pid = \(bind: session.pid) AND application_name = \(bind: marker)
                          AND backend_start::text = \(bind: session.backendStart)
                        """).first(decoding: Termination.self)
                    if let result, !result.terminated {
                        throw V2PostgresHostSessionSettlementError.terminationUnconfirmed
                    }
                }
                // A fresh autocommit read checks all matching backends again;
                // sending a signal alone is never the success condition.
            }
        }
    }

    private struct Settings: Decodable {
        let applicationName: String
        let preparedTransactions: Int
        enum CodingKeys: String, CodingKey {
            case applicationName = "application_name"
            case preparedTransactions = "prepared_transactions"
        }
    }
    private struct Session: Decodable {
        let pid: Int
        let backendStart: String
        enum CodingKeys: String, CodingKey { case pid; case backendStart = "backend_start" }
    }
    private struct Termination: Decodable { let terminated: Bool }
}
