import Foundation
import SQLKit

/// Worker fault-injection tests start with a durable security event. Ordinary
/// display-name mutations deliberately cannot create these jobs.
func seedProfileSecurityInvalidation(on sql: any SQLDatabase, event: UUID, user: UUID, now: Date) async throws {
    try await sql.raw("""
        INSERT INTO im_v2.profile_security_invalidation_outbox
            (source_event_id, source_user_id, revision, profile_state, profile_updated_at, created_at)
        SELECT \(bind: event), user_id, revision, 'hidden', \(bind: now), \(bind: now)
        FROM im_v2.public_user_profiles WHERE user_id = \(bind: user)
        """).run()
}
