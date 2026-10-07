import Foundation
import FluentKit
import IMV2Core
import SQLKit
import Testing
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("Presence renewal samples database time after actual connection locks and never revives expired rows")
    func liveLeaseUsesLockedDatabaseClockAndConfirmedRemaining() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(), device = UUID(), connection = UUID()
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id,device_id,created_at,last_active_at) VALUES (\(bind:senderUUID),\(bind:device),\(bind:now),\(bind:now))").run()
            let identity = V2AuthenticatedConnection(userID: senderID, deviceID: .init(uuid: device), capabilityProfile: "base")
            let store = try PostgresV2LiveActivityStore(database: database)
            let admitted = try await store.admitConnectionRefresh(identity: identity, connectionID: connection,
                publicationSuppressed: false, policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8),
                now: now.addingTimeInterval(-3_600))
            let remaining = try #require(admitted.remainingLeaseSeconds)
            #expect(remaining > 89 && remaining <= 90.001)
            guard case .accepted(let expiry) = admitted.outcome else { Issue.record("Expected confirmed admission"); return }
            #expect(expiry > now.addingTimeInterval(80)) // Input wall clock is not the authority.
            let gate = LiveLeaseClockGate()
            let holder = Task {
                try await database.transaction { transaction in
                    let locked = try #require(transaction as? any SQLDatabase)
                    let pid = try #require(try await locked.raw("SELECT pg_backend_pid() AS value").first(decoding: LiveLeaseClockPID.self)).value
                    try await locked.raw("UPDATE im_v2.user_live_presence_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE connection_id=\(bind:connection)").run()
                    await gate.enter(pid)
                }
            }
            let pid = await gate.waitEntered()
            let renewal = Task { try await store.renewConnections([.init(identity: identity, connectionID: connection, now: now.addingTimeInterval(-3_600))]) }
            do {
                let limit = ContinuousClock.now + .seconds(2)
                var waiting = false
                while !waiting, ContinuousClock.now < limit {
                    waiting = (try await sql.raw("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND state='active' AND wait_event_type='Lock' AND \(bind:pid)::int=ANY(pg_blocking_pids(pid))) AS value").first(decoding: LiveLeaseClockWait.self))?.value ?? false
                    if !waiting { await Task.yield() }
                }
                #expect(waiting)
                await gate.release(); try await holder.value
                let result = try await renewal.value
                #expect(result[connection]?.outcome == .rejected)
                #expect(result[connection]?.remainingLeaseSeconds == nil)
                let stillExpired = try #require(try await sql.raw("SELECT expires_at < clock_timestamp() AS value FROM im_v2.user_live_presence_leases WHERE connection_id=\(bind:connection)").first(decoding: LiveLeaseClockWait.self))
                #expect(stillExpired.value)
                let replacement = try await store.admitConnectionRefresh(identity: identity, connectionID: UUID(),
                    publicationSuppressed: false, policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8), now: now)
                #expect((replacement.remainingLeaseSeconds ?? 0) > 89)
            } catch { await gate.release(); _ = try? await holder.value; _ = try? await renewal.value; throw error }
        }
    }
}
private struct LiveLeaseClockPID: Decodable { let value: Int }
private struct LiveLeaseClockWait: Decodable { let value: Bool }
private actor LiveLeaseClockGate {
    var pid: Int?, released = false
    var held: CheckedContinuation<Void,Never>?
    var observers: [CheckedContinuation<Int,Never>] = []
    func enter(_ value: Int) async {
        pid = value; for observer in observers { observer.resume(returning: value) }; observers.removeAll()
        if !released { await withCheckedContinuation { held = $0 } }
    }
    func waitEntered() async -> Int { if let pid { return pid }; return await withCheckedContinuation { observers.append($0) } }
    func release() { released = true; held?.resume(); held = nil }
}
