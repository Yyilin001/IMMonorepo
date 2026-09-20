#if os(macOS)
import Foundation
import Darwin
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

private final class RoomRecoveryCrashBundleMarker: NSObject {}

@Suite("Room recovery transaction process crash", .serialized, .timeLimit(.minutes(2)))
struct V2RoomRecoveryCrashTests {
    // Keep the complete matrix as the default; allow focused revalidation of
    // changed transaction paths without reporting unexecuted cases as passed.
    static var selectedTransactions: [String] {
        let all = ["body", "directory", "recovery", "state", "summary", "removal", "snapshot", "snapshotNonempty", "snapshotPage", "snapshotImport", "snapshotPrepare", "resetBegin", "resetCancel", "enqueue", "retryWork", "restartDirectory", "unavailable", "enqueueSummary", "ensureSummary", "ensurePendingSummary", "finishWork", "beginScan", "replaceScan", "emptyDirectory", "finalDirectory", "personalGrant", "mergeTarget", "ensureFreshSummary", "enqueueExistingSummary", "summaryWithoutWork", "snapshotCleanup", "memberRemoval"]
        guard let selection = ProcessInfo.processInfo.environment["IMV2_CLIENT_CRASH_TRANSACTIONS"] else { return all }
        let selected = selection.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        precondition(!selected.isEmpty && Set(selected).count == selected.count && selected.allSatisfy(all.contains),
            "IMV2_CLIENT_CRASH_TRANSACTIONS must name distinct supported transactions")
        return selected
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_CLIENT_CRASH_BINARY"] != nil
        && ProcessInfo.processInfo.environment["IMV2_CLIENT_CRASH_STAGE"] == nil), arguments: ["before", "after"], selectedTransactions)
    func killedCommitRecoversAtomically(stage: String, transaction: String) async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["IMV2_CLIENT_CRASH_BINARY"])
        let currentBinary = try #require(Bundle(for: RoomRecoveryCrashBundleMarker.self).executableURL)
        try #require(URL(fileURLWithPath: binary).resolvingSymlinksInPath() == currentBinary.resolvingSymlinksInPath(),
            "Crash child must use the currently loaded test bundle; rebuild and update IMV2_CLIENT_CRASH_BINARY")

        let directory = FileManager.default.temporaryDirectory.appending(path: "room-crash-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        // macOS xctest products are loadable bundles; use the current SwiftPM host.
        let host = URL(fileURLWithPath: CommandLine.arguments[0])
        #expect(host.lastPathComponent == "swiftpm-testing-helper")
        process.executableURL = host
        process.arguments = ["--test-bundle-path", binary, binary,
            "--testing-library", "swift-testing", "--filter", "crashChild"]
        var environment = ProcessInfo.processInfo.environment
        environment["IMV2_CLIENT_CRASH_STAGE"] = stage
        environment["IMV2_CLIENT_CRASH_TRANSACTION"] = transaction
        environment["IMV2_CLIENT_CRASH_DATABASE"] = directory.appending(path: "client.sqlite").path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        let store = try Self.store(path: directory.appending(path: "client.sqlite").path)
        if transaction == "memberRemoval" {
            let state = try await store.databasePool.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_member_effects"),
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_group_member_roles"))
            }
            #expect(state.0 == (stage == "before" ? 1 : 2))
            #expect(state.1 == (stage == "before" ? 1 : 0))
            #expect(try await store.groupEventCursor(roomID: Self.room) == (stage == "before" ? 1 : 2))
            _ = try await store.applyGroupEventPage(Self.memberPage(removing: true))
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_member_effects") } == 2)
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_member_roles") } == 0)
            #expect(try await store.groupEventCursor(roomID: Self.room) == 2)
            try await store.close()
            return
        }
        if transaction == "snapshotCleanup" {
            let retired = try await store.databasePool.read {
                try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name GLOB 'v2_snapshot_retired_*' ORDER BY name")
            }
            #expect(retired.isEmpty == (stage == "after"))
            #expect(try await store.messages(in: Self.room).map(\.text) == ["snapshot-body"])
            let cursor = try #require(await store.cursor())
            #expect(cursor.state == .ready && cursor.appliedSequence == 10 && cursor.serverAcknowledgedSequence == 10)
            try await store.cleanupRetiredSnapshotTables()
            try await store.cleanupRetiredSnapshotTables()
            let remaining = try await store.databasePool.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name GLOB 'v2_snapshot_retired_*'")
            }
            #expect(remaining == 0)
            #expect(try await store.messages(in: Self.room).map(\.text) == ["snapshot-body"])
            #expect(try await store.cursor() == cursor)
            try await store.databasePool.close()
            return
        }
        if transaction == "mergeTarget" {
            let persisted = try await store.databasePool.read { db in
                (try Int.fetchOne(db, sql: "SELECT target_head FROM v2_room_recovery_work"),
                 try Int.fetchOne(db, sql: "SELECT priority FROM v2_room_recovery_work"),
                 try String.fetchOne(db, sql: "SELECT request_revision FROM v2_room_recovery_work"),
                 try Double.fetchOne(db, sql: "SELECT next_attempt_at FROM v2_room_recovery_work"))
            }
            #expect(persisted.0 == (stage == "before" ? 1 : 7))
            #expect(persisted.1 == 2)
            #expect((persisted.2 == "00000000-0000-0000-0000-000000000036") == (stage == "before"))
            #expect(persisted.3 == (stage == "before" ? 2000 : 1000))
            let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
            let old = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true,
                now: Date(timeIntervalSince1970: 3000)).first)
            try await store.enqueueRoomRecovery(roomID: Self.room, targetHead: 9, priority: 1, scope: scope,
                now: Date(timeIntervalSince1970: 1000))
            try await store.retryRoomRecoveryWork(old, at: Date(timeIntervalSince1970: 4000))
            let ready = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true,
                now: Date(timeIntervalSince1970: 1000))
            #expect(ready.count == 1 && ready.first?.targetHead == 9 && ready.first?.priority == 2)
            #expect(ready.first?.requestRevision != old.requestRevision)
            #expect(try await store.groupEventCursor(roomID: Self.room) == 0)
            try await store.databasePool.close()
            return
        }
        if transaction == "personalGrant" {
            let persisted = try await store.databasePool.read { db in
                (try Bool.fetchOne(db, sql: "SELECT is_member FROM v2_room_membership_states"),
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_recovery_work"),
                 try Int.fetchOne(db, sql: "SELECT applied_sequence FROM v2_sync_cursor"))
            }
            #expect(persisted.0 == (stage == "before" ? nil : true))
            #expect(persisted.1 == (stage == "before" ? 0 : 1))
            #expect(persisted.2 == (stage == "before" ? 0 : 1))
            #expect(try await store.groupEventCursor(roomID: Self.room) == 0)
            let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
            _ = try await store.apply(Self.grant())
            let work = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now)
            #expect(work.count == 1 && work.first?.requiresState == true && work.first?.requiresSummary == true)
            #expect(try await store.groupEventAccess(roomID: Self.room)?.isAuthorized == true)
            #expect(try await store.messages(in: Self.room).isEmpty)
            _ = try await store.apply(Self.grant())
            let replay = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now)
            #expect(replay.first?.requestRevision == work.first?.requestRevision)
            try await store.databasePool.close()
            return
        }
        if transaction == "emptyDirectory" || transaction == "finalDirectory" {
            let persisted = try await store.databasePool.read { db in
                (try String.fetchOne(db, sql: "SELECT scan_id FROM v2_room_recovery_scan"),
                 try String.fetchOne(db, sql: "SELECT cursor FROM v2_room_recovery_scan"),
                 try Bool.fetchOne(db, sql: "SELECT directory_complete FROM v2_room_recovery_scan"),
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_recovery_work"))
            }
            let scanID = try #require(persisted.0)
            let scope = V2RoomRecoveryScope(scanID: try #require(UUID(uuidString: scanID)),
                userID: Self.user, installationBinding: "00000000-0000-0000-0000-000000000012")
            let final = transaction == "finalDirectory"
            #expect(persisted.1 == (stage == "before" ? "next-page" : final ? nil : "after-empty"))
            #expect(persisted.2 == (stage == "after" && final))
            #expect(persisted.3 == (stage == "after" && final ? 2 : 1))
            if stage == "before" {
                try await store.commitRoomRecoveryDirectoryPage(Self.followingDirectoryPage(final: final),
                    expectedCursor: "next-page", request: try await store.roomRecoveryScan(scope: scope), now: .now)
            }
            let scan = try await store.roomRecoveryScan(scope: scope)
            #expect(scan.directoryComplete == final)
            #expect(scan.cursor == (final ? nil : "after-empty"))
            await #expect(throws: V2RoomRecoveryPersistenceError.stalePage) {
                try await store.commitRoomRecoveryDirectoryPage(Self.followingDirectoryPage(final: final),
                    expectedCursor: "next-page", request: try await store.roomRecoveryScan(scope: scope), now: .now)
            }
            let fresh = try await store.beginRoomRecoveryScan(userID: Self.user)
            #expect(try await store.roomRecoveryWork(scope: fresh, limit: 10, oldestFirst: true, now: .now).count == (final ? 2 : 1))
            #expect(try await store.groupEventCursor(roomID: Self.room) == 0)
            try await store.databasePool.close()
            return
        }
        if transaction == "beginScan" || transaction == "replaceScan" {
            let persisted = try await store.databasePool.read { db in
                (try String.fetchOne(db, sql: "SELECT scan_id FROM v2_room_recovery_scan"),
                 try String.fetchOne(db, sql: "SELECT cursor FROM v2_room_recovery_scan"),
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_recovery_work"))
            }
            let old = V2RoomRecoveryScope(scanID: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!,
                userID: Self.user, installationBinding: "00000000-0000-0000-0000-000000000012")
            if transaction == "beginScan" {
                #expect((persisted.0 != nil) == (stage == "after"))
                #expect(persisted.2 == 0)
            } else {
                #expect((persisted.0 == old.scanID.uuidString) == (stage == "before"))
                #expect(persisted.1 == (stage == "before" ? "next-page" : nil))
                #expect(persisted.2 == 1)
                if stage == "before" {
                    #expect(try await store.roomRecoveryScan(scope: old).cursor == "next-page")
                } else {
                    await #expect(throws: V2RoomRecoveryPersistenceError.staleScope) {
                        try await store.roomRecoveryScan(scope: old)
                    }
                }
            }
            let fresh = try await store.beginRoomRecoveryScan(userID: Self.user)
            #expect(try await store.roomRecoveryScan(scope: fresh).cursor == nil)
            #expect(try await store.roomRecoveryWork(scope: fresh, limit: 1, oldestFirst: true, now: .now).count
                == (transaction == "replaceScan" ? 1 : 0))
            await #expect(throws: V2RoomRecoveryPersistenceError.staleScope) {
                try await store.enqueueRoomRecovery(roomID: Self.room, targetHead: 99, priority: 1, scope: old, now: .now)
            }
            #expect(try await store.groupEventCursor(roomID: Self.room) == 0)
            try await store.databasePool.close()
            return
        }
        if transaction == "finishWork" {
            let count = try await store.databasePool.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work")
            }
            #expect(count == (stage == "before" ? 1 : 0))
            #expect(try await store.groupEventCursor(roomID: Self.room) == 1)
            #expect(try await store.messages(in: Self.room).map(\.text) == ["crash-boundary"])
            let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
            if stage == "before" {
                let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1,
                    oldestFirst: true, now: .now).first)
                #expect(try await store.finishRoomRecoveryWork(work))
                #expect(try await store.finishRoomRecoveryWork(work) == false)
            }
            #expect(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).isEmpty)
            #expect(try await store.groupEventCursor(roomID: Self.room) == 1)
            try await store.databasePool.close()
            return
        }
        if ["enqueueSummary", "ensureSummary", "ensurePendingSummary", "ensureFreshSummary", "enqueueExistingSummary"].contains(transaction) {
            let row = try await store.databasePool.read { db -> (targetHead: Int, requiresSummary: Bool, priority: Int, nextAttemptAt: Double, requestRevision: String)? in
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_room_recovery_work") else { return nil }
                return (row["target_head"], row["requires_summary"], row["priority"], row["next_attempt_at"], row["request_revision"])
            }
            let hasPriorBodyTask = transaction == "ensureSummary" || transaction == "enqueueExistingSummary"
            if ["enqueueSummary", "ensureFreshSummary"].contains(transaction), stage == "before" {
                #expect(row == nil)
            } else {
                let row = try #require(row)
                #expect(row.targetHead == (hasPriorBodyTask ? 7 : 0))
                #expect(row.requiresSummary == (!hasPriorBodyTask || stage == "after"))
                #expect(row.priority == (stage == "before" ? 1 : 2))
                if transaction == "ensurePendingSummary" {
                    #expect(row.nextAttemptAt == 2000)
                    #expect(row.requestRevision == "00000000-0000-0000-0000-000000000032")
                }
            }
            let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
            try await store.ensureRoomLatestVisible(roomID: Self.room, scope: scope, now: Date(timeIntervalSince1970: 1000))
            if transaction == "ensurePendingSummary" {
                #expect(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true,
                    now: Date(timeIntervalSince1970: 1500)).isEmpty)
            }
            let ready = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true,
                now: Date(timeIntervalSince1970: 2001))
            #expect(ready.count == 1 && ready.first?.requiresSummary == true)
            #expect(try await store.groupEventCursor(roomID: Self.room) == 0)
            try await store.databasePool.close()
            return
        }
        if transaction == "restartDirectory" {
            let persisted = try await store.databasePool.read { db in
                (try String.fetchOne(db, sql: "SELECT cursor FROM v2_room_recovery_scan"),
                 try String.fetchOne(db, sql: "SELECT topology_generation FROM v2_room_recovery_scan"),
                 try String.fetchOne(db, sql: "SELECT directory_round FROM v2_room_recovery_scan"),
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_recovery_work"))
            }
            #expect(persisted.0 == (stage == "before" ? "next-page" : nil))
            #expect(persisted.1 == (stage == "before" ? "crash-topology" : nil))
            #expect((persisted.2 == "00000000-0000-0000-0000-000000000031") == (stage == "before"))
            #expect(persisted.3 == 1)
            let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
            try await store.restartRoomRecoveryDirectory(scope: scope)
            #expect(try await store.roomRecoveryScan(scope: scope).cursor == nil)
            #expect(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).count == 1)
            #expect(try await store.groupEventCursor(roomID: Self.room) == 0)
            try await store.databasePool.close()
            return
        }
        if transaction == "unavailable" {
            let persisted = try await store.databasePool.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_recovery_work"),
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_sync_states"))
            }
            #expect(persisted.0 == (stage == "before" ? 1 : 0))
            #expect(persisted.1 == (stage == "before" ? 1 : 0))
            #expect(try await store.groupEventAccess(roomID: Self.room)?.isAuthorized == (stage == "before"))
            let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
            if stage == "before" {
                let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
                #expect(try await store.commitRoomRecoveryUnavailable(work))
            }
            #expect(try await store.groupEventAccess(roomID: Self.room)?.isAuthorized == false)
            #expect(try await store.groupEventCursor(roomID: Self.room) == 1)
            try await store.databasePool.close()
            return
        }
        if transaction == "enqueue" || transaction == "retryWork" {
            let persisted = try await store.databasePool.read { db in
                (try Int.fetchOne(db, sql: "SELECT target_head FROM v2_room_recovery_work"),
                 try Double.fetchOne(db, sql: "SELECT next_attempt_at FROM v2_room_recovery_work"),
                 try Int.fetchOne(db, sql: "SELECT last_served_order FROM v2_room_recovery_work"),
                 try Int.fetchOne(db, sql: "SELECT service_sequence FROM v2_room_recovery_scan"))
            }
            if transaction == "enqueue" {
                #expect(persisted.0 == (stage == "before" ? nil : 7))
                #expect(persisted.1 == (stage == "before" ? nil : 1000))
            } else {
                #expect(persisted.0 == 1)
                #expect(persisted.1 == (stage == "before" ? 1000 : 2000))
                #expect(persisted.2 == (stage == "before" ? 0 : 1))
                #expect(persisted.3 == (stage == "before" ? 0 : 1))
            }
            #expect(try await store.groupEventCursor(roomID: Self.room) == 0)
            let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
            if transaction == "retryWork" {
                let ready = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true,
                    now: Date(timeIntervalSince1970: 1200))
                #expect(ready.count == (stage == "before" ? 1 : 0))
                if let work = ready.first {
                    try await store.retryRoomRecoveryWork(work, at: Date(timeIntervalSince1970: 2000))
                }
                #expect(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true,
                    now: Date(timeIntervalSince1970: 2001)).count == 1)
            } else {
                // Replaying the same target after either crash boundary is safe.
                try await store.enqueueRoomRecovery(roomID: Self.room, targetHead: 7, priority: 1,
                    scope: scope, now: Date(timeIntervalSince1970: 1000))
                let ready = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true,
                    now: Date(timeIntervalSince1970: 1000))
                #expect(ready.count == 1 && ready.first?.targetHead == 7)
            }
            #expect(try await store.groupEventCursor(roomID: Self.room) == 0)
            try await store.databasePool.close()
            return
        }
        if ["resetBegin", "resetCancel"].contains(transaction) {
            let reset = try Self.snapshot(nonempty: true).manifest.reset
            let pending = (transaction == "resetBegin") == (stage == "after")
            let cursor = try #require(await store.cursor())
            #expect(cursor.state == (pending ? .resetPending : .ready))
            #expect(cursor.generation == (pending ? 2 : 1))
            #expect(cursor.appliedSequence == 0 && cursor.serverAcknowledgedSequence == 0)
            #expect(cursor.pendingReset == (pending ? reset : nil))
            let rollback = try await store.databasePool.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_reset_rollback")
            }
            #expect(rollback == (pending ? 1 : 0))
            #expect(try await store.messages(in: Self.room).map(\.text) == ["crash-boundary"])
            if transaction == "resetCancel" {
                if pending {
                    #expect(try await store.importedSnapshotManifest(for: reset) != nil)
                    try await store.cancelReset(reset)
                } else {
                    let remaining = try await store.databasePool.read {
                        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_snapshot_import")
                    }
                    #expect(remaining == 0)
                }
                #expect(try await store.cursor()?.syncToken == nil)
            } else if pending {
                try await store.cancelReset(reset)
            }
            // A fresh reset must work after recovery, with no orphan rollback row.
            try await store.beginReset(reset)
            try await store.cancelReset(reset)
            #expect(try await store.cursor()?.generation == 1)
            #expect(try await store.messages(in: Self.room).map(\.text) == ["crash-boundary"])
            try await store.databasePool.close()
            return
        }
        if ["snapshotImport", "snapshotPrepare"].contains(transaction) {
            let fixture = try Self.snapshot(nonempty: true)
            #expect(try await store.cursor()?.state == .resetPending)
            #expect(try await store.messages(in: Self.room).map(\.text) == ["crash-boundary"])
            let imported = try await store.importedSnapshotManifest(for: fixture.manifest.reset)
            if transaction == "snapshotImport" {
                #expect(imported == (stage == "before" ? nil : fixture.manifest))
                try await store.beginSnapshotImport(fixture.manifest,
                    initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
                #expect(try await store.nextSnapshotPageIndex(for: fixture.manifest) == 0)
                try await store.applySnapshotPage(#require(fixture.page), for: fixture.manifest)
            } else {
                #expect(imported == fixture.manifest)
                let prepared = try await store.databasePool.read {
                    try Bool.fetchOne($0, sql: "SELECT activation_prepared FROM v2_snapshot_import")
                }
                #expect(prepared == (stage == "after"))
                #expect(try await store.nextSnapshotPageIndex(for: fixture.manifest) == 1)
            }
            // Repeating an already committed setup stage must be safe too.
            try await store.prepareSnapshotActivation(fixture.manifest)
            try await store.activateAcknowledgedSnapshot(fixture.manifest)
            #expect(try await store.messages(in: Self.room).map(\.text) == ["snapshot-body"])
            #expect(try await store.cursor()?.appliedSequence == 10)
            try await store.cleanupRetiredSnapshotTables()
            try await store.databasePool.close()
            return
        }
        if transaction == "snapshotPage" {
            let fixture = try Self.snapshot(nonempty: true)
            let cursor = try #require(await store.cursor())
            #expect(cursor.state == .resetPending && cursor.appliedSequence == 0)
            #expect(try await store.messages(in: Self.room).map(\.text) == ["crash-boundary"])
            #expect(try await store.nextSnapshotPageIndex(for: fixture.manifest) == (stage == "before" ? 0 : 1))
            let progress = try await store.databasePool.read { db in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT rolling_digest, applied_items, applied_bytes FROM v2_snapshot_import"))
                return (row["rolling_digest"] as String, row["applied_items"] as Int64, row["applied_bytes"] as Int64)
            }
            #expect(progress.0 == (stage == "before" ? V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base") : fixture.manifest.rootDigest))
            #expect(progress.1 == (stage == "before" ? 0 : 1))
            #expect(progress.2 == (stage == "before" ? 0 : Int64(fixture.manifest.totalBytes)))
            if stage == "before" {
                try await store.applySnapshotPage(#require(fixture.page), for: fixture.manifest)
            }
            try await store.prepareSnapshotActivation(fixture.manifest)
            try await store.activateAcknowledgedSnapshot(fixture.manifest)
            #expect(try await store.messages(in: Self.room).map(\.text) == ["snapshot-body"])
            #expect(try await store.cursor()?.appliedSequence == 10)
            try await store.cleanupRetiredSnapshotTables()
            try await store.databasePool.close()
            return
        }
        if ["snapshot", "snapshotNonempty"].contains(transaction) {
            let cursor = try #require(await store.cursor())
            #expect(cursor.generation == 2)
            #expect(cursor.state == (stage == "before" ? .resetPending : .ready))
            #expect(cursor.appliedSequence == (stage == "before" ? 0 : 10))
            let messages = try await store.messages(in: Self.room)
            #expect(messages.map(\.text) == (stage == "before" ? ["crash-boundary"] : (transaction == "snapshotNonempty" ? ["snapshot-body"] : [])))
            if stage == "before" {
                try await store.activateAcknowledgedSnapshot(Self.snapshot(nonempty: transaction == "snapshotNonempty").manifest)
            }
            let recovered = try #require(await store.cursor())
            #expect(recovered.state == .ready && recovered.generation == 2)
            #expect(recovered.appliedSequence == 10 && recovered.serverAcknowledgedSequence == 10)
            #expect(try await store.messages(in: Self.room).map(\.text) == (transaction == "snapshotNonempty" ? ["snapshot-body"] : []))
            let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
            #expect(try await store.roomLatestVisible(roomID: Self.room, scope: scope) == nil)
            try await store.cleanupRetiredSnapshotTables()
            try await store.databasePool.close()
            return
        }
        if transaction == "removal" {
            for table in ["v2_room_sync_states", "v2_room_latest_visible", "v2_room_recovery_work"] {
                let count = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") }
                #expect(count == (stage == "before" ? 1 : 0))
            }
            let applied = try await store.databasePool.read {
                try Int.fetchOne($0, sql: "SELECT applied_sequence FROM v2_sync_cursor WHERE singleton = 1")
            }
            #expect(applied == (stage == "before" ? 0 : 1))
            if stage == "before" { _ = try await store.apply(Self.removal()) }
            let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
            let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
            #expect(try await !store.commitRoomLatestVisible(Self.summary(), request: request))
            #expect(try await store.roomSynchronizationState(roomID: Self.room, scope: scope) == nil)
            for table in ["v2_room_sync_states", "v2_room_latest_visible", "v2_room_recovery_work"] {
                let count = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") }
                #expect(count == 0)
            }
            try await store.databasePool.close()
            return
        }
        if transaction == "summary" || transaction == "summaryWithoutWork" {
            let persisted = try await store.databasePool.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_latest_visible"),
                 try Bool.fetchOne(db, sql: "SELECT requires_summary FROM v2_room_recovery_work"))
            }
            #expect(persisted.0 == (stage == "before" ? 0 : 1))
            #expect(persisted.1 == (stage == "before" || transaction == "summaryWithoutWork"))
            #expect(try await store.groupEventCursor(roomID: Self.room) == 0)
            let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
            #expect(try await store.commitRoomLatestVisible(Self.summary(), request: request, work: work))
            let pending = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            #expect(!pending.requiresSummary && pending.targetHead == 1)
            #expect(try await store.roomLatestVisible(roomID: Self.room, scope: scope) == Self.summary())
            #expect(try await store.groupEventCursor(roomID: Self.room) == 0)
            try await store.databasePool.close()
            return
        }
        if transaction == "state" {
            let persisted = try await store.databasePool.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_sync_states"),
                 try Bool.fetchOne(db, sql: "SELECT requires_state FROM v2_room_recovery_work"))
            }
            #expect(persisted.0 == (stage == "before" ? 0 : 1))
            #expect(persisted.1 == (stage == "before"))
            #expect(try await store.groupEventCursor(roomID: Self.room) == 0)
            let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            _ = try await store.commitRoomRecoveryState(.init(roomID: Self.room, ownerEpoch: 1,
                viewerMembershipRevision: 1, head: 1, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0),
                work: work, now: .now)
            let pending = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            #expect(!pending.requiresState && pending.targetHead == 1)
            #expect(try await store.groupEventCursor(roomID: Self.room) == 0)
            try await store.databasePool.close()
            return
        }
        if transaction == "directory" {
            let persisted = try await store.databasePool.read { db in
                (try String.fetchOne(db, sql: "SELECT cursor FROM v2_room_recovery_scan WHERE singleton = 1"),
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_recovery_work"))
            }
            #expect(persisted.0 == (stage == "before" ? nil : "next-page"))
            #expect(persisted.1 == (stage == "before" ? 0 : 1))
            // A new connection restarts directory discovery, retaining committed work.
            let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
            try await store.commitRoomRecoveryDirectoryPage(Self.directoryPage(), expectedCursor: nil,
                request: try await store.roomRecoveryScan(scope: scope), now: .now)
            let scan = try await store.roomRecoveryScan(scope: scope)
            let pending = try await store.roomRecoveryWork(scope: scope, limit: 100, oldestFirst: true, now: .now)
            #expect(scan.cursor == "next-page" && !scan.directoryComplete)
            #expect(pending.count == 1 && pending.first?.roomID == Self.room)
            #expect(pending.first?.requiresState == true && pending.first?.requiresSummary == true)
            try await store.databasePool.close()
            return
        }
        let messages = try await store.messages(in: Self.room)
        let cursor = try await store.groupEventCursor(roomID: Self.room)
        #expect(messages.count == (stage == "before" ? 0 : 1))
        #expect(cursor == (stage == "before" ? 0 : 1))
        if transaction == "recovery" {
            let count = try await store.databasePool.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work")
            }
            #expect(count == (stage == "before" ? 1 : 0))
            if stage == "before" {
                let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
                let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
                _ = try await store.applyRoomRecoveryPage(Self.page(), work: work)
            }
            let remaining = try await store.databasePool.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work")
            }
            #expect(remaining == 0)
        }
        // Retry the exact accepted event after reopening, including committed replay.
        _ = try await store.applyGroupEventPageReportingChanges(Self.page())
        let recovered = try await store.messages(in: Self.room)
        #expect(recovered.count == 1 && recovered.first?.text == "crash-boundary")
        #expect(try await store.groupEventCursor(roomID: Self.room) == 1)
        try await store.databasePool.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_CLIENT_CRASH_STAGE"] != nil))
    func crashChild() async throws {
        let stage = try #require(ProcessInfo.processInfo.environment["IMV2_CLIENT_CRASH_STAGE"])
        let path = try #require(ProcessInfo.processInfo.environment["IMV2_CLIENT_CRASH_DATABASE"])
        let store = try Self.store(path: path)
        let transaction = try #require(ProcessInfo.processInfo.environment["IMV2_CLIENT_CRASH_TRANSACTION"])
        let scope = try await store.beginRoomRecoveryScan(userID: Self.user)
        var bodyWork: V2RoomRecoveryWork?
        if transaction == "memberRemoval" {
            _ = try await store.applyGroupEventPage(Self.memberPage(removing: false))
        }

        if transaction == "mergeTarget" {
            try await store.enqueueRoomRecovery(roomID: Self.room, targetHead: 1, priority: 2, scope: scope,
                now: Date(timeIntervalSince1970: 1000))
            try await store.databasePool.write { try $0.execute(sql: """
                UPDATE v2_room_recovery_work SET next_attempt_at = 2000,
                    request_revision = '00000000-0000-0000-0000-000000000036'
                """) }
        }

        if transaction == "personalGrant" {
            try await store.databasePool.write { try $0.execute(sql: """
                INSERT INTO v2_sync_cursor(singleton,state,generation,applied_sequence,server_acknowledged_sequence,sync_token)
                VALUES(1,'ready',1,0,0,'grant-crash')
                """) }
        }

        if transaction == "emptyDirectory" || transaction == "finalDirectory" {
            try await store.commitRoomRecoveryDirectoryPage(Self.directoryPage(), expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .now)
        }

        if transaction == "beginScan" {
            try await store.databasePool.write { try $0.execute(sql: "DELETE FROM v2_room_recovery_scan") }
        } else if transaction == "replaceScan" {
            try await store.commitRoomRecoveryDirectoryPage(Self.directoryPage(), expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .now)
            try await store.databasePool.write {
                try $0.execute(sql: "UPDATE v2_room_recovery_scan SET scan_id = '00000000-0000-0000-0000-000000000033'")
            }
        }

        if transaction == "finishWork" {
            try await store.enqueueRoomRecovery(roomID: Self.room, targetHead: 1, priority: 1, scope: scope, now: .now)
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            _ = try await store.commitRoomRecoveryState(.init(roomID: Self.room, ownerEpoch: 1,
                viewerMembershipRevision: 1, head: 1, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0),
                work: work, now: .now)
            // Realtime delivery has durably caught up, leaving the scheduler to finish separately.
            _ = try await store.applyGroupEventPageReportingChanges(Self.page())
        }
        if transaction == "ensureSummary" || transaction == "enqueueExistingSummary" {
            try await store.enqueueRoomRecovery(roomID: Self.room, targetHead: 7, priority: 1,
                scope: scope, now: Date(timeIntervalSince1970: 1000))
        }
        if transaction == "ensurePendingSummary" {
            try await store.enqueueRoomLatestVisible(roomID: Self.room, scope: scope, now: Date(timeIntervalSince1970: 1000))
            try await store.databasePool.write { db in
                try db.execute(sql: """
                    UPDATE v2_room_recovery_work SET priority = 1, next_attempt_at = 2000,
                        request_revision = '00000000-0000-0000-0000-000000000032'
                    """)
            }
        }
        if transaction == "restartDirectory" {
            try await store.commitRoomRecoveryDirectoryPage(Self.directoryPage(), expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .now)
            try await store.databasePool.write {
                try $0.execute(sql: "UPDATE v2_room_recovery_scan SET directory_round = '00000000-0000-0000-0000-000000000031'")
            }
        }
        if transaction == "unavailable" {
            try await store.databasePool.write { db in
                try db.execute(sql: """
                    INSERT INTO v2_room_profile_projections
                        (room_id,source_event_id,title,owner_user_id,capacity_class,created_at)
                    VALUES (?,?,'crash-room',?,'standard',1000)
                    """, arguments: [Self.room.rawValue, UUID().uuidString, Self.user.rawValue])
            }
            _ = try await store.applyGroupEventPageReportingChanges(Self.page())
            try await store.enqueueRoomRecovery(roomID: Self.room, targetHead: 2, priority: 1, scope: scope, now: .now)
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            _ = try await store.commitRoomRecoveryState(.init(roomID: Self.room, ownerEpoch: 1,
                viewerMembershipRevision: 1, head: 2, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0),
                work: work, now: .now)
        }
        if transaction == "retryWork" {
            try await store.enqueueRoomRecovery(roomID: Self.room, targetHead: 1, priority: 1,
                scope: scope, now: Date(timeIntervalSince1970: 1000))
        }
        if ["resetBegin", "resetCancel"].contains(transaction) {
            try await store.databasePool.write { try $0.execute(sql: """
                INSERT INTO v2_sync_cursor(singleton,state,generation,applied_sequence,server_acknowledged_sequence,sync_token)
                VALUES(1,'ready',1,0,0,'before-reset')
                """) }
            _ = try await store.applyGroupEventPageReportingChanges(Self.page())
            if transaction == "resetCancel" {
                let fixture = try Self.snapshot(nonempty: true)
                try await store.beginReset(fixture.manifest.reset)
                try await store.beginSnapshotImport(fixture.manifest,
                    initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
                try await store.applySnapshotPage(#require(fixture.page), for: fixture.manifest)
            }
        }
        if ["snapshotPage", "snapshotImport", "snapshotPrepare"].contains(transaction) {
            try await store.databasePool.write { try $0.execute(sql: """
                INSERT INTO v2_sync_cursor(singleton,state,generation,applied_sequence,server_acknowledged_sequence,sync_token)
                VALUES(1,'ready',1,0,0,'page-crash')
                """) }
            _ = try await store.applyGroupEventPageReportingChanges(Self.page())
            let fixture = try Self.snapshot(nonempty: true)
            try await store.beginReset(fixture.manifest.reset)
            if transaction != "snapshotImport" {
                try await store.beginSnapshotImport(fixture.manifest,
                    initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
            }
            if transaction == "snapshotPrepare" {
                try await store.applySnapshotPage(#require(fixture.page), for: fixture.manifest)
            }
        }
        if transaction == "summary" || transaction == "summaryWithoutWork" || transaction == "removal" || ["snapshot", "snapshotNonempty", "snapshotCleanup"].contains(transaction) {
            try await store.databasePool.write { try $0.execute(sql: """
                INSERT INTO v2_sync_cursor(singleton,state,generation,applied_sequence,server_acknowledged_sequence,sync_token)
                VALUES(1,'ready',1,0,0,'summary-crash')
                """) }
            try await store.commitRoomRecoveryDirectoryPage(Self.directoryPage(), expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .now)
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            _ = try await store.commitRoomRecoveryState(.init(roomID: Self.room, ownerEpoch: 1,
                viewerMembershipRevision: 1, head: 1, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0),
                work: work, now: .now)
            if transaction == "removal" || ["snapshot", "snapshotNonempty", "snapshotCleanup"].contains(transaction) {
                let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
                #expect(try await store.commitRoomLatestVisible(Self.summary(), request: request))
            }
            if ["snapshot", "snapshotNonempty", "snapshotCleanup"].contains(transaction) {
                _ = try await store.applyGroupEventPageReportingChanges(Self.page())
                let manifest = try Self.snapshot(nonempty: transaction != "snapshot").manifest
                try await store.beginReset(manifest.reset)
                try await store.beginSnapshotImport(manifest,
                    initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
                if let page = try Self.snapshot(nonempty: transaction != "snapshot").page {
                    try await store.applySnapshotPage(page, for: manifest)
                }
                try await store.prepareSnapshotActivation(manifest)
                if transaction == "snapshotCleanup" { try await store.activateAcknowledgedSnapshot(manifest) }
            }
        }
        if transaction == "state" {
            try await store.enqueueRoomRecovery(roomID: Self.room, targetHead: 1, priority: 1, scope: scope, now: .now)
        }
        if transaction == "recovery" {
            try await store.enqueueRoomRecovery(roomID: Self.room, targetHead: 1, priority: 1, scope: scope, now: .now)
            let initial = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            _ = try await store.commitRoomRecoveryState(.init(roomID: Self.room, ownerEpoch: 1,
                viewerMembershipRevision: 1, head: 1, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0),
                work: initial, now: .now)
            bodyWork = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        }
        if transaction == "snapshotCleanup" {
            // DDL does not provide row-change hooks. Register outside a transaction
            // so the next commit boundary is the production cleanup itself.
            let observer = CrashAtRecoveryCommit(afterCommit: stage == "after", table: "", allTransactions: true)
            try await store.databasePool.writeWithoutTransaction { db in
                db.add(transactionObserver: observer, extent: .databaseLifetime)
            }
            try await store.cleanupRetiredSnapshotTables()
            Issue.record("Cleanup did not reach the crash boundary")
            return
        }
        let table: String
        switch transaction {
        case "ensureFreshSummary", "enqueueExistingSummary", "mergeTarget", "personalGrant", "finishWork", "directory", "enqueue", "retryWork", "unavailable", "enqueueSummary", "ensureSummary", "ensurePendingSummary": table = "v2_room_recovery_work"
        case "emptyDirectory", "finalDirectory", "beginScan", "replaceScan", "restartDirectory": table = "v2_room_recovery_scan"
        case "state": table = "v2_room_sync_states"
        case "summary", "summaryWithoutWork": table = "v2_room_latest_visible"
        case "removal": table = "v2_room_membership_states"
        case "memberRemoval": table = "v2_member_effects"
        case "snapshot", "snapshotNonempty": table = "v2_sync_cursor"
        case "snapshotPage", "snapshotImport", "snapshotPrepare": table = "v2_snapshot_import"
        case "resetBegin", "resetCancel": table = "v2_sync_cursor"
        default: table = "v2_message_projections"
        }
        let observer = CrashAtRecoveryCommit(afterCommit: stage == "after", table: table)
        try await store.databasePool.write { db in db.add(transactionObserver: observer, extent: .databaseLifetime) }
        if transaction == "mergeTarget" {
            try await store.enqueueRoomRecovery(roomID: Self.room, targetHead: 7, priority: 1, scope: scope,
                now: Date(timeIntervalSince1970: 1000))
        } else if transaction == "personalGrant" {
            _ = try await store.apply(Self.grant())
        } else if transaction == "beginScan" || transaction == "replaceScan" {
            _ = try await store.beginRoomRecoveryScan(userID: Self.user)
        } else if transaction == "finishWork" {
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            _ = try await store.finishRoomRecoveryWork(work)
        } else if transaction == "enqueueSummary" || transaction == "enqueueExistingSummary" {
            try await store.enqueueRoomLatestVisible(roomID: Self.room, scope: scope, now: Date(timeIntervalSince1970: 1000))
        } else if transaction == "ensureSummary" || transaction == "ensurePendingSummary" || transaction == "ensureFreshSummary" {
            try await store.ensureRoomLatestVisible(roomID: Self.room, scope: scope, now: Date(timeIntervalSince1970: 1000))
        } else if transaction == "restartDirectory" {
            try await store.restartRoomRecoveryDirectory(scope: scope)
        } else if transaction == "unavailable" {
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            _ = try await store.commitRoomRecoveryUnavailable(work)
        } else if transaction == "enqueue" {
            try await store.enqueueRoomRecovery(roomID: Self.room, targetHead: 7, priority: 1,
                scope: scope, now: Date(timeIntervalSince1970: 1000))
        } else if transaction == "retryWork" {
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1,
                oldestFirst: true, now: Date(timeIntervalSince1970: 1000)).first)
            try await store.retryRoomRecoveryWork(work, at: Date(timeIntervalSince1970: 2000))
        } else if transaction == "resetBegin" {
            try await store.beginReset(Self.snapshot(nonempty: true).manifest.reset)
        } else if transaction == "resetCancel" {
            try await store.cancelReset(Self.snapshot(nonempty: true).manifest.reset)
        } else if transaction == "snapshotImport" {
            try await store.beginSnapshotImport(Self.snapshot(nonempty: true).manifest,
                initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        } else if transaction == "snapshotPrepare" {
            try await store.prepareSnapshotActivation(Self.snapshot(nonempty: true).manifest)
        } else if transaction == "snapshotPage" {
            let fixture = try Self.snapshot(nonempty: true)
            try await store.applySnapshotPage(#require(fixture.page), for: fixture.manifest)
        } else if ["snapshot", "snapshotNonempty", "snapshotCleanup"].contains(transaction) {
            try await store.activateAcknowledgedSnapshot(Self.snapshot(nonempty: transaction != "snapshot").manifest)
        } else if transaction == "memberRemoval" {
            _ = try await store.applyGroupEventPage(Self.memberPage(removing: true))
        } else if transaction == "removal" {
            _ = try await store.apply(Self.removal())
        } else if transaction == "summaryWithoutWork" {
            let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
            _ = try await store.commitRoomLatestVisible(Self.summary(), request: request)
        } else if transaction == "summary" {
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
            _ = try await store.commitRoomLatestVisible(Self.summary(), request: request, work: work)
        } else if transaction == "state" {
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            _ = try await store.commitRoomRecoveryState(.init(roomID: Self.room, ownerEpoch: 1,
                viewerMembershipRevision: 1, head: 1, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0),
                work: work, now: .now)
        } else if transaction == "emptyDirectory" || transaction == "finalDirectory" {
            try await store.commitRoomRecoveryDirectoryPage(Self.followingDirectoryPage(final: transaction == "finalDirectory"),
                expectedCursor: "next-page", request: try await store.roomRecoveryScan(scope: scope), now: .now)
        } else if transaction == "directory" {
            try await store.commitRoomRecoveryDirectoryPage(Self.directoryPage(), expectedCursor: nil,
                request: try await store.roomRecoveryScan(scope: scope), now: .now)
        } else if let bodyWork {
            _ = try await store.applyRoomRecoveryPage(Self.page(), work: bodyWork)
        } else {
            _ = try await store.applyGroupEventPageReportingChanges(Self.page())
        }
        Issue.record("The transaction observer did not terminate the child")
    }

    private static let user = UserID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000016")!)
    private static func snapshot(nonempty: Bool) throws -> (manifest: V2ClientSnapshotManifest, page: V2ClientSnapshotPage?) {
        let initial = V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base")
        var root = initial
        var page: V2ClientSnapshotPage?
        if nonempty {
            let messageID = "00000000-0000-0000-0000-000000000019"
            let payload = try JSONSerialization.data(withJSONObject: [
                "event_type": "message.accepted", "room_id": room.rawValue,
                "message_id": messageID, "room_sequence": 7, "timeline_sequence": 7,
                "message_revision": 1, "sender_user_id": user.rawValue, "text": "snapshot-body",
                "media_ids": [], "media_presentations": [], "mention_user_ids": [],
                "mentions_everyone": false, "entities": [], "is_withdrawn": false,
                "server_created_at_ms": 1_750_000_000_000
            ], options: [.sortedKeys])
            let projection = try V2SnapshotProjectionV3Page(items: [.init(
                key: .init(projectionKind: "message", entityKey: messageID),
                sourceEventID: .init("00000000-0000-0000-0000-000000000020"), sequence: 10, payload: payload)])
            let encoded = try V2SnapshotProjectionV3Codec.encode(projection)
            let digest = V2SnapshotV3Digest.page(encoded)
            root = V2SnapshotV3Digest.next(previous: initial, pageIndex: 0, pageDigest: digest,
                firstKey: projection.firstKey, lastKey: projection.lastKey, itemCount: 1)
            page = try .init(index: 0, digest: digest, firstKey: projection.firstKey,
                lastKey: projection.lastKey, itemCount: 1, payload: encoded)
        }
        let manifest = try V2ClientSnapshotManifest(reset: .init(snapshotID: .init("00000000-0000-0000-0000-000000000018"),
            generation: 2, baseSequence: 10, expiresAt: Date(timeIntervalSince1970: 2_000_000_000)),
            rootDigest: root,
            pageCount: nonempty ? 1 : 0, totalItems: nonempty ? 1 : 0,
            totalBytes: UInt64(page?.payload.count ?? 0), nextSyncToken: .init("snapshot-token"),
            receipt: .init("snapshot-receipt"), capabilityProfile: "base")
        return (manifest, page)
    }
    private static func memberPage(removing: Bool) throws -> V2ClientGroupEventPage {
        var payload: [String: Any] = ["room_id": room.rawValue,
            "target_user_id": "00000000-0000-0000-0000-000000000041", "membership_revision": removing ? 3 : 2]
        if removing {
            payload["event_type"] = "membership_changed"; payload["action"] = "remove"
            payload["title"] = "Member crash"; payload["owner_user_id"] = user.rawValue
            payload["capacity_class"] = "standard"; payload["created_at_ms"] = 1000
            payload["server_created_at_ms"] = 3000
        } else {
            payload["event_type"] = "group.member_role_changed"; payload["role"] = "admin"
        }
        let event = try V2ClientGroupEvent(sourceEventID: .init(removing
            ? "00000000-0000-0000-0000-000000000043" : "00000000-0000-0000-0000-000000000042"),
            roomSequence: removing ? 2 : 1, projectionKind: removing ? "membership" : "group_capability",
            payload: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        return try .init(roomID: room, events: [event], nextRoomSequence: removing ? 2 : 1, hasMore: false)
    }
    private static func grant() throws -> V2ClientSyncBatch {
        let record = try V2ClientSyncRecord(sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000035"), projectionKind: "membership",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed",
                "room_id": room.rawValue, "membership_revision": 2, "target_user_id": user.rawValue,
                "action": "add", "title": "Granted room", "owner_user_id": user.rawValue,
                "capacity_class": "standard", "created_at_ms": 1000, "server_created_at_ms": 2000], options: [.sortedKeys]))
        return try .init(generation: 1, records: [record], nextSyncToken: .init("granted"),
            receipt: .init("grant-receipt"), hasMore: false, capabilityProfile: "base")
    }
    private static func removal() throws -> V2ClientSyncBatch {
        let record = try V2ClientSyncRecord(sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000017"), projectionKind: "membership",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed",
                "room_id": room.rawValue, "membership_revision": 2, "target_user_id": user.rawValue,
                "action": "remove"]))
        return try .init(generation: 1, records: [record], nextSyncToken: .init("removed"),
            receipt: .init("receipt"), hasMore: false, capabilityProfile: "base")
    }
    private static func summary() throws -> V2RoomLatestVisible {
        try .init(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 1, latest: nil)
    }
    private static func directoryPage() throws -> V2ClientUserRoomPage {
        try .init(rooms: [.init(roomID: room, kind: .group, viewerMembershipRevision: 1, ownerEpoch: 1)],
            nextCursor: "next-page", topologyGeneration: "crash-topology")
    }
    private static func followingDirectoryPage(final: Bool) throws -> V2ClientUserRoomPage {
        try .init(rooms: final ? [.init(roomID: .init(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000034")!),
            kind: .group, viewerMembershipRevision: 1, ownerEpoch: 1)] : [],
            nextCursor: final ? nil : "after-empty", topologyGeneration: "crash-topology")
    }
    private static let room = RoomID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
    private static func store(path: String) throws -> GRDBV2LocalSyncStore {
        try .init(databaseURL: URL(fileURLWithPath: path), installationBinding: .init(value:
            UUID(uuidString: "00000000-0000-0000-0000-000000000012")!), userID: user)
    }
    private static func page() throws -> V2ClientGroupEventPage {
        let payload = try JSONSerialization.data(withJSONObject: [
            "event_type": "message.accepted", "room_id": room.rawValue, "room_sequence": 1,
            "message_id": "00000000-0000-0000-0000-000000000013", "message_revision": 1,
            "sender_user_id": "00000000-0000-0000-0000-000000000014", "text": "crash-boundary",
            "server_created_at_ms": 1_750_000_000_000
        ], options: [.sortedKeys])
        return try .init(roomID: room, events: [.init(sourceEventID:
            .init("00000000-0000-0000-0000-000000000015"), roomSequence: 1,
            projectionKind: "message", payload: payload)], nextRoomSequence: 1, hasMore: false)
    }
}

/// GRDB invokes these callbacks on its serialized database writer.
private final class CrashAtRecoveryCommit: TransactionObserver, @unchecked Sendable {
    let afterCommit: Bool
    private var containsTarget = false
    let table: String
    init(afterCommit: Bool, table: String, allTransactions: Bool = false) {
        self.afterCommit = afterCommit; self.table = table; self.containsTarget = allTransactions
    }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == table
    }
    func databaseDidChange(with event: DatabaseEvent) { containsTarget = true }
    func databaseWillCommit() throws {
        if containsTarget && !afterCommit { terminate() }
    }
    func databaseDidCommit(_ db: Database) {
        if containsTarget && afterCommit { terminate() }
    }
    func databaseDidRollback(_ db: Database) { containsTarget = false }
    private func terminate() -> Never {
        kill(getpid(), SIGKILL)
        // Signal delivery can be scheduled on another thread. Never let the
        // writer advance from willCommit while process termination is pending.
        while true { pause() }
    }
}
#endif
